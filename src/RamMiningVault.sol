// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {FlapAIConsumerBase, IFlapAIProvider} from "./flap/IFlapAIProvider.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";

/// @notice Minimal Chainlink price-feed surface (NVDA/USD and BNB/USD, 8 decimals on BNB Chain).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title RamMiningVaultUpgradeable
/// @notice Flap V2 real-yield mining vault for the RAM project — KEEPER/RFQ model (v2).
/// @dev Users buy native-BNB "rig" contracts that grant mining `power`. The vault's reward comes from REAL
///      trading fees: the RAM tax token routes its `market` fee share (in BNB) to this vault. Instead of swapping
///      BNB on a DEX (v1), a keeper sells the reward token (tokenized NVIDIA, NVDAB) INTO the vault at the
///      Chainlink oracle price plus a small, clamped premium (`sellRWAToVault`): the vault pays BNB and
///      receives NVDAB, which it distributes pro-rata to active power using a MasterChef-style accumulator
///      (`accRewardPerPower`). Rigs expire per-rig; expiry is settled lazily by time buckets (no paid keeper).
///      NO buyback & burn — capital is reinvested into the reward asset.
///
///      v2 inverts the cash flow (BNB LEAVES the vault to a permissionless keeper), so the oracle + a clamped
///      premium + a per-fill cap + a per-window rate-limit + a deviation band + hard feed-staleness checks are
///      the wall against treasury drain. See the §8b must-fix set in the design doc.
contract RamMiningVaultUpgradeable is
    Initializable,
    VaultBaseV2,
    ReentrancyGuardUpgradeable,
    FlapAIConsumerBase,
    ITriggerReceiver
{
    using SafeERC20 for IERC20;

    uint256 public constant MAX_CONTRACTS_PER_USER = 16;
    uint256 public constant PLAN_COUNT = 4;
    uint256 public constant ACC_PRECISION = 1e12;
    uint256 public constant BUCKET = 1 days; // expiry granularity
    uint256 public constant BPS_DENOM = 10000;

    // --- economic-agent clamps (keeper premium) ---
    uint8 public constant LEVER_COUNT = 4; // 0 HOLD · 1 RAISE_PREMIUM · 2 LOWER_PREMIUM · 3 RETAIN
    /// @dev Hard, IMMUTABLE floor: the keeper premium can never drop below +2% (Flap's recommended NVDAB keeper
    ///      band is 1.02–1.04). The floor keeps fills live — a too-low premium would leave the vault with no keeper
    ///      and BNB that never converts to NVDA for miners. RAISING this floor requires a beacon upgrade (Guardian
    ///      + factory 2-day timelock), so the AI/guardian can only ever move the premium INSIDE Flap's band.
    uint256 public constant MIN_PREMIUM_BPS = 10200; // 102% (Flap-recommended floor)
    /// @dev Conservative ceiling (+4%, top of Flap's recommended band). Compile-time constant: RAISING the cap
    ///      requires upgrading the beacon implementation, itself gated behind the factory's 2-day upgrade timelock
    ///      + guardian. That satisfies must-fix #6 ("MAX no subible sin timelock") without a separate mutable cap.
    uint256 public constant MAX_PREMIUM_BPS = 10400; // 104% (+4% absolute ceiling)
    uint256 public constant PREMIUM_STEP_BPS = 50; // 0.5% per AI lever step
    /// @dev Dead-feed safety ceiling: the guardian can tune `rewardFeedMaxStale` up to this bound but never beyond
    ///      it, so a genuinely dead NVDA/USD feed (no print for > 30d) always makes sells REVERT. Matches the Flap
    ///      template's intentional MAX_PRICE_STALENESS (stock feeds don't update off-hours; 30d is the hard wall).
    uint256 public constant MAX_REWARD_FEED_STALE = 30 days;
    /// @dev BNB/USD updates 24/7, so its staleness is kept tight: the guardian can never set it looser than this.
    uint256 public constant MAX_BNB_FEED_STALE = 1 days;

    // --- keeper egress safety ---
    uint256 public constant WINDOW = 1 days; // fixed/tumbling rate-limit window for BNB egress (see _consumeWindow)

    // --- config (set at initialize) ---
    address public taxToken; // RAM token (fee source; not held by this vault directly)
    address public rewardToken; // tokenized NVIDIA distributed to miners (NVDAB)
    address public rewardPriceFeed; // Chainlink NVDA/USD feed (8 decimals)
    address public bnbPriceFeed; // Chainlink BNB/USD feed (8 decimals)
    uint8 public rewardTokenDecimals; // IERC20Metadata(rewardToken).decimals() read at initialize (NOT assumed 18)
    uint256 public basePriceWei; // Micro rig price in BNB
    uint256 public seasonEnd; // rigs cannot mine past this timestamp

    // --- keeper / RFQ acquisition (replaces v1 DEX swap) ---
    uint256 public keeperPremiumBps; // premium paid to the keeper over oracle market value (default 10200 = +2%)
    uint256 public maxBnbOutPerFill; // absolute cap on BNB paid out in a single sell (guardian-set; 0 = sells disabled)
    uint256 public maxBnbOutPerWindow; // cap on BNB paid out per WINDOW (guardian-set; 0 = sells disabled)
    uint256 public bnbOutThisWindow; // BNB paid out so far in the current window
    uint256 public windowStart; // start timestamp of the current rate-limit window
    uint256 public priceDeviationBps; // max allowed deviation of the live feed from referencePrice (guardian-set)
    uint256 public referencePrice; // armed NVDA/USD reference (8 dec); deviation band is enforced only when != 0
    uint256 public bnbFeedMaxStale; // max staleness for BNB/USD (crypto 24/7 → short, ~1-2h)
    uint256 public rewardFeedMaxStale; // max staleness for NVDA/USD (stock feed freezes off-hours; 7d so weekend
        // buys keep operating per Flap, bounded by MAX_REWARD_FEED_STALE = dead-feed wall)
    uint256 public lastFillTimestamp; // liveness metric: last successful keeper sell

    // --- real-yield accumulator ---
    uint256 public accRewardPerPower; // reward token per unit of power, scaled by ACC_PRECISION
    uint256 public totalActivePower; // power currently mining (expired rigs excluded)
    uint256 public rewardUndistributed; // reward received while totalActivePower == 0 (applied to first miner)
    uint256 public lastSettledBucket; // last time bucket _settleExpiries advanced to
    mapping(uint256 => uint256) public powerExpiringAtBucket; // bucket => power that stops mining at that bucket
    mapping(uint256 => uint256) public accSnapshotAtBucket; // bucket => accRewardPerPower frozen at that bucket's expiry

    // --- stats ---
    uint256 public totalContractsSold;
    uint256 public totalRewardDistributed; // reward token credited to the accumulator (lifetime)
    uint256 public totalRewardClaimed; // reward token actually claimed (lifetime)
    uint256 public totalNativePaid; // BNB paid by miners buying rigs (lifetime)
    uint256 public totalBnbPaidToKeepers; // BNB paid out to keepers via sellRWAToVault (lifetime)
    uint256 public lastContractId;

    // --- economic agent (AI oracle) ---
    address public flapAIProvider; // overrides chain-default AI provider when set (config/testing)
    address public flapTriggerService; // Flap trigger service (configurable; testnet addr not in interface)
    uint256 public aiModelId;
    uint256 public aiReasonFee; // BNB budget per reason() call
    uint64 public epochInterval; // seconds between economic epochs
    bool public autoTriggerEnabled;
    uint256 public lastReasoningRequestId;
    uint256 public lastTriggerRequestId;
    uint256 public lastEpochAt;
    uint8 public lastLever;

    struct Rig {
        uint256 id;
        uint256 planId;
        uint256 power;
        uint256 startTime;
        uint256 endTime;
        uint256 endBucket;
        uint256 rewardDebt; // accRewardPerPower checkpoint for this rig
        uint256 claimed; // reward token already claimed from this rig
        uint256 paidNative;
    }

    mapping(address => Rig[]) private userRigs;

    /// @dev Storage gap for safe future upgrades (append-only): when adding new state vars, append them and
    ///      shrink this gap so the beacon-proxy storage layout never collides. v2 is a fresh deployment
    ///      (new beacon implementation), so this reflects the new layout, not an upgrade-in-place of v1.
    uint256[44] private __gap;

    event RigBought(
        address indexed user,
        uint256 indexed rigId,
        uint256 indexed planId,
        uint256 power,
        uint256 priceWei,
        uint256 startTime,
        uint256 endTime
    );
    event RewardClaimed(address indexed user, address indexed to, uint256 amount);
    event RewardNotified(uint256 amount, uint256 newAccRewardPerPower);
    event RWASoldToVault(address indexed keeper, uint256 rwaIn, uint256 bnbOut);
    event KeeperConfigured(address rewardPriceFeed, address bnbPriceFeed, uint256 keeperPremiumBps);
    event KeeperLimitsSet(uint256 maxBnbOutPerFill, uint256 maxBnbOutPerWindow);
    event OracleGuardsSet(uint256 priceDeviationBps, uint256 bnbFeedMaxStale, uint256 rewardFeedMaxStale);
    event ReferencePriceSet(uint256 referencePrice);
    event KeeperPremiumSet(uint256 keeperPremiumBps);
    event AgentConfigured(address provider, address triggerService, uint256 modelId);
    event ReasoningRequested(uint256 requestId);
    event LeverApplied(uint256 indexed requestId, uint8 indexed lever);
    event ReasoningRefunded(uint256 indexed requestId);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _taxToken,
        address _rewardToken,
        address _rewardPriceFeed,
        address _bnbPriceFeed,
        uint256 _basePriceWei,
        uint256 _seasonEnd
    ) external initializer {
        __ReentrancyGuard_init();
        require(_taxToken != address(0), unicode"RAM token required / 需要 RAM 代币地址");
        require(_rewardToken != address(0), unicode"Reward token required / 需要奖励代币地址");
        require(_rewardPriceFeed != address(0), unicode"Reward feed required / 需要奖励价格预言机");
        require(_bnbPriceFeed != address(0), unicode"BNB feed required / 需要 BNB 价格预言机");
        // should-fix #7: the quote math assumes 8-decimal Chainlink feeds (the two feeds cancel). Enforce it so a
        // mis-wired feed with different decimals can never silently mis-price the keeper payout.
        require(AggregatorV3Interface(_rewardPriceFeed).decimals() == 8, unicode"Reward feed not 8dec / 奖励预言机非8位");
        require(AggregatorV3Interface(_bnbPriceFeed).decimals() == 8, unicode"BNB feed not 8dec / BNB预言机非8位");
        require(_basePriceWei > 0, unicode"Base price required / 需要基础价格");
        require(_seasonEnd >= block.timestamp + 1 days, unicode"Season too short / 赛季过短");

        taxToken = _taxToken;
        rewardToken = _rewardToken;
        rewardPriceFeed = _rewardPriceFeed;
        bnbPriceFeed = _bnbPriceFeed;
        basePriceWei = _basePriceWei;
        seasonEnd = _seasonEnd;
        lastSettledBucket = block.timestamp / BUCKET;

        // must-fix #7: read the reward token's real decimals (NVDAB = 18, but never assume).
        rewardTokenDecimals = IERC20Metadata(_rewardToken).decimals();

        // Safe-by-default keeper config. BNB egress caps start at 0 → sells are DISABLED until the guardian
        // explicitly arms maxBnbOutPerFill / maxBnbOutPerWindow. The premium starts at the centre of Flap's
        // recommended NVDAB band (1.03), clamped to [MIN_PREMIUM_BPS, MAX_PREMIUM_BPS] = [1.02, 1.04].
        keeperPremiumBps = 10300; // +3% (centre of Flap's recommended 1.02–1.04 keeper band)
        bnbFeedMaxStale = 2 hours; // crypto feed is 24/7; tight window
        // GENEROUS default (per Flap #8): NVDA/USD Chainlink freezes off-hours, but Flap does NOT want weekend buys
        // to revert (failed txs = bad UX). 7d keeps fills operating over the weekend at the last (Friday) print;
        // the residual weekend-arb is bounded by the per-fill / per-window BNB caps and is the documented interim
        // trade-off until Flap's 24/7 NVDA feed is wired (then the guardian can tighten this toward ~12–24h). The
        // hard dead-feed wall stays at MAX_REWARD_FEED_STALE (30d): a genuinely dead feed still makes sells revert.
        rewardFeedMaxStale = 7 days;
        // ±5% band vs the armed referencePrice. NVDA is a volatile single stock that routinely moves >2% intraday,
        // and the band compares the live feed against a STATIC guardian-armed reference — so a too-tight band would
        // brick ALL keeper fills on a legitimate price move until the guardian re-arms (fails CLOSED: no fund loss,
        // but a liveness footgun). 5% matches Flap's 24/7 feed deviation threshold. GUARDIAN DUTY: keep the band wide
        // enough for NVDA's real volatility and re-arm `setReferencePrice` periodically so the band stays meaningful
        // (its job is to catch a manipulated/jumped oracle, not normal drift; tighten once the 24/7 feed is wired).
        priceDeviationBps = 500; // ±5% band vs referencePrice once armed (NVDA-appropriate default)
        windowStart = block.timestamp;
        // maxBnbOutPerFill, maxBnbOutPerWindow, referencePrice default to 0 (sells disabled / band off until armed).
    }

    /// @notice Accept native BNB. The RAM tax token's TaxProcessor sends the `market` fee share here, and the
    ///         vault can also be seeded with BNB. No external calls, no loops.
    receive() external payable {}

    // ──────────────────────────────────────────────────────────────────────────
    //  Buy / Claim
    // ──────────────────────────────────────────────────────────────────────────

    function buyMiningContract(uint256 planId) external payable nonReentrant {
        require(planId < PLAN_COUNT, unicode"Invalid plan / 无效套餐");
        require(block.timestamp < seasonEnd, unicode"Mining season ended / 挖矿赛季已结束");

        _settleExpiries();
        _compact(msg.sender);
        require(userRigs[msg.sender].length < MAX_CONTRACTS_PER_USER, unicode"Too many rigs / 矿机数量过多");

        (uint256 priceWei, uint256 power, uint256 duration,) = _plan(planId);
        require(msg.value >= priceWei, unicode"Not enough BNB / BNB 不足");

        uint256 start = block.timestamp;
        uint256 end = start + duration;
        if (end > seasonEnd) {
            end = seasonEnd;
        }
        require(end > start, unicode"No mining time left / 没有剩余挖矿时间");
        uint256 endBucket = end / BUCKET;
        // BUG FIX (last-bucket brick): _settleExpiries() above advanced lastSettledBucket to nowBucket and the
        // settle loop only scans buckets > lastSettledBucket. A rig whose endBucket has already been settled
        // (e.g. near seasonEnd, when end is capped into the current/settled bucket) would inflate totalActivePower
        // forever (its power never gets subtracted) and read accSnapshotAtBucket==0 → owed underflow → claims
        // brick for everyone. Reject such rigs: their power must expire in a future, not-yet-settled bucket.
        require(endBucket > lastSettledBucket, unicode"Rig ends too soon / 套餐过短");

        // Refund excess BNB before recording state (safe-order; full revert on failure).
        uint256 refund = msg.value - priceWei;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, unicode"Refund failed / 退款失败");
        }

        lastContractId += 1;
        userRigs[msg.sender].push(
            Rig({
                id: lastContractId,
                planId: planId,
                power: power,
                startTime: start,
                endTime: end,
                endBucket: endBucket,
                rewardDebt: accRewardPerPower,
                claimed: 0,
                paidNative: priceWei
            })
        );

        totalActivePower += power;
        powerExpiringAtBucket[endBucket] += power;
        totalContractsSold += 1;
        totalNativePaid += priceWei;

        emit RigBought(msg.sender, lastContractId, planId, power, priceWei, start, end);
    }

    // @dev Claims are NEVER gated by anything — there is no pause anywhere in this vault (Flap's no-pause model:
    //      recovery is the Guardian-only beacon upgrade, not an operational pause). Users can always withdraw.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        amount = _claim(msg.sender, msg.sender);
    }

    /// @notice Claim accumulated rewards to a different recipient — useful if the caller's own address became
    ///         non-compliant for the (regulated) reward token but a fresh recipient can still receive it.
    function claimRewardsTo(address to) external nonReentrant returns (uint256 amount) {
        require(to != address(0), unicode"Bad recipient / 错误接收地址");
        amount = _claim(msg.sender, to);
    }

    /// @dev Single accounting+transfer claim path. Effects (rewardDebt/claimed) are mutated BEFORE the one and
    ///      only `safeTransfer` at the end; if that transfer reverts (reward token paused / recipient non-compliant)
    ///      the whole tx rolls back atomically, leaving this miner's pending intact and OTHER miners' accounting
    ///      untouched. No transfers happen inside the rig loop (would open reentrancy). (must-fix #8 alignment.)
    function _claim(address user, address to) internal returns (uint256 amount) {
        _settleExpiries();
        Rig[] storage rigs = userRigs[user];
        for (uint256 i = 0; i < rigs.length; i++) {
            Rig storage r = rigs[i];
            uint256 acc = _rigAcc(r);
            uint256 owed = (r.power * (acc - r.rewardDebt)) / ACC_PRECISION;
            if (owed > 0) {
                r.rewardDebt = acc;
                r.claimed += owed;
                amount += owed;
            }
        }
        require(amount > 0, unicode"Nothing to claim / 无可领取");

        totalRewardClaimed += amount;
        IERC20(rewardToken).safeTransfer(to, amount);
        emit RewardClaimed(user, to, amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Reward funding (real-yield): keeper/RFQ — keeper sells the RWA (NVDAB) INTO the
    //  vault at oracle price + clamped premium; the vault pays BNB and distributes NVDAB.
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Oracle quote: how much BNB the vault pays for `rwaAmount` of the reward RWA token (NVDAB).
    /// @dev Reads both Chainlink feeds with HARD staleness/sanity checks (revert on stale/bad price), normalizes
    ///      `rwaAmount` to 18 decimals via the token's real `decimals()`, then applies the keeper premium.
    ///      `marketBnb = rwaAmount(18) * nvdaUsd / bnbUsd` (the two 8-dec feeds cancel, leaving BNB wei).
    ///      Note: within `rewardFeedMaxStale` of the last print the quote uses that (frozen-but-tolerated) price —
    ///      see `_checkDeviationBand` for the bounded window-frontier arbitrage trade-off and its mitigations.
    function quoteRWAToVault(uint256 rwaAmount) public view returns (uint256 bnbOwed) {
        uint256 nvdaUsd = _readFeed(rewardPriceFeed, rewardFeedMaxStale); // 8 dec
        uint256 bnbUsd = _readFeed(bnbPriceFeed, bnbFeedMaxStale); // 8 dec
        uint256 amount18 = _to18(rwaAmount);
        uint256 marketBnb = (amount18 * nvdaUsd) / bnbUsd; // 18-dec BNB wei
        bnbOwed = (marketBnb * keeperPremiumBps) / BPS_DENOM;
    }

    /// @notice PERMISSIONLESS keeper RFQ (Flap standard interface): the keeper transfers `rwaAmount` of the RWA
    ///         token (NVDAB) into the vault and is paid `bnbOwed` (oracle price + premium) from the vault's BNB
    ///         reserve. The received NVDAB is distributed to miners by power. This is the v2 replacement for the
    ///         v1 DEX swap, and the standard surface Flap's arbitrageurs/keepers fill against.
    /// @dev BNB LEAVES the vault to a permissionless caller, so every drain guard fires here: oracle staleness (in
    ///      the quote), per-fill cap, per-window rate-limit, deviation band, balance check. There is NO pause — a
    ///      stuck/compromised vault is handled by the Guardian-only beacon upgrade, not an operational pause. The
    ///      keeper is paid LAST (CEI), and the credited reward is the REAL measured delta (fee-on-transfer safe).
    /// @param rwaAmount amount of reward RWA token the keeper sells into the vault.
    /// @param minBnbOut keeper slippage floor (the oracle may have moved since they quoted).
    function sellRWAToVault(uint256 rwaAmount, uint256 minBnbOut)
        external
        nonReentrant
        returns (uint256 bnbOwed)
    {
        require(rwaAmount > 0, unicode"Bad amount / 金额错误");
        // should-fix #6: settle expiries BEFORE checking effective power, so no BNB leaves once power has lapsed
        // (e.g. past seasonEnd, where all power is settled to 0 → reverts here instead of paying a keeper).
        _settleExpiries();
        require(totalActivePower > 0, unicode"No miners / 没有矿工");

        // must-fix #5/#8: pull FIRST, measure the REAL received delta, and price THAT delta — so a future
        // fee-on-transfer/rebasing reward token can never make the vault overpay the keeper on a nominal amount.
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rwaAmount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
        require(received > 0, unicode"No reward received / 未收到奖励");

        // price the actual received delta; all drain guards apply to THIS final bnbOwed.
        bnbOwed = quoteRWAToVault(received);
        require(bnbOwed > 0 && bnbOwed >= minBnbOut, unicode"Slippage / 滑点过大"); // keeper slippage on the FINAL owed
        require(bnbOwed <= maxBnbOutPerFill, unicode"Over per-fill cap / 超过单次上限");

        // must-fix #1a: deviation band vs the armed reference price (rejects an oracle that jumped/was manipulated).
        _checkDeviationBand();
        // must-fix #1c: per-window BNB egress rate-limit (fixed/tumbling window — see _consumeWindow).
        _consumeWindow(bnbOwed);

        require(address(this).balance >= bnbOwed, unicode"Insufficient BNB / BNB 不足");

        _notifyReward(received); // distribute the actual delta by power
        lastFillTimestamp = block.timestamp; // liveness metric
        totalBnbPaidToKeepers += bnbOwed;

        // CEI: pay the keeper LAST (reentrancy-guarded above).
        (bool ok,) = payable(msg.sender).call{value: bnbOwed}("");
        require(ok, unicode"BNB transfer failed / BNB 转账失败");
        emit RWASoldToVault(msg.sender, received, bnbOwed);
    }

    /// @dev Chainlink read with HARD checks (must-fix #2 & #4). Any stale/bad answer REVERTS the whole op — never
    ///      a silent zero/old price. BNB Chain is L1, so there is NO sequencer-uptime feed to consult (that's L2).
    function _readFeed(address feed, uint256 maxStale) internal view returns (uint256 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, unicode"Bad feed price / 预言机价格无效");
        require(updatedAt != 0, unicode"Round not complete / 轮次未完成");
        require(answeredInRound >= roundId, unicode"Stale round / 预言机轮次过期");
        require(block.timestamp - updatedAt <= maxStale, unicode"Stale feed / 预言机数据过期");
        price = uint256(answer);
    }

    /// @dev Normalize an amount of reward token to 18 decimals using the token's real `decimals()`.
    function _to18(uint256 amount) internal view returns (uint256) {
        uint8 d = rewardTokenDecimals;
        if (d == 18) return amount;
        if (d < 18) return amount * (10 ** (18 - d));
        return amount / (10 ** (d - 18));
    }

    /// @dev must-fix #1a: reject the sell if the live NVDA/USD feed deviates more than `priceDeviationBps` from the
    ///      armed `referencePrice`. NOTE: the band compares the SAME feed (live) vs a stored reference, so it is
    ///      BLIND to a frozen feed (a stale value still sits inside the band) — the weekend/overnight arbitrage
    ///      risk is NOT resolved by the band. It is mitigated by the HARD staleness check in `_readFeed` (a frozen
    ///      NVDA/USD feed makes the sell REVERT = a de-facto pause while the market is closed) plus the per-fill /
    ///      per-window BNB caps. The band's job is narrower: catch a fresh-but-jumped/manipulated oracle print.
    ///      Sells cannot run until the guardian arms a reference (enforced at setKeeperLimits AND on every sell).
    ///
    ///      RESIDUAL ARB (inherent, documented trade-off — NOT a bug): even with the band armed, for up to
    ///      `rewardFeedMaxStale` after the last feed print the sell executes at the last (frozen-but-tolerated)
    ///      price, and the band is structurally blind to a frozen feed because it compares the feed against a
    ///      reference derived from that same feed. That window is BOUNDED by the per-fill and per-window BNB caps,
    ///      so the worst-case loss is capped. The real future mitigation is a market-open gate; until then the
    ///      operator must set `rewardFeedMaxStale` ≈ the feed's true market-hours heartbeat (a liveness/arb
    ///      trade-off: tighter = less arb but more spurious reverts intra-heartbeat).
    function _checkDeviationBand() internal view {
        uint256 ref = referencePrice;
        if (ref == 0) {
            // INVARIANT (enforced on EVERY sell, not only at setKeeperLimits): egress enabled ⟹ band armed.
            // If the band was disarmed (setReferencePrice(0) / setPriceFeeds) while caps stayed armed, refuse the
            // sell rather than run with the band OFF and egress OPEN.
            require(
                maxBnbOutPerFill == 0 && maxBnbOutPerWindow == 0, unicode"Arm reference price first / 请先设置参考价"
            );
            return;
        }
        uint256 live = _readFeed(rewardPriceFeed, rewardFeedMaxStale);
        uint256 diff = live > ref ? live - ref : ref - live;
        require(diff * BPS_DENOM <= ref * priceDeviationBps, unicode"Price out of band / 价格超出区间");
    }

    /// @dev must-fix #1c: per-window BNB egress accounting; reverts if this fill would breach the window cap.
    ///      NOTE: this is a FIXED / TUMBLING window (NOT a sliding window) — the counter resets the first time a
    ///      fill lands at/after windowStart + WINDOW, anchoring a fresh full allowance to that fill. A keeper can
    ///      therefore egress up to ~2× maxBnbOutPerWindow straddling a boundary (full cap just before the reset +
    ///      full cap just after). This is NOT a drain (every fill is value-for-value: NVDA in at oracle price, BNB
    ///      out at the clamped premium), but the guardian must SIZE maxBnbOutPerWindow knowing the worst-case
    ///      boundary egress is ~2× the nominal per-window figure.
    function _consumeWindow(uint256 amount) internal {
        if (block.timestamp >= windowStart + WINDOW) {
            windowStart = block.timestamp;
            bnbOutThisWindow = 0;
        }
        require(bnbOutThisWindow + amount <= maxBnbOutPerWindow, unicode"Over window cap / 超过窗口上限");
        bnbOutThisWindow += amount;
    }

    /// @notice Credit reward tokens already held/received by the vault into the distribution accumulator.
    /// @dev Pull-pattern fallback for externally-sourced reward token (e.g. a manual top-up). Caller must approve.
    ///      Credits the REAL measured delta (must-fix #5), not the nominal `amount`.
    function donateReward(uint256 amount) external nonReentrant {
        require(amount > 0, unicode"Bad amount / 金额错误");
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
        require(received > 0, unicode"No reward received / 未收到奖励");
        _notifyReward(received);
    }

    function _notifyReward(uint256 amount) internal {
        if (amount == 0) return;
        _settleExpiries();
        uint256 toDistribute = amount + rewardUndistributed;
        if (totalActivePower == 0) {
            rewardUndistributed = toDistribute;
            return;
        }
        rewardUndistributed = 0;
        accRewardPerPower += (toDistribute * ACC_PRECISION) / totalActivePower;
        totalRewardDistributed += toDistribute; // S3 fix: credit what was actually distributed (incl. flushed
        // rewardUndistributed), so the `Σ claimed ≤ Σ distributed` invariant holds when undistributed reward is flushed.
        emit RewardNotified(toDistribute, accRewardPerPower);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Lazy bucket expiry settlement
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Advances `totalActivePower` to the current bucket, freezing `accRewardPerPower` at each bucket where
    ///      power expires. Cost is a bounded loop over elapsed day-buckets, paid by the interacting tx (no keeper).
    function _settleExpiries() internal {
        uint256 nowBucket = block.timestamp / BUCKET;
        if (nowBucket <= lastSettledBucket) return;
        // S1 fix: no rig mines past seasonEnd, so no power expires beyond it — cap the scanned range at the
        // season-end bucket. This bounds the loop to the season length forever (keeps the AI/trigger callbacks
        // under the 2M-gas cap) no matter how long the vault sits without interaction.
        uint256 endBucket = seasonEnd / BUCKET;
        uint256 target = nowBucket < endBucket ? nowBucket : endBucket;
        for (uint256 b = lastSettledBucket + 1; b <= target; b++) {
            uint256 expiring = powerExpiringAtBucket[b];
            if (expiring > 0) {
                accSnapshotAtBucket[b] = accRewardPerPower;
                totalActivePower = expiring >= totalActivePower ? 0 : totalActivePower - expiring;
            }
        }
        lastSettledBucket = nowBucket;
    }

    /// @dev The accumulator value applicable to a rig: live if still active, frozen snapshot if expired.
    function _rigAcc(Rig storage r) internal view returns (uint256) {
        uint256 nowBucket = block.timestamp / BUCKET;
        if (nowBucket >= r.endBucket) {
            // Expired. If settlement already passed its bucket, the frozen snapshot is authoritative.
            // Otherwise no reward could have been distributed since expiry (notifyReward always settles first),
            // so the current accumulator equals the value at expiry.
            if (lastSettledBucket >= r.endBucket) {
                return accSnapshotAtBucket[r.endBucket];
            }
            return accRewardPerPower;
        }
        return accRewardPerPower;
    }

    /// @dev Removes fully-settled expired rigs (no pending) via swap-and-pop to keep the active set bounded.
    function _compact(address user) internal {
        Rig[] storage rigs = userRigs[user];
        uint256 i = 0;
        while (i < rigs.length) {
            Rig storage r = rigs[i];
            bool expired = block.timestamp / BUCKET >= r.endBucket;
            uint256 acc = _rigAcc(r);
            uint256 owed = (r.power * (acc - r.rewardDebt)) / ACC_PRECISION;
            if (expired && owed == 0) {
                rigs[i] = rigs[rigs.length - 1];
                rigs.pop();
            } else {
                i++;
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────────────

    function pendingRewards(address user) public view returns (uint256 amount) {
        Rig[] storage rigs = userRigs[user];
        for (uint256 i = 0; i < rigs.length; i++) {
            Rig storage r = rigs[i];
            uint256 acc = _rigAcc(r);
            amount += (r.power * (acc - r.rewardDebt)) / ACC_PRECISION;
        }
    }

    function activeContractCount(address user) external view returns (uint256 count) {
        count = userRigs[user].length;
    }

    function getMiningContract(address user, uint256 index)
        external
        view
        returns (
            uint256 rigId,
            uint256 planId,
            uint256 power,
            uint256 startTime,
            uint256 endTime,
            uint256 claimed,
            uint256 pending,
            bool active
        )
    {
        require(index < userRigs[user].length, unicode"Bad rig index / 错误矿机索引");
        Rig storage r = userRigs[user][index];
        rigId = r.id;
        planId = r.planId;
        power = r.power;
        startTime = r.startTime;
        endTime = r.endTime;
        claimed = r.claimed;
        uint256 acc = _rigAcc(r);
        pending = (r.power * (acc - r.rewardDebt)) / ACC_PRECISION;
        active = block.timestamp / BUCKET < r.endBucket;
    }

    function getPlan(uint256 planId)
        external
        view
        returns (uint256 priceWei, uint256 power, uint256 durationSeconds, string memory name)
    {
        require(planId < PLAN_COUNT, unicode"Invalid plan / 无效套餐");
        (priceWei, power, durationSeconds, name) = _plan(planId);
    }

    function getVaultMiningStats()
        external
        view
        returns (
            uint256 rewardTokenBalance,
            uint256 nativeTreasury,
            uint256 miningPower,
            uint256 contractsSold,
            uint256 rewardDistributed,
            uint256 seasonEndsAt,
            uint256 accRewardPerPowerScaled
        )
    {
        rewardTokenBalance = IERC20(rewardToken).balanceOf(address(this));
        nativeTreasury = address(this).balance;
        miningPower = totalActivePower;
        contractsSold = totalContractsSold;
        rewardDistributed = totalRewardDistributed;
        seasonEndsAt = seasonEnd;
        accRewardPerPowerScaled = accRewardPerPower;
    }

    function getUserMinerStats(address user)
        external
        view
        returns (
            uint256 contractCount,
            uint256 activePower,
            uint256 lifetimeClaimed,
            uint256 claimableReward,
            uint256 sharePerMille
        )
    {
        Rig[] storage rigs = userRigs[user];
        contractCount = rigs.length;
        for (uint256 i = 0; i < rigs.length; i++) {
            Rig storage r = rigs[i];
            lifetimeClaimed += r.claimed;
            if (block.timestamp / BUCKET < r.endBucket) {
                activePower += r.power;
            }
            uint256 acc = _rigAcc(r);
            claimableReward += (r.power * (acc - r.rewardDebt)) / ACC_PRECISION;
        }
        sharePerMille = totalActivePower == 0 ? 0 : (activePower * 1000) / totalActivePower;
    }

    function description() public view override returns (string memory) {
        if (totalContractsSold == 0) {
            return unicode"RAM Mining Vault: no rigs yet. Buy a rig with BNB to start earning tokenized NVIDIA funded by RAM trading fees. / RAM 挖矿金库：还没有矿机。用 BNB 购买矿机，开始赚取由 RAM 交易费购买的代币化英伟达。";
        }
        return unicode"RAM Mining Vault: rigs are mining. Rewards are tokenized NVIDIA bought with real RAM trading fees and shared by mining power. / RAM 挖矿金库：矿机运行中。奖励为用真实 RAM 交易费购买的代币化英伟达，按算力分配。";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "RamMiningVault";
        schema.description =
            "Mine tokenized NVIDIA with RAM. Buy a rig with BNB to gain mining power; the vault acquires tokenized NVIDIA from keepers at the Chainlink oracle price plus a small clamped premium (funded by real trading fees) and distributes it pro-rata to your power. No buyback & burn.";
        schema.methods = new VaultMethodSchema[](9);

        schema.methods[0].name = "getVaultMiningStats";
        schema.methods[0].description =
            "Mining Terminal: NVDA reward balance, BNB treasury, total power, rigs sold, NVDA distributed, season end, accumulator.";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](7);
        schema.methods[0].outputs[0] = FieldDescriptor("rewardBalance", "uint256", "NVDA Reward Balance", 18);
        schema.methods[0].outputs[1] = FieldDescriptor("bnbTreasury", "uint256", "BNB Treasury", 18);
        schema.methods[0].outputs[2] = FieldDescriptor("totalMiningPower", "uint256", "Total Mining Power", 0);
        schema.methods[0].outputs[3] = FieldDescriptor("rigsSold", "uint256", "Rigs Sold", 0);
        schema.methods[0].outputs[4] = FieldDescriptor("nvdaDistributed", "uint256", "NVDA Distributed", 18);
        schema.methods[0].outputs[5] = FieldDescriptor("seasonEnds", "time", "Season Ends", 0);
        schema.methods[0].outputs[6] = FieldDescriptor("accPerPower", "uint256", "Acc Reward / Power", 0);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "getUserMinerStats";
        schema.methods[1].description = "My Miner: rigs, active power, NVDA claimed, claimable NVDA, share per-mille.";
        schema.methods[1].inputs = new FieldDescriptor[](1);
        schema.methods[1].inputs[0] = FieldDescriptor("user", "address", "Miner wallet address", 0);
        schema.methods[1].outputs = new FieldDescriptor[](5);
        schema.methods[1].outputs[0] = FieldDescriptor("myRigs", "uint256", "My Rigs", 0);
        schema.methods[1].outputs[1] = FieldDescriptor("myPower", "uint256", "My Power", 0);
        schema.methods[1].outputs[2] = FieldDescriptor("alreadyClaimed", "uint256", "NVDA Claimed", 18);
        schema.methods[1].outputs[3] = FieldDescriptor("claimableNVDA", "uint256", "Claimable NVDA", 18);
        schema.methods[1].outputs[4] = FieldDescriptor("sharePerMille", "uint256", "Share (per-mille)", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        schema.methods[2].name = "pendingRewards";
        schema.methods[2].description = "Quick claimable NVDA check for any miner wallet.";
        schema.methods[2].inputs = new FieldDescriptor[](1);
        schema.methods[2].inputs[0] = FieldDescriptor("user", "address", "Miner wallet address", 0);
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] = FieldDescriptor("claimableNVDA", "uint256", "Claimable NVDA", 18);
        schema.methods[2].approvals = new ApproveAction[](0);

        schema.methods[3].name = "getPlan";
        schema.methods[3].description = "Rig Shop preview. Plan IDs: 0 Micro, 1 Core, 2 Mega, 3 Hyper.";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] = FieldDescriptor("planId", "uint256", "Plan ID: 0, 1, 2, or 3", 0);
        schema.methods[3].outputs = new FieldDescriptor[](4);
        schema.methods[3].outputs[0] = FieldDescriptor("rigPrice", "uint256", "Rig Price", 18);
        schema.methods[3].outputs[1] = FieldDescriptor("miningPower", "uint256", "Mining Power", 0);
        schema.methods[3].outputs[2] = FieldDescriptor("duration", "uint256", "Duration", 0);
        schema.methods[3].outputs[3] = FieldDescriptor("rigName", "string", "Rig Name", 0);
        schema.methods[3].approvals = new ApproveAction[](0);

        schema.methods[4].name = "buyMiningContract";
        schema.methods[4].description = "Buy a mining rig with BNB. Plan IDs: 0 Micro, 1 Core, 2 Mega, 3 Hyper. Extra BNB is refunded.";
        schema.methods[4].inputs = new FieldDescriptor[](2);
        schema.methods[4].inputs[0] = FieldDescriptor("planId", "uint256", "Plan ID: 0, 1, 2, or 3", 0);
        schema.methods[4].inputs[1] = FieldDescriptor("amount", "msg.value", "BNB to pay for the selected rig", 18);
        schema.methods[4].outputs = new FieldDescriptor[](0);
        schema.methods[4].approvals = new ApproveAction[](0);
        schema.methods[4].isWriteMethod = true;

        schema.methods[5].name = "claimRewards";
        schema.methods[5].description = "Claim your accumulated tokenized NVIDIA rewards.";
        schema.methods[5].inputs = new FieldDescriptor[](0);
        schema.methods[5].outputs = new FieldDescriptor[](0);
        schema.methods[5].approvals = new ApproveAction[](0);
        schema.methods[5].isWriteMethod = true;

        schema.methods[6].name = "quoteRWAToVault";
        schema.methods[6].description =
            "Keeper RFQ quote: BNB the vault will pay for a given amount of the RWA reward token at the oracle price plus premium.";
        schema.methods[6].inputs = new FieldDescriptor[](1);
        schema.methods[6].inputs[0] = FieldDescriptor("rwaAmount", "uint256", "RWA reward token amount to sell", 18);
        schema.methods[6].outputs = new FieldDescriptor[](1);
        schema.methods[6].outputs[0] = FieldDescriptor("bnbOwed", "uint256", "BNB the vault will pay", 18);
        schema.methods[6].approvals = new ApproveAction[](0);

        schema.methods[7].name = "sellRWAToVault";
        schema.methods[7].description =
            "Keeper RFQ fill: sell the RWA reward token into the vault for BNB at the oracle price plus premium. Set minBnbOut for slippage protection.";
        schema.methods[7].inputs = new FieldDescriptor[](2);
        schema.methods[7].inputs[0] = FieldDescriptor("rwaAmount", "uint256", "RWA reward token amount to sell", 18);
        schema.methods[7].inputs[1] = FieldDescriptor("minBnbOut", "uint256", "Minimum BNB to accept (slippage)", 18);
        schema.methods[7].outputs = new FieldDescriptor[](1);
        schema.methods[7].outputs[0] = FieldDescriptor("bnbOut", "uint256", "BNB paid to the keeper", 18);
        schema.methods[7].approvals = new ApproveAction[](1);
        // UI: call vault.rewardToken() then token.approve(vault, rwaAmount) before the fill.
        schema.methods[7].approvals[0] = ApproveAction("rewardToken", "rwaAmount");
        schema.methods[7].isWriteMethod = true;

        schema.methods[8].name = "claimRewardsTo";
        schema.methods[8].description =
            "Claim your accumulated tokenized NVIDIA rewards to a different recipient address.";
        schema.methods[8].inputs = new FieldDescriptor[](1);
        schema.methods[8].inputs[0] = FieldDescriptor("to", "address", "Recipient of the claimed rewards", 0);
        schema.methods[8].outputs = new FieldDescriptor[](0);
        schema.methods[8].approvals = new ApproveAction[](0);
        schema.methods[8].isWriteMethod = true;
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Admin (guardian) — NO pause, NO emergency-withdraw hatches (Flap no-pause model)
    // ──────────────────────────────────────────────────────────────────────────
    //
    //  This vault is a BeaconProxy and is therefore EXEMPT from Flap Rule 009's emergency-withdraw requirement
    //  (emergencyWithdrawNative / emergencyWithdrawToken). Per Flap's onboarding guidance, the sole emergency
    //  mechanism is the Guardian-only beacon upgrade: the factory's `upgradeVaultImplementation` (Guardian-gated,
    //  behind a 2-day timelock) can ship a fixed implementation if the vault ever reaches a stuck/compromised
    //  state. There is intentionally NO operational pause and NO direct fund-drain hatch anywhere in this vault —
    //  removing them eliminates a guardian DOS/rug vector (Rule 001 No-DOS / Rule 003 fairness) while keeping the
    //  economic egress guards (per-fill/per-window caps, deviation band, staleness) as the wall on keeper fills.
    //  Claims are always open; `buyMiningContract` always runs during the season. See the factory for the upgrade
    //  path and `lockVaultUpgrades()` for the optional immutability commitment.

    // ──────────────────────────────────────────────────────────────────────────
    //  Keeper / oracle configuration (guardian) — safe-by-default, tunable
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Set/replace the Chainlink feeds used to price keeper RFQ fills. Both feeds MUST be 8-decimal.
    /// @dev should-fix #9: changing feeds DISARMS the deviation band (referencePrice = 0) — the guardian must
    ///      consciously re-arm the reference against the new feed (and re-set caps) before sells can run again.
    function setPriceFeeds(address _rewardPriceFeed, address _bnbPriceFeed) external onlyGuardian {
        require(_rewardPriceFeed != address(0) && _bnbPriceFeed != address(0), unicode"Bad feed / 预言机无效");
        require(AggregatorV3Interface(_rewardPriceFeed).decimals() == 8, unicode"Reward feed not 8dec / 奖励预言机非8位");
        require(AggregatorV3Interface(_bnbPriceFeed).decimals() == 8, unicode"BNB feed not 8dec / BNB预言机非8位");
        rewardPriceFeed = _rewardPriceFeed;
        bnbPriceFeed = _bnbPriceFeed;
        referencePrice = 0; // disarm the band on a feed change (conscious re-arm required)
        emit ReferencePriceSet(0);
        emit KeeperConfigured(_rewardPriceFeed, _bnbPriceFeed, keeperPremiumBps);
    }

    /// @notice Arm/adjust the absolute BNB egress caps (must-fix #1b/#1c). Both default to 0 (sells disabled).
    /// @dev blocker #4b: enabling sells (either cap > 0) REQUIRES the deviation band to be armed first
    ///      (referencePrice != 0), so the guardian can never open egress with a blind/unarmed oracle band.
    function setKeeperLimits(uint256 _maxBnbOutPerFill, uint256 _maxBnbOutPerWindow) external onlyGuardian {
        if (_maxBnbOutPerFill > 0 || _maxBnbOutPerWindow > 0) {
            require(referencePrice != 0, unicode"Arm reference price first / 请先设定参考价");
        }
        maxBnbOutPerFill = _maxBnbOutPerFill;
        maxBnbOutPerWindow = _maxBnbOutPerWindow;
        emit KeeperLimitsSet(_maxBnbOutPerFill, _maxBnbOutPerWindow);
    }

    /// @notice Tune the deviation band width and per-feed staleness windows (must-fix #2).
    /// @dev Per-feed bounds: BNB/USD updates 24/7 so its staleness is clamped tight (≤ MAX_BNB_FEED_STALE = 1d);
    ///      NVDA/USD freezes off-hours so its staleness is generous (per Flap #8, weekend buys keep operating) but
    ///      still capped at MAX_REWARD_FEED_STALE = 30d so a genuinely dead feed always reverts (safety wall).
    function setOracleGuards(uint256 _priceDeviationBps, uint256 _bnbFeedMaxStale, uint256 _rewardFeedMaxStale)
        external
        onlyGuardian
    {
        require(_priceDeviationBps <= BPS_DENOM, unicode"Bad deviation / 偏差无效");
        require(_bnbFeedMaxStale > 0 && _rewardFeedMaxStale > 0, unicode"Bad staleness / 过期阈值无效");
        require(_bnbFeedMaxStale <= MAX_BNB_FEED_STALE, unicode"BNB staleness too loose / BNB过期阈值过松");
        require(_rewardFeedMaxStale <= MAX_REWARD_FEED_STALE, unicode"Reward staleness too loose / 奖励过期阈值过松");
        priceDeviationBps = _priceDeviationBps;
        bnbFeedMaxStale = _bnbFeedMaxStale;
        rewardFeedMaxStale = _rewardFeedMaxStale;
        emit OracleGuardsSet(_priceDeviationBps, _bnbFeedMaxStale, _rewardFeedMaxStale);
    }

    /// @notice Arm/move the NVDA/USD reference price for the deviation band. Must be a fresh, live value
    ///         (validated against the feed) to keep the band meaningful; passing 0 disables the band.
    function setReferencePrice(uint256 newReference) external onlyGuardian {
        if (newReference != 0) {
            uint256 live = _readFeed(rewardPriceFeed, rewardFeedMaxStale);
            uint256 diff = newReference > live ? newReference - live : live - newReference;
            // The armed reference must itself be within the band of the live feed (no arbitrarily-wide reference).
            require(diff * BPS_DENOM <= live * priceDeviationBps, unicode"Reference off-market / 参考价偏离");
        }
        referencePrice = newReference;
        emit ReferencePriceSet(newReference);
    }

    /// @notice Guardian sets the keeper premium directly, clamped to [MIN_PREMIUM_BPS, MAX_PREMIUM_BPS].
    function setKeeperPremium(uint256 bps) external onlyGuardian {
        require(bps >= MIN_PREMIUM_BPS && bps <= MAX_PREMIUM_BPS, unicode"Premium out of range / 溢价超范围");
        keeperPremiumBps = bps;
        emit KeeperPremiumSet(bps);
    }

    // NOTE: there is intentionally NO emergencyRescueReward / pauseManager and NO acquisition pause. The reward
    // token (NVDAB) is only ever moved by miners' own `claimRewards`. If the regulated reward token were ever
    // permanently blocked for the vault, recovery is the Guardian-only beacon upgrade (see the factory) — not an
    // operator drain hatch. This keeps the vault free of any privileged path that could touch miners' reward.

    // ──────────────────────────────────────────────────────────────────────────
    //  Keeper views
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Snapshot of keeper-relevant state for ops/keepers/UI.
    function getKeeperStats()
        external
        view
        returns (
            uint256 premiumBps,
            uint256 perFillCap,
            uint256 perWindowCap,
            uint256 windowUsed,
            uint256 windowResetsAt,
            uint256 refPrice,
            uint256 lastFillAt
        )
    {
        premiumBps = keeperPremiumBps;
        perFillCap = maxBnbOutPerFill;
        perWindowCap = maxBnbOutPerWindow;
        windowUsed = block.timestamp >= windowStart + WINDOW ? 0 : bnbOutThisWindow;
        windowResetsAt = windowStart + WINDOW;
        refPrice = referencePrice;
        lastFillAt = lastFillTimestamp;
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Economic agent (AI oracle) — autonomous clamped premium levers, NO burn
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Guardian configures the AI oracle + trigger service + epoch params. Set provider/trigger to
    ///         address(0) to use the chain default provider / disable the trigger loop.
    function configureAgent(
        address _provider,
        address _trigger,
        uint256 _modelId,
        uint256 _reasonFee,
        uint64 _epochInterval
    ) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        flapAIProvider = _provider;
        flapTriggerService = _trigger;
        aiModelId = _modelId;
        aiReasonFee = _reasonFee;
        epochInterval = _epochInterval;
        emit AgentConfigured(_provider, _trigger, _modelId);
    }

    function setAutoTrigger(bool on) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        autoTriggerEnabled = on;
    }

    /// @notice Guardian kicks off the autonomous epoch loop (arms the first trigger).
    function startEpochLoop() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        autoTriggerEnabled = true;
        _armNextEpoch();
    }

    /// @notice Manually request an economic decision (guardian/ops).
    function requestReasoning() external returns (uint256 requestId) {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        requestId = _requestReasoning();
    }

    /// @notice Trigger-service callback: at each epoch, re-arm and ask the oracle for a decision.
    function trigger(uint256 requestId) external override nonReentrant {
        require(msg.sender == flapTriggerService, unicode"Only trigger service / 仅限触发服务");
        if (!autoTriggerEnabled) return;
        // B2 fix: bind the callback to the pending trigger id and consume it (anti replay/stale; retryUndelivered is public)
        require(requestId == lastTriggerRequestId && lastTriggerRequestId != 0, unicode"Stale/unknown trigger / 触发ID无效");
        lastTriggerRequestId = 0;
        _armNextEpoch();
        _requestReasoning();
    }

    /// @notice AI oracle callback delivering the chosen lever (0..LEVER_COUNT-1).
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal override {
        // B2 fix: validate + consume the pending reasoning id BEFORE acting, so a stale/replayed fulfillment
        // (retryUndelivered is callable by anyone) can't re-apply an obsolete economic decision to fresh funds.
        require(requestId == lastReasoningRequestId && lastReasoningRequestId != 0, unicode"Stale/unknown reasoning / 推理ID无效");
        lastReasoningRequestId = 0;
        require(choice < LEVER_COUNT, unicode"Invalid lever / 无效杠杆");
        lastLever = choice;
        _applyLever(choice);
        emit LeverApplied(requestId, choice);
    }

    function _onFlapAIRequestRefunded(uint256 requestId) internal override {
        if (requestId == lastReasoningRequestId) lastReasoningRequestId = 0; // free the pending slot for a clean retry
        emit ReasoningRefunded(requestId);
    }

    function lastRequestId() public view override returns (uint256) {
        return lastReasoningRequestId;
    }

    /// @dev Prefer the configured provider (testing/ops); fall back to the chain-default provider.
    function _getFlapAIProvider() internal view override returns (address) {
        if (flapAIProvider != address(0)) return flapAIProvider;
        return super._getFlapAIProvider();
    }

    function _requestReasoning() internal returns (uint256 requestId) {
        address provider = _getFlapAIProvider();
        requestId = IFlapAIProvider(provider).reason{value: aiReasonFee}(aiModelId, _buildPrompt(), LEVER_COUNT);
        lastReasoningRequestId = requestId;
        lastEpochAt = block.timestamp;
        emit ReasoningRequested(requestId);
    }

    function _armNextEpoch() internal {
        if (flapTriggerService == address(0) || epochInterval == 0) return;
        uint256 fee = IFlapTriggerService(flapTriggerService).getFee();
        if (address(this).balance < fee) return;
        lastTriggerRequestId =
            IFlapTriggerService(flapTriggerService).requestTrigger{value: fee}(uint64(block.timestamp + epochInterval));
    }

    /// @dev Applies the chosen lever. ALL levers are low-risk, reversible, and execute immediately: the only state
    ///      they touch is the keeper premium, hard-clamped to [MIN_PREMIUM_BPS, MAX_PREMIUM_BPS] = [1.02, 1.04]
    ///      (Flap's recommended NVDAB band). There is NO pause lever and NO burn lever — the AI can never stop the
    ///      vault, drain it, or move the premium outside Flap's band. The premium is the keeper's fill incentive.
    function _applyLever(uint8 choice) internal {
        if (choice == 0 || choice == 3) {
            return; // 0 HOLD · 3 RETAIN reserve (no-op)
        } else if (choice == 1) {
            // RAISE_PREMIUM: more attractive to keepers (faster conversion of accumulated BNB), clamp to MAX.
            uint256 next = keeperPremiumBps + PREMIUM_STEP_BPS;
            keeperPremiumBps = next > MAX_PREMIUM_BPS ? MAX_PREMIUM_BPS : next;
            emit KeeperPremiumSet(keeperPremiumBps);
        } else if (choice == 2) {
            // LOWER_PREMIUM: more value retained for miners (slower conversion), clamp to MIN (never < +2%).
            uint256 cur = keeperPremiumBps;
            keeperPremiumBps = cur > MIN_PREMIUM_BPS + PREMIUM_STEP_BPS ? cur - PREMIUM_STEP_BPS : MIN_PREMIUM_BPS;
            emit KeeperPremiumSet(keeperPremiumBps);
        }
    }

    function _buildPrompt() internal pure returns (string memory) {
        return
        "You are the RAM vault economic agent for a real-yield mining vault. The vault holds BNB from real trading fees and acquires tokenized NVIDIA (NVDAB) from permissionless keepers at the Chainlink oracle price plus a small clamped premium, then shares it by mining power. You regulate ONLY the keeper premium. Choose ONE lever (reply with the integer 0-3). NO token burns, NO pause. 0=HOLD; 1=RAISE_PREMIUM (more keepers, faster conversion of BNB into NVDA, costs miners a little); 2=LOWER_PREMIUM (more value to miners, slower conversion); 3=RETAIN reserve. The premium is clamped to 102%-104% (Flap's recommended NVDAB band). Consider the recent fill-rate (lastFillTimestamp) and BNB reserve before deciding. Use the ave_token_info tool for market data first.";
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Plans
    // ──────────────────────────────────────────────────────────────────────────

    function _plan(uint256 planId)
        internal
        view
        returns (uint256 priceWei, uint256 power, uint256 durationSeconds, string memory name)
    {
        if (planId == 0) {
            (priceWei, power, durationSeconds, name) = (basePriceWei, 10, 1 days, "Micro Rig");
        } else if (planId == 1) {
            (priceWei, power, durationSeconds, name) = (basePriceWei * 3, 40, 7 days, "Core Rig");
        } else if (planId == 2) {
            (priceWei, power, durationSeconds, name) = (basePriceWei * 8, 130, 30 days, "Mega Rig");
        } else if (planId == 3) {
            (priceWei, power, durationSeconds, name) = (basePriceWei * 20, 420, 90 days, "Hyper Rig");
        } else {
            revert(unicode"Invalid plan / 无效套餐");
        }
        require(priceWei > 0 && power > 0 && durationSeconds > 0, unicode"Bad plan params / 套餐参数错误");
    }
}

/// @title RamMiningBeaconFactory
/// @notice Flap V2 factory for launching RamMiningVault BeaconProxy instances. Upgrades are timelocked.
contract RamMiningBeaconFactory is VaultFactoryBaseV2 {
    address public immutable beacon;

    uint256 public constant UPGRADE_DELAY = 2 days;
    address public pendingImplementation;
    uint256 public pendingImplementationReadyAt;

    event UpgradeScheduled(address indexed newImplementation, uint256 readyAt);
    event UpgradeExecuted(address indexed newImplementation);
    event UpgradeCancelled(address indexed newImplementation);

    constructor() {
        RamMiningVaultUpgradeable impl = new RamMiningVaultUpgradeable();
        beacon = address(new UpgradeableBeacon(address(impl)));
    }

    /// @dev vaultData = abi.encode(rewardToken, rewardPriceFeed, bnbPriceFeed, basePriceWei, seasonEnd).
    function newVault(address taxToken, address, address, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Only VaultPortal / 仅限 VaultPortal 调用");
        (address rewardToken, address rewardPriceFeed, address bnbPriceFeed, uint256 basePriceWei, uint256 seasonEnd) =
            abi.decode(vaultData, (address, address, address, uint256, uint256));

        vault = address(
            new BeaconProxy(
                beacon,
                abi.encodeCall(
                    RamMiningVaultUpgradeable.initialize,
                    (taxToken, rewardToken, rewardPriceFeed, bnbPriceFeed, basePriceWei, seasonEnd)
                )
            )
        );
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    // --- Timelocked beacon upgrade (staged rollout, no instant bait-and-switch) ---

    function scheduleUpgrade(address newImplementation) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(newImplementation.code.length > 0, unicode"Not a contract / 不是合约");
        pendingImplementation = newImplementation;
        pendingImplementationReadyAt = block.timestamp + UPGRADE_DELAY;
        emit UpgradeScheduled(newImplementation, pendingImplementationReadyAt);
    }

    function executeUpgrade() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(pendingImplementation != address(0), unicode"No pending upgrade / 无待处理升级");
        require(block.timestamp >= pendingImplementationReadyAt, unicode"Timelock not elapsed / 时间锁未到");
        address impl = pendingImplementation;
        pendingImplementation = address(0);
        pendingImplementationReadyAt = 0;
        UpgradeableBeacon(beacon).upgradeTo(impl);
        emit UpgradeExecuted(impl);
    }

    function cancelUpgrade() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        address impl = pendingImplementation;
        pendingImplementation = address(0);
        pendingImplementationReadyAt = 0;
        emit UpgradeCancelled(impl);
    }

    function lockVaultUpgrades() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).renounceOwnership();
    }

    function isVaultUpgradesLocked() external view returns (bool locked) {
        locked = UpgradeableBeacon(beacon).owner() == address(0);
    }

    function beaconImplementation() external view returns (address implementation) {
        implementation = UpgradeableBeacon(beacon).implementation();
    }

    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, "RAM Mining vault supports native BNB only.");
        }
        return (true, "");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Launch a RAM Mining Vault. Users buy BNB rig contracts to earn tokenized NVIDIA, acquired from keepers at the Chainlink oracle price plus a small clamped premium and funded by the RAM token's real trading fees, shared by mining power. Provide the reward token (NVDAB), the NVDA/USD and BNB/USD Chainlink feeds, the Micro rig base price, and the season end.";
        schema.fields = new FieldDescriptor[](5);
        schema.fields[0] = FieldDescriptor("rewardToken", "address", "Tokenized NVIDIA reward token (NVDAB)", 0);
        schema.fields[1] = FieldDescriptor("rewardPriceFeed", "address", "Chainlink NVDA/USD price feed (8 dec)", 0);
        schema.fields[2] = FieldDescriptor("bnbPriceFeed", "address", "Chainlink BNB/USD price feed (8 dec)", 0);
        schema.fields[3] = FieldDescriptor("basePriceWei", "uint256", "Base price for Micro Rig in BNB", 18);
        schema.fields[4] = FieldDescriptor("seasonEnd", "time", "Mining season end timestamp", 0);
        schema.isArray = false;
    }
}
