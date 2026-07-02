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

/// @notice Price source for the RAM tax token (Phase-2 sink pricing). Returns the RAM price denominated in BNB
///         (wei of BNB per 1e18 RAM) plus a trust flag. `trusted == false` means a reliability gate failed
///         (stale observations / thin pool / immature TWAP / feed down) — the vault then falls back to its
///         guardian-armed price cage, always erring toward OVER-charging (more RAM burned). The oracle is NEVER
///         on the claim path and the vault NEVER reverts on oracle failure (degraded mode instead).
interface IRamPriceOracle {
    /// @dev State-updating read (records a fresh pair observation, then prices). Called by sink txs.
    function pokeAndGetPrice(address token) external returns (uint256 priceBnbPerRamE18, bool trusted);
    /// @dev View read for quotes (no observation recorded).
    function getPrice(address token) external view returns (uint256 priceBnbPerRamE18, bool trusted);
}

// ──────────────────────────────────────────────────────────────────────────────
//  Custom errors (v3): file-level, shared by the vault and the factory. Replaces
//  the audited v2 require-strings 1:1 (semantics unchanged) to free EIP-170
//  bytecode headroom for the Phase-2 economy. Names map to the old messages.
// ──────────────────────────────────────────────────────────────────────────────
error ZeroAddress();
error ZeroAmount();
error BadConfig();
error BadFeedDecimals();
error SeasonTooShort();
error InvalidPlan();
error SeasonEnded();
error TooManyRigs();
error InsufficientPayment();
error NoMiningTime();
error RigEndsTooSoon();
error RefundFailed();
error NothingToClaim();
error NoMiners();
error NoRewardReceived();
error Slippage();
error OverFillCap();
error InsufficientBnb();
error BnbTransferFailed();
error BadFeedPrice();
error RoundNotComplete();
error StaleRound();
error StaleFeed();
error ReferenceNotArmed();
error PriceOutOfBand();
error OverWindowCap();
error BadIndex();
error BadPlanParams();
error StalenessTooLoose();
error ReferenceOffMarket();
error PremiumOutOfRange();
error OnlyGuardian();
error OnlyTriggerService();
error StaleRequest();
error InvalidLever();
error OnlyVaultPortal();
error NotAuthorized();
error NotAContract();
error NoPendingUpgrade();
error TimelockNotElapsed();
// --- Phase-2 economy (v3) ---
error RamPricingNotArmed();
error RigExpired();
error InvalidUpgrade();
error UnexpectedValue();
error NothingToRepair();
error NoRamReceived();

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

    // --- Phase-2 economy (v3): wear + RAM sinks ---
    /// @dev Wear is PHYSICS (time-only), snapshot at mint, NEVER derived from dollars earned (economy spec §5).
    ///      It is implemented as PARTIAL SUB-EXPIRATIONS on the audited bucket machinery: at buy time the rig's
    ///      deterministic wear steps are registered in `powerExpiringAtBucket` exactly like the audited full-expiry
    ///      path, so `_settleExpiries` (UNCHANGED) settles them and freezes the accumulator at each step bucket.
    uint256 public constant WEAR_EPOCH = 3 days; // one wear step every 3 days
    uint256 public constant WEAR_KEEP_BPS = 9500; // each step keeps 95% of the current level (d = 0.05)
    uint256 public constant WEAR_FLOOR_BPS = 4700; // effective power never decays below 47% of the plan power
    // NOTE: a rig's lifetime is its AUDITED plan duration (1d/7d/30d/90d, season-capped) — unchanged from the
    // contract Flap reviewed. The wear ladder runs WITHIN that lifetime; repairs/upgrades NEVER extend it.
    uint256 public constant RAM_BURN_BPS = 8500; // 85% of every RAM sink payment is burned…
    address public constant RAM_BURN_ADDR = 0x000000000000000000000000000000000000dEaD; // …to the dead address
    uint256 public constant REPAIR_AGE_PENALTY_BPS = 3000; // repair restore-cap decays linearly to −30% over the rig's plan duration
    uint256 public constant MIN_REPAIR_COST_BPS = 2500; // guardian-tunable repair cost, hard-bounded [25%, 75%]
    uint256 public constant MAX_REPAIR_COST_BPS = 7500; //   of the rig's plan price

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
        uint256 power; // start level of the CURRENT wear schedule (plan power at mint; restored level after repair)
        uint256 startTime; // mint time — anchors the plan-duration lifetime (never moved by repair/upgrade)
        uint256 endTime;
        uint256 endBucket;
        uint256 rewardDebt; // accRewardPerPower checkpoint for this rig
        uint256 claimed; // reward token already claimed from this rig
        uint256 paidNative;
        uint256 wearStart; // start of the CURRENT wear schedule (mint, or last repair/upgrade)
        uint256 accrued; // reward checkpointed at repair/upgrade (claimable, survives rescheduling)
    }

    mapping(address => Rig[]) private userRigs;

    // --- Phase-2 economy (v3) state ---
    mapping(address => bool) public hasEnteredBefore; // first rig per wallet is paid in BNB; all later ones in RAM
    address public ramPriceOracle; // IRamPriceOracle for the tax token (guardian-set; RAM sinks disabled until set)
    uint256 public ramPriceCageMin; // BNB-per-RAM floor (18 dec): degraded-mode price + lower clamp. 0 = not armed
    uint256 public ramPriceCageMax; // BNB-per-RAM ceiling (18 dec): upper clamp on the trusted market read
    uint256 public repairCostBps; // repair price as bps of the rig's plan price (bounded [2500, 7500])
    /// @dev Dedicated treasury wallet receiving the 15% share of every RAM sink payment (paid out in the same
    ///      tx). Set ONCE at initialize via vaultData — there is deliberately NO setter: the destination is
    ///      immutable per vault, changeable only via the Guardian-gated, timelocked beacon upgrade. Kept separate
    ///      from the factory dev-lock wallet by design (ops separation).
    address public ramTreasuryWallet;
    uint256 public totalRamTreasuryPaid; // lifetime 15% treasury share of RAM sink payments (paid to ramTreasuryWallet)
    uint256 public totalRamPaid; // lifetime RAM received through sinks
    uint256 public totalRamBurned; // lifetime RAM burned to RAM_BURN_ADDR

    /// @dev Storage gap for safe future upgrades (append-only): when adding new state vars, append them and
    ///      shrink this gap so the beacon-proxy storage layout never collides. v2 is a fresh deployment
    ///      (new beacon implementation), so this reflects the new layout, not an upgrade-in-place of v1.
    ///      v3 appended 8 slots (Phase-2 economy) → gap shrunk 44 → 36. NOTE: the Rig struct gained fields, which
    ///      is safe ONLY because v3 deploys as a FRESH beacon implementation for NEW vaults (never an in-place
    ///      upgrade of a live v2 vault's storage).
    uint256[35] private __gap;

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
    // --- Phase-2 economy (v3) ---
    event RigBoughtWithRam(address indexed user, uint256 indexed rigId, uint256 ramPaid, uint256 ramBurned);
    event RigRepaired(address indexed user, uint256 indexed rigId, uint256 ramPaid, uint256 restoredPower);
    event RigUpgraded(
        address indexed user, uint256 indexed rigId, uint256 indexed newPlanId, uint256 ramPaid, uint256 newPower
    );
    event RamPriceOracleSet(address oracle);
    event RamPriceCageSet(uint256 cageMin, uint256 cageMax);
    event RepairCostSet(uint256 repairCostBps);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _taxToken,
        address _rewardToken,
        address _rewardPriceFeed,
        address _bnbPriceFeed,
        uint256 _basePriceWei,
        uint256 _seasonEnd,
        address _ramPriceOracle,
        uint256 _ramCageMin,
        uint256 _ramCageMax,
        address _ramTreasuryWallet
    ) external initializer {
        __ReentrancyGuard_init();
        if (!(_taxToken != address(0))) revert ZeroAddress();
        if (!(_rewardToken != address(0))) revert ZeroAddress();
        if (!(_rewardPriceFeed != address(0))) revert ZeroAddress();
        if (!(_bnbPriceFeed != address(0))) revert ZeroAddress();
        // should-fix #7: the quote math assumes 8-decimal Chainlink feeds (the two feeds cancel). Enforce it so a
        // mis-wired feed with different decimals can never silently mis-price the keeper payout.
        if (!(AggregatorV3Interface(_rewardPriceFeed).decimals() == 8)) revert BadFeedDecimals();
        if (!(AggregatorV3Interface(_bnbPriceFeed).decimals() == 8)) revert BadFeedDecimals();
        if (!(_basePriceWei > 0)) revert BadConfig();
        if (!(_seasonEnd >= block.timestamp + 1 days)) revert SeasonTooShort();

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
        // Phase-2: the LAUNCHER may arm the RAM sink pricing at creation via vaultData (the vault is then
        // Phase-2-live from block one, no Guardian round-trip needed — consistent with the dev already choosing
        // the reward token and feeds in vaultData). Zeros = DISARMED: rig #2+/repair/upgrade revert
        // RamPricingNotArmed until armed. The Guardian keeps the setters either way. Rig #1 in BNB always works.
        if (!(_ramCageMin <= _ramCageMax)) revert BadConfig();
        if (!(_ramTreasuryWallet != address(0))) revert ZeroAddress();
        ramPriceOracle = _ramPriceOracle;
        ramPriceCageMin = _ramCageMin;
        ramPriceCageMax = _ramCageMax;
        ramTreasuryWallet = _ramTreasuryWallet;
        repairCostBps = 4000; // 40% of plan price per repair (guardian-tunable within [25%, 75%])
    }

    /// @notice Accept native BNB. The RAM tax token's TaxProcessor sends the `market` fee share here, and the
    ///         vault can also be seeded with BNB. No external calls, no loops.
    receive() external payable {}

    // ──────────────────────────────────────────────────────────────────────────
    //  Buy / Claim
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Buy a mining rig. Phase-2 two-phase economy: the FIRST rig of a wallet is paid in native BNB
    ///         (the entry — also the honest per-wallet Sybil limiter); every later rig is paid in the RAM tax
    ///         token, converted from the plan's BNB price via the RAM price oracle (85% burned / 15% treasury).
    ///         Rigs keep their AUDITED per-plan durations (season-capped) and wear 5% every 3 days to a 47% floor.
    function buyMiningContract(uint256 planId) external payable nonReentrant {
        if (!(planId < PLAN_COUNT)) revert InvalidPlan();
        if (!(block.timestamp < seasonEnd)) revert SeasonEnded();

        _settleExpiries();
        _compact(msg.sender);
        if (!(userRigs[msg.sender].length < MAX_CONTRACTS_PER_USER)) revert TooManyRigs();

        (uint256 priceWei, uint256 power, uint256 duration,) = _plan(planId);

        uint256 start = block.timestamp;
        uint256 end = start + duration; // AUDITED per-plan duration (1d/7d/30d/90d), season-capped below
        if (end > seasonEnd) {
            end = seasonEnd;
        }
        if (!(end > start)) revert NoMiningTime();
        uint256 endBucket = end / BUCKET;
        // BUG FIX (last-bucket brick): _settleExpiries() above advanced lastSettledBucket to nowBucket and the
        // settle loop only scans buckets > lastSettledBucket. A rig whose endBucket has already been settled
        // (e.g. near seasonEnd, when end is capped into the current/settled bucket) would inflate totalActivePower
        // forever (its power never gets subtracted) and read accSnapshotAtBucket==0 → owed underflow → claims
        // brick for everyone. Reject such rigs: their power must expire in a future, not-yet-settled bucket.
        if (!(endBucket > lastSettledBucket)) revert RigEndsTooSoon();

        uint256 ramPaid;
        if (!hasEnteredBefore[msg.sender]) {
            // ── entry rig: BNB path (the audited v2 path, unchanged) ──
            hasEnteredBefore[msg.sender] = true;
            if (!(msg.value >= priceWei)) revert InsufficientPayment();
            // Refund excess BNB before recording state (safe-order; full revert on failure).
            uint256 refund = msg.value - priceWei;
            if (refund > 0) {
                (bool ok,) = msg.sender.call{value: refund}("");
                if (!(ok)) revert RefundFailed();
            }
            totalNativePaid += priceWei;
        } else {
            // ── growth rig: RAM path (Phase-2). No BNB accepted here — the plan price converts to RAM units. ──
            if (msg.value != 0) revert UnexpectedValue();
            ramPaid = _chargeRam(priceWei);
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
                paidNative: ramPaid == 0 ? priceWei : 0,
                wearStart: start,
                accrued: 0
            })
        );

        // Register the full wear ladder as partial sub-expirations on the audited bucket machinery: the
        // registered deltas + the end remainder telescope to exactly `power`, matching totalActivePower.
        totalActivePower += power;
        _applySchedule(power, _floorLevel(planId), start, end, endBucket, true, 0);
        totalContractsSold += 1;

        emit RigBought(msg.sender, lastContractId, planId, power, priceWei, start, end);
        if (ramPaid > 0) {
            emit RigBoughtWithRam(msg.sender, lastContractId, ramPaid, (ramPaid * RAM_BURN_BPS) / BPS_DENOM);
        }
    }

    // @dev Claims are NEVER gated by anything — there is no pause anywhere in this vault (Flap's no-pause model:
    //      recovery is the Guardian-only beacon upgrade, not an operational pause). Users can always withdraw.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        amount = _claim(msg.sender, msg.sender);
    }

    /// @notice Claim accumulated rewards to a different recipient — useful if the caller's own address became
    ///         non-compliant for the (regulated) reward token but a fresh recipient can still receive it.
    /// @dev Flap pre-audit #4: the open `to` parameter is BY DESIGN and is NOT an access-control gap. The caller
    ///      (`msg.sender`) can only ever settle and claim THEIR OWN rigs (`_claim(msg.sender, to)` reads
    ///      `userRigs[msg.sender]`); `to` is purely the payout recipient. No caller can ever claim, redirect, or
    ///      touch another miner's rewards. The only effect of an open `to` is letting a compliance-blocked owner
    ///      route their own NVDAB to a fresh compliant address.
    function claimRewardsTo(address to) external nonReentrant returns (uint256 amount) {
        if (!(to != address(0))) revert ZeroAddress();
        amount = _claim(msg.sender, to);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Phase-2 economy (v3): repair & upgrade — RAM sinks (85% burn / 15% treasury wallet)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Repair a live rig: pay RAM (85% burned) to reset its wear ladder NOW at a restored level. The
    ///         restore cap decays linearly with the rig's AGE (100% → 70% of plan power over its plan duration),
    ///         so old rigs restore less — and the lifetime wall itself is NEVER extended. Claimable NVDA is untouched.
    function repairRig(uint256 index) external nonReentrant {
        _settleExpiries();
        Rig[] storage rigs = userRigs[msg.sender];
        if (!(index < rigs.length)) revert BadIndex();
        Rig storage r = rigs[index];
        if (!(block.timestamp < r.endTime && block.timestamp / BUCKET < r.endBucket)) revert RigExpired();

        (uint256 planPrice, uint256 planPower, uint256 planDuration,) = _plan(r.planId);
        uint256 capBps = BPS_DENOM - ((block.timestamp - r.startTime) * REPAIR_AGE_PENALTY_BPS) / planDuration;
        uint256 restored = (planPower * capBps) / BPS_DENOM;
        uint256 floorLvl = _floorLevel(r.planId);
        if (restored < floorLvl) restored = floorLvl;
        if (!(restored > _rigCurrentPower(r))) revert NothingToRepair();

        uint256 ramPaid = _chargeRam((planPrice * repairCostBps) / BPS_DENOM);
        _reschedule(r, restored, r.planId);
        emit RigRepaired(msg.sender, r.id, ramPaid, restored);
    }

    /// @notice Upgrade a live rig to a higher tier: pay the plan-price DIFFERENCE in RAM (85% burned). The rig
    ///         becomes the new tier at full power with a FRESH wear ladder (new hardware), but its lifetime
    ///         (ORIGINAL plan duration from mint) is NEVER extended — no buying a 1d Micro to smuggle a 90d Hyper.
    function upgradeRig(uint256 index, uint256 newPlanId) external nonReentrant {
        if (!(newPlanId < PLAN_COUNT)) revert InvalidPlan();
        _settleExpiries();
        Rig[] storage rigs = userRigs[msg.sender];
        if (!(index < rigs.length)) revert BadIndex();
        Rig storage r = rigs[index];
        if (!(block.timestamp < r.endTime && block.timestamp / BUCKET < r.endBucket)) revert RigExpired();
        if (!(newPlanId > r.planId)) revert InvalidUpgrade();

        (uint256 oldPrice,,,) = _plan(r.planId);
        (uint256 newPrice, uint256 newPower,,) = _plan(newPlanId);
        uint256 ramPaid = _chargeRam(newPrice - oldPrice);
        _reschedule(r, newPower, newPlanId);
        emit RigUpgraded(msg.sender, r.id, newPlanId, ramPaid, newPower);
    }

    /// @dev Charge a BNB-denominated cost in RAM units through the oracle+cage price, split 85% burn (to
    ///      RAM_BURN_ADDR) / 15% to the dedicated, immutable treasury wallet (same tx). Delta-measured so a
    ///      taxed/fee-on-transfer path can't corrupt accounting. Reverts only when the RAM pricing is not armed
    ///      (safe-by-default) or nothing arrives.
    function _chargeRam(uint256 bnbCost) internal returns (uint256 received) {
        uint256 price = _cagedRamPrice(true);
        uint256 units = (bnbCost * 1e18) / price;
        if (!(units > 0)) revert ZeroAmount();

        IERC20 ram = IERC20(taxToken);
        uint256 balBefore = ram.balanceOf(address(this));
        ram.safeTransferFrom(msg.sender, address(this), units);
        received = ram.balanceOf(address(this)) - balBefore;
        if (!(received > 0)) revert NoRamReceived();

        uint256 burnAmt = (received * RAM_BURN_BPS) / BPS_DENOM;
        if (burnAmt > 0) {
            ram.safeTransfer(RAM_BURN_ADDR, burnAmt);
        }
        uint256 treasuryShare = received - burnAmt;
        if (treasuryShare > 0) {
            ram.safeTransfer(ramTreasuryWallet, treasuryShare);
        }
        totalRamTreasuryPaid += treasuryShare;
        totalRamPaid += received;
        totalRamBurned += burnAmt;
    }

    /// @dev Resolve the RAM price (BNB wei per 1e18 RAM) through the oracle, then the guardian cage — the
    ///      judge-mandated fail-safe shape: the market read is used ONLY when the oracle reports it trusted;
    ///      any failure (untrusted / zero / oracle reverting) degrades to the cage FLOOR, which assumes the
    ///      CHEAPEST RAM and therefore charges the MOST units (over-charging is the safe direction for a burn
    ///      sink). A trusted read is clamped into [cageMin, cageMax]. Never on the claim path.
    function _cagedRamPrice(bool poke) internal returns (uint256 price) {
        address oracle = ramPriceOracle;
        uint256 cageMin = ramPriceCageMin;
        if (oracle == address(0) || cageMin == 0) revert RamPricingNotArmed();
        bool trusted;
        uint256 p;
        if (poke) {
            try IRamPriceOracle(oracle).pokeAndGetPrice(taxToken) returns (uint256 p_, bool t_) {
                (p, trusted) = (p_, t_);
            } catch {}
        } else {
            try IRamPriceOracle(oracle).getPrice(taxToken) returns (uint256 p_, bool t_) {
                (p, trusted) = (p_, t_);
            } catch {}
        }
        if (!trusted || p == 0) {
            return cageMin;
        }
        uint256 cageMax = ramPriceCageMax;
        if (p < cageMin) return cageMin;
        if (p > cageMax) return cageMax;
        return p;
    }

    /// @dev View twin of _cagedRamPrice for quoting (view context — cannot poke).
    function _cagedRamPriceView() internal view returns (uint256 price, bool trusted) {
        address oracle = ramPriceOracle;
        uint256 cageMin = ramPriceCageMin;
        if (oracle == address(0) || cageMin == 0) revert RamPricingNotArmed();
        uint256 p;
        try IRamPriceOracle(oracle).getPrice(taxToken) returns (uint256 p_, bool t_) {
            (p, trusted) = (p_, t_);
        } catch {}
        if (!trusted || p == 0) {
            return (cageMin, false);
        }
        uint256 cageMax = ramPriceCageMax;
        if (p < cageMin) p = cageMin;
        if (p > cageMax) p = cageMax;
        return (p, true);
    }

    /// @notice Quote a rig purchase (rig #2+) in RAM units at the current caged price.
    function quoteRigInRam(uint256 planId) external view returns (uint256 ramUnits, bool trusted) {
        (uint256 priceWei,,,) = _plan(planId);
        uint256 price;
        (price, trusted) = _cagedRamPriceView();
        ramUnits = (priceWei * 1e18) / price;
    }

    /// @notice Quote a repair of `user`'s rig at `index` in RAM units at the current caged price.
    function quoteRepairInRam(address user, uint256 index) external view returns (uint256 ramUnits, bool trusted) {
        if (!(index < userRigs[user].length)) revert BadIndex();
        (uint256 planPrice,,,) = _plan(userRigs[user][index].planId);
        uint256 price;
        (price, trusted) = _cagedRamPriceView();
        ramUnits = (((planPrice * repairCostBps) / BPS_DENOM) * 1e18) / price;
    }

    /// @notice Quote a tier upgrade of `user`'s rig at `index` to `newPlanId` in RAM units.
    function quoteUpgradeInRam(address user, uint256 index, uint256 newPlanId)
        external
        view
        returns (uint256 ramUnits, bool trusted)
    {
        if (!(index < userRigs[user].length)) revert BadIndex();
        if (!(newPlanId < PLAN_COUNT)) revert InvalidPlan();
        uint256 oldPlanId = userRigs[user][index].planId;
        if (!(newPlanId > oldPlanId)) revert InvalidUpgrade();
        (uint256 oldPrice,,,) = _plan(oldPlanId);
        (uint256 newPrice,,,) = _plan(newPlanId);
        uint256 price;
        (price, trusted) = _cagedRamPriceView();
        ramUnits = ((newPrice - oldPrice) * 1e18) / price;
    }

    /// @dev Single accounting+transfer claim path. Effects (rewardDebt/claimed) are mutated BEFORE the one and
    ///      only `safeTransfer` at the end; if that transfer reverts (reward token paused / recipient non-compliant)
    ///      the whole tx rolls back atomically, leaving this miner's pending intact and OTHER miners' accounting
    ///      untouched. No transfers happen inside the rig loop (would open reentrancy). (must-fix #8 alignment.)
    ///      v3: per-rig owed is the wear-tranche sum (see _rigPending); the debt reset to the CURRENT accumulator
    ///      zeroes every already-expired tranche (their frozen snapshots are ≤ acc now) and re-bases live ones.
    function _claim(address user, address to) internal returns (uint256 amount) {
        _settleExpiries();
        Rig[] storage rigs = userRigs[user];
        for (uint256 i = 0; i < rigs.length; i++) {
            Rig storage r = rigs[i];
            uint256 owed = _rigPending(r);
            if (owed > 0) {
                r.rewardDebt = accRewardPerPower;
                r.accrued = 0;
                r.claimed += owed;
                amount += owed;
            }
        }
        if (!(amount > 0)) revert NothingToClaim();

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
        if (!(rwaAmount > 0)) revert ZeroAmount();
        // should-fix #6: settle expiries BEFORE checking effective power, so no BNB leaves once power has lapsed
        // (e.g. past seasonEnd, where all power is settled to 0 → reverts here instead of paying a keeper).
        _settleExpiries();
        if (!(totalActivePower > 0)) revert NoMiners();

        // must-fix #5/#8: pull FIRST, measure the REAL received delta, and price THAT delta — so a future
        // fee-on-transfer/rebasing reward token can never make the vault overpay the keeper on a nominal amount.
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rwaAmount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
        if (!(received > 0)) revert NoRewardReceived();

        // price the actual received delta; all drain guards apply to THIS final bnbOwed.
        bnbOwed = quoteRWAToVault(received);
        if (!(bnbOwed > 0 && bnbOwed >= minBnbOut)) revert Slippage(); // keeper slippage on the FINAL owed
        if (!(bnbOwed <= maxBnbOutPerFill)) revert OverFillCap();

        // must-fix #1a: deviation band vs the armed reference price (rejects an oracle that jumped/was manipulated).
        _checkDeviationBand();
        // must-fix #1c: per-window BNB egress rate-limit (fixed/tumbling window — see _consumeWindow).
        _consumeWindow(bnbOwed);

        if (!(address(this).balance >= bnbOwed)) revert InsufficientBnb();

        _notifyReward(received); // distribute the actual delta by power
        lastFillTimestamp = block.timestamp; // liveness metric
        totalBnbPaidToKeepers += bnbOwed;

        // CEI: pay the keeper LAST (reentrancy-guarded above).
        (bool ok,) = payable(msg.sender).call{value: bnbOwed}("");
        if (!(ok)) revert BnbTransferFailed();
        emit RWASoldToVault(msg.sender, received, bnbOwed);
    }

    /// @dev Chainlink read with HARD checks (must-fix #2 & #4). Any stale/bad answer REVERTS the whole op — never
    ///      a silent zero/old price. BNB Chain is L1, so there is NO sequencer-uptime feed to consult (that's L2).
    function _readFeed(address feed, uint256 maxStale) internal view returns (uint256 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feed).latestRoundData();
        if (!(answer > 0)) revert BadFeedPrice();
        if (!(updatedAt != 0)) revert RoundNotComplete();
        if (!(answeredInRound >= roundId)) revert StaleRound();
        if (!(block.timestamp - updatedAt <= maxStale)) revert StaleFeed();
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
            if (!(maxBnbOutPerFill == 0 && maxBnbOutPerWindow == 0)) revert ReferenceNotArmed();
            return;
        }
        uint256 live = _readFeed(rewardPriceFeed, rewardFeedMaxStale);
        uint256 diff = live > ref ? live - ref : ref - live;
        if (!(diff * BPS_DENOM <= ref * priceDeviationBps)) revert PriceOutOfBand();
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
        if (!(bnbOutThisWindow + amount <= maxBnbOutPerWindow)) revert OverWindowCap();
        bnbOutThisWindow += amount;
    }

    /// @notice Credit reward tokens already held/received by the vault into the distribution accumulator.
    /// @dev Pull-pattern fallback for externally-sourced reward token (e.g. a manual top-up). Caller must approve.
    ///      Credits the REAL measured delta (must-fix #5), not the nominal `amount`.
    /// @dev Flap pre-audit #3: PERMISSIONLESS by design (intended use: manual top-ups by the team / any benefactor).
    ///      There is no economic attack surface: it is value-IN only — the donor transfers reward token to the vault
    ///      and it is credited pro-rata to ACTIVE miners via the shared `accRewardPerPower` accumulator (or buffered in
    ///      `rewardUndistributed` when no power is active). A donor can never extract value, dilute, or redirect any
    ///      miner's reward; the worst a caller can do is gift tokens to the existing miners.
    function donateReward(uint256 amount) external nonReentrant {
        if (!(amount > 0)) revert ZeroAmount();
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
        if (!(received > 0)) revert NoRewardReceived();
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

    // ──────────────────────────────────────────────────────────────────────────
    //  Wear ladder (v3) — partial sub-expirations on the audited bucket machinery
    // ──────────────────────────────────────────────────────────────────────────
    //
    //  A rig's effective power steps down 5% every WEAR_EPOCH (3d) until the 47%-of-plan floor, then holds the
    //  floor until endTime (RIG_LIFE, season-capped). Every step is REGISTERED in `powerExpiringAtBucket` at buy
    //  time, so the AUDITED `_settleExpiries` (untouched) both subtracts the step from `totalActivePower` and
    //  freezes `accSnapshotAtBucket` at that bucket — a wear step is accounting-identical to a partial expiry.
    //  All four consumers (register, unregister, pending, current-power) walk the SAME canonical ladder loop so
    //  the per-rig view can never diverge from the aggregate machinery.

    /// @dev The accumulator value applicable at a bucket boundary: the frozen snapshot once settlement passed it,
    ///      the live accumulator otherwise (no reward can land between expiry and settle — notify settles first).
    function _accAtBucket(uint256 b) internal view returns (uint256) {
        if (lastSettledBucket >= b) {
            return accSnapshotAtBucket[b];
        }
        return accRewardPerPower;
    }

    /// @dev Effective-power floor for a plan (47% of the plan's mint power).
    function _floorLevel(uint256 planId) internal view returns (uint256) {
        (, uint256 planPower,,) = _plan(planId);
        return (planPower * WEAR_FLOOR_BPS) / BPS_DENOM;
    }

    /// @dev Register (add=true) or unregister (add=false) a wear ladder in `powerExpiringAtBucket`. The step
    ///      deltas plus the end remainder telescope to exactly `startLevel`. `skipUpToBucket` skips buckets the
    ///      settle loop already consumed (used when unregistering a live rig's remaining ladder: the skipped,
    ///      already-settled steps were deducted from totalActivePower by settle; what remains telescopes to the
    ///      rig's CURRENT live level).
    function _applySchedule(
        uint256 startLevel,
        uint256 floorLvl,
        uint256 wearStart,
        uint256 endTime,
        uint256 endBucket,
        bool add,
        uint256 skipUpToBucket
    ) internal {
        uint256 lvl = startLevel;
        for (uint256 k = 1;; k++) {
            uint256 t = wearStart + k * WEAR_EPOCH;
            if (t >= endTime) break;
            uint256 next = (lvl * WEAR_KEEP_BPS) / BPS_DENOM;
            if (next < floorLvl) next = floorLvl;
            if (next == lvl) break;
            uint256 sb = t / BUCKET;
            if (sb > skipUpToBucket) {
                if (add) {
                    powerExpiringAtBucket[sb] += lvl - next;
                } else {
                    powerExpiringAtBucket[sb] -= lvl - next;
                }
            }
            lvl = next;
        }
        if (add) {
            powerExpiringAtBucket[endBucket] += lvl;
        } else {
            powerExpiringAtBucket[endBucket] -= lvl;
        }
    }

    /// @dev Pending reward of a rig = Σ over ladder tranches of tranche-power × (acc at the tranche's expiry
    ///      boundary − rig debt), plus the checkpointed `accrued` from reschedules. Expired tranches use their
    ///      frozen bucket snapshots; live ones the current accumulator — uniformly via _accAtBucket. A tranche
    ///      whose boundary settled BEFORE the rig's debt checkpoint contributes 0 (snapshot ≤ debt).
    function _rigPending(Rig storage r) internal view returns (uint256 owed) {
        uint256 debt = r.rewardDebt;
        uint256 weighted;
        uint256 lvl = r.power;
        uint256 floorLvl = _floorLevel(r.planId);
        for (uint256 k = 1;; k++) {
            uint256 t = r.wearStart + k * WEAR_EPOCH;
            if (t >= r.endTime) break;
            uint256 next = (lvl * WEAR_KEEP_BPS) / BPS_DENOM;
            if (next < floorLvl) next = floorLvl;
            if (next == lvl) break;
            uint256 accK = _accAtBucket(t / BUCKET);
            if (accK > debt) {
                weighted += (lvl - next) * (accK - debt);
            }
            lvl = next;
        }
        uint256 accEnd = _accAtBucket(r.endBucket);
        if (accEnd > debt) {
            weighted += lvl * (accEnd - debt);
        }
        owed = weighted / ACC_PRECISION + r.accrued;
    }

    /// @dev Current effective (wear-decayed) power of a rig; 0 once expired.
    function _rigCurrentPower(Rig storage r) internal view returns (uint256 lvl) {
        uint256 nowBucket = block.timestamp / BUCKET;
        if (nowBucket >= r.endBucket) return 0;
        lvl = r.power;
        uint256 floorLvl = _floorLevel(r.planId);
        for (uint256 k = 1;; k++) {
            uint256 t = r.wearStart + k * WEAR_EPOCH;
            if (t >= r.endTime) break;
            uint256 sb = t / BUCKET;
            if (nowBucket < sb) break;
            uint256 next = (lvl * WEAR_KEEP_BPS) / BPS_DENOM;
            if (next < floorLvl) next = floorLvl;
            if (next == lvl) break;
            lvl = next;
        }
    }

    /// @dev Reschedule a live rig's ladder (repair/upgrade): checkpoint its pending into `accrued`, swap the
    ///      not-yet-settled remainder of the old ladder for a fresh one starting at `newLevel` NOW, and adjust
    ///      `totalActivePower` by the live-level delta. `endTime`/`endBucket` are NEVER touched (RIG_LIFE is a
    ///      hard wall anchored at mint). Caller must have settled expiries and verified the rig is alive.
    function _reschedule(Rig storage r, uint256 newLevel, uint256 newPlanId) internal {
        uint256 pending = _rigPending(r);
        uint256 live = _rigCurrentPower(r);
        _applySchedule(r.power, _floorLevel(r.planId), r.wearStart, r.endTime, r.endBucket, false, lastSettledBucket);
        r.accrued = pending;
        r.rewardDebt = accRewardPerPower;
        r.planId = newPlanId;
        r.power = newLevel;
        r.wearStart = block.timestamp;
        _applySchedule(newLevel, _floorLevel(newPlanId), block.timestamp, r.endTime, r.endBucket, true, 0);
        totalActivePower = totalActivePower + newLevel - live;
    }

    /// @dev Removes fully-settled expired rigs (no pending) via swap-and-pop to keep the active set bounded.
    function _compact(address user) internal {
        Rig[] storage rigs = userRigs[user];
        uint256 i = 0;
        while (i < rigs.length) {
            Rig storage r = rigs[i];
            bool expired = block.timestamp / BUCKET >= r.endBucket;
            if (expired && _rigPending(r) == 0) {
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
            amount += _rigPending(rigs[i]);
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
        if (!(index < userRigs[user].length)) revert BadIndex();
        Rig storage r = userRigs[user][index];
        rigId = r.id;
        planId = r.planId;
        power = _rigCurrentPower(r); // v3: live wear-decayed power (0 once expired)
        startTime = r.startTime;
        endTime = r.endTime;
        claimed = r.claimed;
        pending = _rigPending(r);
        active = block.timestamp / BUCKET < r.endBucket;
    }

    /// @notice v3 wear detail for a rig: schedule level, live effective power, floor, and life bounds.
    function getRigWear(address user, uint256 index)
        external
        view
        returns (
            uint256 scheduleLevel,
            uint256 currentPower,
            uint256 floorPower,
            uint256 wearStartedAt,
            uint256 lifeEndsAt,
            uint256 accruedReward
        )
    {
        if (!(index < userRigs[user].length)) revert BadIndex();
        Rig storage r = userRigs[user][index];
        scheduleLevel = r.power;
        currentPower = _rigCurrentPower(r);
        floorPower = _floorLevel(r.planId);
        wearStartedAt = r.wearStart;
        lifeEndsAt = r.endTime;
        accruedReward = r.accrued;
    }

    /// @notice v3 Phase-2 economy stats (RAM sink flows + config).
    function getRamEconomyStats()
        external
        view
        returns (
            uint256 ramPaidLifetime,
            uint256 ramBurnedLifetime,
            uint256 ramTreasuryPaid,
            uint256 cageMin,
            uint256 cageMax,
            uint256 repairCost,
            address oracle
        )
    {
        ramPaidLifetime = totalRamPaid;
        ramBurnedLifetime = totalRamBurned;
        ramTreasuryPaid = totalRamTreasuryPaid;
        cageMin = ramPriceCageMin;
        cageMax = ramPriceCageMax;
        repairCost = repairCostBps;
        oracle = ramPriceOracle;
    }

    function getPlan(uint256 planId)
        external
        view
        returns (uint256 priceWei, uint256 power, uint256 durationSeconds, string memory name)
    {
        if (!(planId < PLAN_COUNT)) revert InvalidPlan();
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
            activePower += _rigCurrentPower(r); // 0 once expired; wear-decayed while live
            claimableReward += _rigPending(r);
        }
        sharePerMille = totalActivePower == 0 ? 0 : (activePower * 1000) / totalActivePower;
    }

    function description() public view override returns (string memory) {
        if (totalContractsSold == 0) {
            return "RAM Mining Vault: no rigs yet. Buy a rig with BNB to start earning tokenized NVIDIA funded by RAM trading fees.";
        }
        return "RAM Mining Vault: rigs are mining. Rewards are tokenized NVIDIA bought with real RAM trading fees and shared by mining power.";
    }

    /// @dev v3 TEST BUILD (Flap Post-Audit Step 2 recipe): the auto-generated-UI schema is intentionally
    ///      MINIMAL — RAM ships a bespoke UI artifact, so these schemas no longer feed any UI. Flap explicitly
    ///      blessed ignoring the schema findings once a bespoke UI is used (audit v2), and their Step 2 testing
    ///      recipe is to strip description()/vaultUISchema() for the simplified test factory. Restoring a full
    ///      schema for production is a P4 decision with Flap. This also frees ~4 KB of EIP-170 headroom that the
    ///      Phase-2 economy occupies.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "RamMiningVault";
        schema.description = "RAM real-yield mining vault (bespoke UI artifact; schema intentionally minimal).";
        schema.methods = new VaultMethodSchema[](0);
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
        if (!(_rewardPriceFeed != address(0) && _bnbPriceFeed != address(0))) revert ZeroAddress();
        if (!(AggregatorV3Interface(_rewardPriceFeed).decimals() == 8)) revert BadFeedDecimals();
        if (!(AggregatorV3Interface(_bnbPriceFeed).decimals() == 8)) revert BadFeedDecimals();
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
            if (!(referencePrice != 0)) revert ReferenceNotArmed();
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
        if (!(_priceDeviationBps <= BPS_DENOM)) revert BadConfig();
        if (!(_bnbFeedMaxStale > 0 && _rewardFeedMaxStale > 0)) revert BadConfig();
        if (!(_bnbFeedMaxStale <= MAX_BNB_FEED_STALE)) revert StalenessTooLoose();
        if (!(_rewardFeedMaxStale <= MAX_REWARD_FEED_STALE)) revert StalenessTooLoose();
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
            if (!(diff * BPS_DENOM <= live * priceDeviationBps)) revert ReferenceOffMarket();
        }
        referencePrice = newReference;
        emit ReferencePriceSet(newReference);
    }

    /// @notice Atomically disarm keeper sells: zero BOTH BNB egress caps AND the deviation-band reference in one call.
    /// @dev Flap pre-audit #2: removes any operational window in which `referencePrice == 0` while the egress caps
    ///      remain armed. Sells already FAIL-CLOSED in that window (`_checkDeviationBand` reverts when the band is
    ///      disarmed but either cap is still non-zero), so this is a clarity/ergonomics hardening, not a new safety
    ///      property: it gives the guardian (and the auditor) a single, atomic "stop sells" switch instead of a
    ///      two-call sequence. Re-arming is deliberate: setReferencePrice(...) then setKeeperLimits(...).
    function disarmSells() external onlyGuardian {
        maxBnbOutPerFill = 0;
        maxBnbOutPerWindow = 0;
        referencePrice = 0;
        emit KeeperLimitsSet(0, 0);
        emit ReferencePriceSet(0);
    }

    /// @notice Guardian sets the keeper premium directly, clamped to [MIN_PREMIUM_BPS, MAX_PREMIUM_BPS].
    function setKeeperPremium(uint256 bps) external onlyGuardian {
        if (!(bps >= MIN_PREMIUM_BPS && bps <= MAX_PREMIUM_BPS)) revert PremiumOutOfRange();
        keeperPremiumBps = bps;
        emit KeeperPremiumSet(bps);
    }

    // ── Phase-2 (v3): RAM sink pricing config — same safe-by-default shape as the keeper guards ──

    /// @notice Wire/replace the RAM price oracle. RAM sinks stay disabled until BOTH the oracle and the cage
    ///         are armed. Setting address(0) disarms the RAM path (rig #1 in BNB and claims are unaffected).
    function setRamPriceOracle(address oracle) external onlyGuardian {
        ramPriceOracle = oracle;
        emit RamPriceOracleSet(oracle);
    }

    /// @notice Arm/move the RAM price cage (BNB wei per 1e18 RAM). `cageMin` is BOTH the lower clamp on the
    ///         market read and the degraded-mode price (cheapest RAM assumed → most units charged → safe for a
    ///         burn sink). `cageMin = 0` disarms the RAM path entirely.
    function setRamPriceCage(uint256 cageMin, uint256 cageMax) external onlyGuardian {
        if (!(cageMin <= cageMax)) revert BadConfig();
        ramPriceCageMin = cageMin;
        ramPriceCageMax = cageMax;
        emit RamPriceCageSet(cageMin, cageMax);
    }

    /// @notice Tune the repair cost (bps of the rig's plan price), hard-bounded to [25%, 75%].
    function setRepairCost(uint256 bps) external onlyGuardian {
        if (!(bps >= MIN_REPAIR_COST_BPS && bps <= MAX_REPAIR_COST_BPS)) revert BadConfig();
        repairCostBps = bps;
        emit RepairCostSet(bps);
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
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        flapAIProvider = _provider;
        flapTriggerService = _trigger;
        aiModelId = _modelId;
        aiReasonFee = _reasonFee;
        epochInterval = _epochInterval;
        emit AgentConfigured(_provider, _trigger, _modelId);
    }

    function setAutoTrigger(bool on) external {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        autoTriggerEnabled = on;
    }

    /// @notice Guardian kicks off the autonomous epoch loop (arms the first trigger).
    function startEpochLoop() external {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        autoTriggerEnabled = true;
        _armNextEpoch();
    }

    /// @notice Manually request an economic decision (guardian/ops).
    function requestReasoning() external returns (uint256 requestId) {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        requestId = _requestReasoning();
    }

    /// @notice Trigger-service callback: at each epoch, re-arm and ask the oracle for a decision.
    function trigger(uint256 requestId) external override nonReentrant {
        if (!(msg.sender == flapTriggerService)) revert OnlyTriggerService();
        if (!autoTriggerEnabled) return;
        // B2 fix: bind the callback to the pending trigger id and consume it (anti replay/stale; retryUndelivered is public)
        if (!(requestId == lastTriggerRequestId && lastTriggerRequestId != 0)) revert StaleRequest();
        lastTriggerRequestId = 0;
        _armNextEpoch();
        _requestReasoning();
    }

    /// @notice AI oracle callback delivering the chosen lever (0..LEVER_COUNT-1).
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal override {
        // B2 fix: validate + consume the pending reasoning id BEFORE acting, so a stale/replayed fulfillment
        // (retryUndelivered is callable by anyone) can't re-apply an obsolete economic decision to fresh funds.
        if (!(requestId == lastReasoningRequestId && lastReasoningRequestId != 0)) revert StaleRequest();
        lastReasoningRequestId = 0;
        if (!(choice < LEVER_COUNT)) revert InvalidLever();
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

    /// @dev AUDITED tier table — UNCHANGED from the v2 contract Flap reviewed. Per our F2 "By Design"
    ///      response to the Flap Risk Report, the four Genesis tiers (powers, prices AND durations) are
    ///      deliberately NOT rebalanced: the yield-per-BNB spread is publicly disclosed via getPlan, bounded
    ///      by the seasonEnd cap (end = min(start + duration, seasonEnd)), and Phase 2 rebalances scaling
    ///      incentives ECONOMICALLY (subsequent rigs/upgrades/repairs are paid in RAM) — not by re-numbering
    ///      the audited table. The v3 wear ladder operates WITHIN each rig's own audited duration.
    function _plan(uint256 planId)
        internal
        view
        returns (uint256 priceWei, uint256 power, uint256 durationSeconds, string memory name)
    {
        if (!(planId < PLAN_COUNT)) revert InvalidPlan();
        if (planId == 0) {
            (priceWei, power, durationSeconds, name) = (basePriceWei, 10, 1 days, "Micro Rig");
        } else if (planId == 1) {
            (priceWei, power, durationSeconds, name) = (basePriceWei * 3, 40, 7 days, "Core Rig");
        } else if (planId == 2) {
            (priceWei, power, durationSeconds, name) = (basePriceWei * 8, 130, 30 days, "Mega Rig");
        } else {
            (priceWei, power, durationSeconds, name) = (basePriceWei * 20, 420, 90 days, "Hyper Rig");
        }
        if (!(priceWei > 0 && power > 0 && durationSeconds > 0)) revert BadPlanParams();
    }
}

