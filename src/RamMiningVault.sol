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
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";
import {FlapAIConsumerBase, IFlapAIProvider} from "./flap/IFlapAIProvider.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";

/// @notice Minimal PancakeSwap/Uniswap-V2 router surface used to swap native BNB into the reward token.
interface IRamSwapRouter {
    function WETH() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

/// @title RamMiningVaultUpgradeable
/// @notice Flap V2 real-yield mining vault for the RAM project.
/// @dev Users buy native-BNB "rig" contracts that grant mining `power`. The vault's reward comes from REAL
///      trading fees: the RAM tax token routes its `market` fee share (in BNB) to this vault; the vault swaps
///      that BNB into a reward token (tokenized NVIDIA, e.g. NVDAx) and distributes it pro-rata to active power
///      using a MasterChef-style accumulator (`accRewardPerPower`). Rigs expire per-rig; expiry is settled lazily
///      by time buckets (no paid keeper). NO buyback & burn — capital is reinvested into the reward asset.
contract RamMiningVaultUpgradeable is
    Initializable,
    VaultBaseV2,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    FlapAIConsumerBase,
    ITriggerReceiver
{
    using SafeERC20 for IERC20;

    uint256 public constant MAX_CONTRACTS_PER_USER = 16;
    uint256 public constant PLAN_COUNT = 4;
    uint256 public constant ACC_PRECISION = 1e12;
    uint256 public constant BUCKET = 1 days; // expiry granularity
    uint256 public constant EMERGENCY_COOLDOWN = 1 days;

    // economic-agent clamps
    uint8 public constant LEVER_COUNT = 6;
    uint256 public constant MIN_DCA_BPS = 500; // 5%
    uint256 public constant MAX_DCA_BPS = 5000; // 50%
    uint256 public constant DCA_MAX_SLIPPAGE_BPS = 300; // 3% — max slippage tolerated by the autonomous DCA swap (anti-MEV)
    uint256 public constant DCA_STEP_BPS = 500; // 5%
    uint256 public constant DCA_COOLDOWN = 6 hours;
    uint256 public constant ACTION_TIMELOCK = 12 hours;

    // --- config (set at initialize) ---
    address public taxToken; // RAM token (fee source; not held by this vault directly)
    address public rewardToken; // tokenized NVIDIA distributed to miners (e.g. NVDAx)
    address public swapRouter; // PancakeSwap router for BNB -> rewardToken
    uint256 public basePriceWei; // Micro rig price in BNB
    uint256 public seasonEnd; // rigs cannot mine past this timestamp

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
    uint256 public totalNativePaid;
    uint256 public totalNativeDeployed; // BNB spent buying reward token
    uint256 public lastContractId;
    uint256 public lastEmergencyWithdraw;

    // --- economic agent (AI oracle) ---
    address public flapAIProvider; // overrides chain-default AI provider when set (config/testing)
    address public flapTriggerService; // Flap trigger service (configurable; testnet addr not in interface)
    uint256 public aiModelId;
    uint256 public aiReasonFee; // BNB budget per reason() call
    uint64 public epochInterval; // seconds between economic epochs
    bool public autoTriggerEnabled;
    uint256 public dcaPercentBps; // % of BNB reserve deployed per DCA (clamped MIN_DCA_BPS..MAX_DCA_BPS)
    uint256 public dcaCooldownUntil;
    uint256 public lastReasoningRequestId;
    uint256 public lastTriggerRequestId;
    uint256 public lastEpochAt;
    uint8 public lastLever;
    // tiered autonomy: queued high-impact action (lever 5 = pause sales)
    uint8 public queuedLever;
    uint256 public queuedReadyAt;
    bool public hasQueuedAction;

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
    ///      shrink this gap so the beacon-proxy storage layout never collides.
    uint256[50] private __gap;

    event RigBought(
        address indexed user,
        uint256 indexed rigId,
        uint256 indexed planId,
        uint256 power,
        uint256 priceWei,
        uint256 startTime,
        uint256 endTime
    );
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 newAccRewardPerPower);
    event NativeDeployedToReward(uint256 amountInBNB, uint256 rewardOut);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    event AgentConfigured(address provider, address triggerService, uint256 modelId);
    event ReasoningRequested(uint256 requestId);
    event LeverApplied(uint256 indexed requestId, uint8 indexed lever);
    event QueuedActionScheduled(uint8 indexed lever, uint256 readyAt);
    event QueuedActionExecuted(uint8 indexed lever);
    event QueuedActionCancelled(uint8 indexed lever);
    event ReasoningRefunded(uint256 indexed requestId);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _taxToken,
        address _rewardToken,
        address _swapRouter,
        uint256 _basePriceWei,
        uint256 _seasonEnd
    ) external initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        require(_taxToken != address(0), unicode"RAM token required / 需要 RAM 代币地址");
        require(_rewardToken != address(0), unicode"Reward token required / 需要奖励代币地址");
        require(_swapRouter != address(0), unicode"Router required / 需要路由器地址");
        require(_basePriceWei > 0, unicode"Base price required / 需要基础价格");
        require(_seasonEnd >= block.timestamp + 1 days, unicode"Season too short / 赛季过短");

        taxToken = _taxToken;
        rewardToken = _rewardToken;
        swapRouter = _swapRouter;
        basePriceWei = _basePriceWei;
        seasonEnd = _seasonEnd;
        lastSettledBucket = block.timestamp / BUCKET;
    }

    /// @notice Accept native BNB. The RAM tax token's TaxProcessor sends the `market` fee share here, and the
    ///         vault can also be seeded with BNB. No external calls, no loops.
    receive() external payable {}

    // ──────────────────────────────────────────────────────────────────────────
    //  Buy / Claim
    // ──────────────────────────────────────────────────────────────────────────

    function buyMiningContract(uint256 planId) external payable nonReentrant whenNotPaused {
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

    // @dev Claims are intentionally NOT gated by whenNotPaused — users can always withdraw their rewards,
    //      even if rig sales are paused (the agent's freno). Never trap user funds.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _settleExpiries();
        Rig[] storage rigs = userRigs[msg.sender];
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
        IERC20(rewardToken).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Reward funding (real-yield): swap BNB fees into reward token, then notify
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Deploy `amountBNB` of the BNB reserve into the reward token and credit it to miners.
    /// @dev Guardian-gated in Phase 1. In Phase 3 the AI economic agent (within clamps) also calls this.
    function deployToReward(uint256 amountBNB, uint256 minRewardOut)
        external
        nonReentrant
        returns (uint256 rewardOut)
    {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        rewardOut = _deployToReward(amountBNB, minRewardOut);
    }

    function _deployToReward(uint256 amountBNB, uint256 minRewardOut) internal returns (uint256 rewardOut) {
        require(amountBNB > 0 && amountBNB <= address(this).balance, unicode"Bad amount / 金额错误");

        IRamSwapRouter router = IRamSwapRouter(swapRouter);
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = rewardToken;

        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        router.swapExactETHForTokens{value: amountBNB}(minRewardOut, path, address(this), block.timestamp);
        rewardOut = IERC20(rewardToken).balanceOf(address(this)) - balBefore;

        totalNativeDeployed += amountBNB;
        _notifyReward(rewardOut);
        emit NativeDeployedToReward(amountBNB, rewardOut);
    }

    /// @dev On-chain min-out for the autonomous DCA swap: router quote minus a clamped slippage bound (anti-MEV, B1).
    function _dcaMinOut(uint256 amountBNB) internal view returns (uint256) {
        IRamSwapRouter router = IRamSwapRouter(swapRouter);
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = rewardToken;
        uint256[] memory outs = router.getAmountsOut(amountBNB, path);
        return (outs[1] * (10000 - DCA_MAX_SLIPPAGE_BPS)) / 10000;
    }

    /// @notice Credit reward tokens already held/received by the vault into the distribution accumulator.
    /// @dev Pull pattern for externally-sourced reward token (e.g. a manual top-up). Caller must have approved.
    function donateReward(uint256 amount) external nonReentrant {
        require(amount > 0, unicode"Bad amount / 金额错误");
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        _notifyReward(amount);
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
            "Mine tokenized NVIDIA with RAM. Buy a rig with BNB to gain mining power; the vault buys tokenized NVIDIA with real trading fees and distributes it pro-rata to your power. No buyback & burn.";
        schema.methods = new VaultMethodSchema[](6);

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
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Admin (guardian) — Pausable + emergency, all cooldown/bounded
    // ──────────────────────────────────────────────────────────────────────────

    function pauseVault() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        _pause();
    }

    function unpauseVault() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        _unpause();
    }

    function emergencyWithdrawNative(address to) external nonReentrant {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(to != address(0), unicode"Bad recipient / 错误接收地址");
        require(block.timestamp >= lastEmergencyWithdraw + EMERGENCY_COOLDOWN, unicode"Cooldown / 冷却期");
        lastEmergencyWithdraw = block.timestamp;
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        require(ok, unicode"Native withdraw failed / 原生币提取失败");
        emit EmergencyWithdrawNative(to, bal);
    }

    function emergencyWithdrawToken(address token, address to) external nonReentrant {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(to != address(0), unicode"Bad recipient / 错误接收地址");
        require(block.timestamp >= lastEmergencyWithdraw + EMERGENCY_COOLDOWN, unicode"Cooldown / 冷却期");
        lastEmergencyWithdraw = block.timestamp;
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit EmergencyWithdrawToken(token, to, bal);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Economic agent (AI oracle) — tiered autonomy, NO burn
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Guardian configures the AI oracle + trigger service + epoch params. Set provider/trigger to
    ///         address(0) to use the chain default provider / disable the trigger loop.
    function configureAgent(
        address _provider,
        address _trigger,
        uint256 _modelId,
        uint256 _reasonFee,
        uint64 _epochInterval,
        uint256 _dcaBps
    ) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(_dcaBps >= MIN_DCA_BPS && _dcaBps <= MAX_DCA_BPS, unicode"Bad DCA bps / DCA 比例错误");
        flapAIProvider = _provider;
        flapTriggerService = _trigger;
        aiModelId = _modelId;
        aiReasonFee = _reasonFee;
        epochInterval = _epochInterval;
        dcaPercentBps = _dcaBps;
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

    /// @notice Execute a queued high-impact action after its timelock (guardian-gated).
    function executeQueuedAction() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(hasQueuedAction, unicode"No queued action / 无排队操作");
        require(block.timestamp >= queuedReadyAt, unicode"Timelock not elapsed / 时间锁未到");
        uint8 lever = queuedLever;
        hasQueuedAction = false;
        if (lever == 5) {
            _pause(); // freno: pause rig sales
        }
        emit QueuedActionExecuted(lever);
    }

    function cancelQueuedAction() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(hasQueuedAction, unicode"No queued action / 无排队操作");
        uint8 lever = queuedLever;
        hasQueuedAction = false;
        queuedReadyAt = 0;
        emit QueuedActionCancelled(lever);
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

    /// @dev Applies the chosen lever. Low-risk/reversible levers execute immediately (tiered autonomy);
    ///      the high-impact lever (5 = pause sales) is queued behind a timelock for guardian execution.
    ///      NO burn lever exists.
    function _applyLever(uint8 choice) internal {
        if (choice == 0 || choice == 2) {
            return; // 0 HOLD · 2 RETAIN reserve (no-op)
        } else if (choice == 1) {
            // DCA: buy NVDA with a clamped slice of the BNB reserve (auto, cooldown-gated)
            if (block.timestamp < dcaCooldownUntil) return;
            uint256 amt = (address(this).balance * dcaPercentBps) / 10000;
            if (amt == 0) return;
            dcaCooldownUntil = block.timestamp + DCA_COOLDOWN;
            // B1 fix (anti-MEV): derive an on-chain min-out from the router quote with a clamped slippage bound,
            // instead of accepting amountOutMin=0. If liquidity can't satisfy the bound the swap reverts (safe).
            _deployToReward(amt, _dcaMinOut(amt));
        } else if (choice == 3) {
            uint256 next = dcaPercentBps + DCA_STEP_BPS;
            dcaPercentBps = next > MAX_DCA_BPS ? MAX_DCA_BPS : next;
        } else if (choice == 4) {
            dcaPercentBps = dcaPercentBps < MIN_DCA_BPS + DCA_STEP_BPS ? MIN_DCA_BPS : dcaPercentBps - DCA_STEP_BPS;
        } else if (choice == 5) {
            // HIGH IMPACT: queue pause-sales behind a timelock (guardian executes)
            queuedLever = 5;
            queuedReadyAt = block.timestamp + ACTION_TIMELOCK;
            hasQueuedAction = true;
            emit QueuedActionScheduled(5, queuedReadyAt);
        }
    }

    function _buildPrompt() internal pure returns (string memory) {
        return
        "You are the RAM vault economic agent for a real-yield mining vault that buys tokenized NVIDIA with real trading fees and shares it by mining power. Choose ONE lever (reply with the integer 0-5). NO token burns. 0=HOLD; 1=DCA buy NVDA with a clamped slice of the BNB reserve; 2=retain/grow BNB reserve; 3=raise DCA aggressiveness; 4=lower DCA aggressiveness; 5=pause rig sales (emergency brake). Use the ave_token_info tool for market data before deciding.";
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

    /// @dev vaultData = abi.encode(rewardToken, swapRouter, basePriceWei, seasonEnd).
    function newVault(address taxToken, address, address, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Only VaultPortal / 仅限 VaultPortal 调用");
        (address rewardToken, address swapRouter, uint256 basePriceWei, uint256 seasonEnd) =
            abi.decode(vaultData, (address, address, uint256, uint256));

        vault = address(
            new BeaconProxy(
                beacon,
                abi.encodeCall(
                    RamMiningVaultUpgradeable.initialize,
                    (taxToken, rewardToken, swapRouter, basePriceWei, seasonEnd)
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
            "Launch a RAM Mining Vault. Users buy BNB rig contracts to earn tokenized NVIDIA bought with the RAM token's real trading fees, shared by mining power. Provide the reward token (e.g. NVDAx), the swap router, the Micro rig base price, and the season end.";
        schema.fields = new FieldDescriptor[](4);
        schema.fields[0] = FieldDescriptor("rewardToken", "address", "Tokenized NVIDIA reward token (e.g. NVDAx)", 0);
        schema.fields[1] = FieldDescriptor("swapRouter", "address", "PancakeSwap router for BNB->reward swaps", 0);
        schema.fields[2] = FieldDescriptor("basePriceWei", "uint256", "Base price for Micro Rig in BNB", 18);
        schema.fields[3] = FieldDescriptor("seasonEnd", "time", "Mining season end timestamp", 0);
        schema.isArray = false;
    }
}