/// @title RamMiningBeaconFactory
/// @notice Flap V2 factory for launching RamMiningVault BeaconProxy instances. Upgrades are timelocked.
contract RamMiningBeaconFactory is VaultFactoryBaseV2 {
    address public immutable beacon;

    /// @notice Only this developer wallet may launch vaults through this factory (Flap Post-Audit Step 0).
    ///         VaultPortal passes the token creator as `creator`; any other creator is rejected at creation.
    address public constant DEV_ADDRESS = 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1;

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

    /// @dev vaultData = abi.encode(rewardToken, rewardPriceFeed, bnbPriceFeed, basePriceWei, seasonEnd,
    ///      ramPriceOracle, ramCageMin, ramCageMax, ramTreasuryWallet). Fields 6-8 arm the Phase-2 RAM sink
    ///      pricing at creation (zeros = disarmed; the Guardian can arm/adjust later); field 9 is the dedicated
    ///      treasury wallet receiving the 15% share of RAM sinks (required non-zero, immutable per vault).
    function newVault(address taxToken, address, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        if (!(msg.sender == _getVaultPortal())) revert OnlyVaultPortal();
        if (!(creator == DEV_ADDRESS)) revert NotAuthorized();
        (
            address rewardToken,
            address rewardPriceFeed,
            address bnbPriceFeed,
            uint256 basePriceWei,
            uint256 seasonEnd,
            address ramPriceOracle,
            uint256 ramCageMin,
            uint256 ramCageMax,
            address ramTreasuryWallet
        ) = abi.decode(vaultData, (address, address, address, uint256, uint256, address, uint256, uint256, address));

        vault = address(
            new BeaconProxy(
                beacon,
                abi.encodeCall(
                    RamMiningVaultUpgradeable.initialize,
                    (
                        taxToken,
                        rewardToken,
                        rewardPriceFeed,
                        bnbPriceFeed,
                        basePriceWei,
                        seasonEnd,
                        ramPriceOracle,
                        ramCageMin,
                        ramCageMax,
                        ramTreasuryWallet
                    )
                )
            )
        );
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    // --- Timelocked beacon upgrade (staged rollout, no instant bait-and-switch) ---

    function scheduleUpgrade(address newImplementation) external {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        if (!(newImplementation.code.length > 0)) revert NotAContract();
        pendingImplementation = newImplementation;
        pendingImplementationReadyAt = block.timestamp + UPGRADE_DELAY;
        emit UpgradeScheduled(newImplementation, pendingImplementationReadyAt);
    }

    function executeUpgrade() external {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        if (!(pendingImplementation != address(0))) revert NoPendingUpgrade();
        if (!(block.timestamp >= pendingImplementationReadyAt)) revert TimelockNotElapsed();
        address impl = pendingImplementation;
        pendingImplementation = address(0);
        pendingImplementationReadyAt = 0;
        UpgradeableBeacon(beacon).upgradeTo(impl);
        emit UpgradeExecuted(impl);
    }

    function cancelUpgrade() external {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
        address impl = pendingImplementation;
        pendingImplementation = address(0);
        pendingImplementationReadyAt = 0;
        emit UpgradeCancelled(impl);
    }

    function lockVaultUpgrades() external {
        if (!(msg.sender == _getGuardian())) revert OnlyGuardian();
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
        schema.fields = new FieldDescriptor[](9);
        schema.fields[0] = FieldDescriptor("rewardToken", "address", "Tokenized NVIDIA reward token (NVDAB)", 0);
        schema.fields[1] = FieldDescriptor("rewardPriceFeed", "address", "Chainlink NVDA/USD price feed (8 dec)", 0);
        schema.fields[2] = FieldDescriptor("bnbPriceFeed", "address", "Chainlink BNB/USD price feed (8 dec)", 0);
        schema.fields[3] = FieldDescriptor("basePriceWei", "uint256", "Base price for Micro Rig in BNB", 18);
        schema.fields[4] = FieldDescriptor("seasonEnd", "time", "Mining season end timestamp", 0);
        schema.fields[5] = FieldDescriptor("ramPriceOracle", "address", "RAM price oracle (0 = RAM sinks disarmed)", 0);
        schema.fields[6] = FieldDescriptor("ramCageMin", "uint256", "RAM price cage floor, BNB wei per 1e18 RAM", 18);
        schema.fields[7] = FieldDescriptor("ramCageMax", "uint256", "RAM price cage ceiling, BNB wei per 1e18 RAM", 18);
        schema.fields[8] = FieldDescriptor("ramTreasuryWallet", "address", "Treasury wallet for the 15% RAM sink share", 0);
        schema.isArray = false;
    }
}
