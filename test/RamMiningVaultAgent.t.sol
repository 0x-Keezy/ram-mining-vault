// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable, IRamSwapRouter} from "../src/RamMiningVault.sol";
import {ITriggerReceiver} from "../src/flap/IFlapTriggerService.sol";

contract AgentRewardToken is ERC20 {
    constructor() ERC20("Test NVIDIA", "tNVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AgentSwapRouter is IRamSwapRouter {
    AgentRewardToken public reward;
    address public wbnb = address(0x1111);

    constructor(AgentRewardToken _reward) {
        reward = _reward;
    }

    function WETH() external view override returns (address) {
        return wbnb;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata) external pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // mock 1:1 quote, matches swapExactETHForTokens
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata, address to, uint256)
        external
        payable
        override
        returns (uint256[] memory amounts)
    {
        uint256 out = msg.value;
        require(out >= amountOutMin, "slippage");
        reward.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }
}

/// @dev Stand-in for the Flap AI oracle. `fulfill` delivers a chosen lever AS the provider address.
contract MockAIProvider {
    uint256 public nextId = 1;

    function reason(uint256, string calldata, uint8) external payable returns (uint256) {
        return nextId++;
    }

    function fulfill(address consumer, uint256 requestId, uint8 choice) external {
        RamMiningVaultUpgradeable(payable(consumer)).fulfillReasoning(requestId, choice);
    }
}

/// @dev Stand-in for the Flap trigger service. `fire` invokes the receiver's epoch callback.
contract MockTriggerService {
    uint256 public nextId = 1;

    function getFee() external pure returns (uint256) {
        return 0;
    }

    function requestTrigger(uint64) external payable returns (uint256) {
        return nextId++;
    }

    function fire(address receiver, uint256 requestId) external {
        ITriggerReceiver(receiver).trigger(requestId);
    }
}

contract RamMiningVaultAgentTest is Test {
    address constant BNB_TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant RAM_TOKEN = address(0x4A11);

    address alice = address(0xA11CE);

    AgentRewardToken reward;
    AgentSwapRouter router;
    MockAIProvider ai;
    MockTriggerService triggerSvc;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days);
        reward = new AgentRewardToken();
        router = new AgentSwapRouter(reward);
        ai = new MockAIProvider();
        triggerSvc = new MockTriggerService();
        factory = new RamMiningBeaconFactory();

        uint256 seasonEnd = block.timestamp + 60 days;
        bytes memory vaultData = abi.encode(address(reward), address(router), basePrice, seasonEnd);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        vault = RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), address(this), vaultData)));

        vm.prank(GUARDIAN);
        vault.configureAgent(address(ai), address(triggerSvc), 1, 0, uint64(1 days), 2000);

        // an active miner + BNB reserve for the agent to deploy
        vm.deal(alice, 10 ether);
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vault.buyMiningContract{value: price}(0);
        vm.deal(address(vault), 10 ether);
    }

    function _fulfill(uint8 choice) internal {
        // real flow: request first (sets lastReasoningRequestId via the mock AI), then fulfill with THAT id
        vm.prank(GUARDIAN);
        uint256 id = vault.requestReasoning();
        ai.fulfill(address(vault), id, choice);
    }

    // ── config / access ────────────────────────────────────────────────

    function testConfigureAgentOnlyGuardian() public {
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vault.configureAgent(address(ai), address(triggerSvc), 1, 0, uint64(1 days), 2000);
    }

    function testConfigureAgentRejectsBadDcaBps() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Bad DCA bps / DCA 比例错误"));
        vault.configureAgent(address(ai), address(triggerSvc), 1, 0, uint64(1 days), 9000); // > MAX
    }

    function testOnlyProviderCanFulfill() public {
        vm.expectRevert(); // FlapAIConsumerOnlyProvider
        vault.fulfillReasoning(1, 0);
    }

    function testInvalidLeverReverts() public {
        vm.prank(GUARDIAN);
        uint256 id = vault.requestReasoning();
        vm.expectRevert(bytes(unicode"Invalid lever / 无效杠杆"));
        ai.fulfill(address(vault), id, 6);
    }

    // ── levers ───────────────────────────────────────────────────────────

    function testLeverHoldNoop() public {
        uint256 pendingBefore = vault.pendingRewards(alice);
        _fulfill(0);
        assertEq(vault.lastLever(), 0);
        assertEq(vault.pendingRewards(alice), pendingBefore);
    }

    function testLeverDcaBuysAndDistributes() public {
        assertEq(vault.pendingRewards(alice), 0);
        _fulfill(1); // DCA: 20% of 10 BNB = 2 BNB -> 2 tNVDA (1:1 mock) -> all to alice (only miner)
        assertApproxEqAbs(vault.pendingRewards(alice), 2 ether, 1e6);
        assertEq(vault.totalNativeDeployed(), 2 ether);
        assertGt(vault.dcaCooldownUntil(), block.timestamp);
    }

    function testLeverDcaRespectsCooldown() public {
        _fulfill(1);
        uint256 deployed = vault.totalNativeDeployed();
        _fulfill(1); // within cooldown -> no-op
        assertEq(vault.totalNativeDeployed(), deployed);
    }

    function testLeverRaiseAndLowerDcaClamped() public {
        // raise to MAX
        for (uint256 i = 0; i < 10; i++) {
            _fulfill(3);
        }
        assertEq(vault.dcaPercentBps(), vault.MAX_DCA_BPS());
        // lower to MIN
        for (uint256 i = 0; i < 20; i++) {
            _fulfill(4);
        }
        assertEq(vault.dcaPercentBps(), vault.MIN_DCA_BPS());
    }

    // ── tiered autonomy: high-impact lever 5 is queued behind a timelock ──

    function testLeverPauseIsQueuedNotImmediate() public {
        _fulfill(5);
        assertTrue(vault.hasQueuedAction());
        assertEq(vault.queuedLever(), 5);
        // rig sales NOT paused yet (only queued)
        (uint256 price,,,) = vault.getPlan(0);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.buyMiningContract{value: price}(0); // still works
    }

    function testQueuedActionTimelockThenExecute() public {
        _fulfill(5);
        // too early
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Timelock not elapsed / 时间锁未到"));
        vault.executeQueuedAction();

        vm.warp(block.timestamp + vault.ACTION_TIMELOCK());
        vm.prank(GUARDIAN);
        vault.executeQueuedAction();

        // now sales are paused
        (uint256 price,,,) = vault.getPlan(0);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.buyMiningContract{value: price}(0);
    }

    function testCancelQueuedAction() public {
        _fulfill(5);
        vm.prank(GUARDIAN);
        vault.cancelQueuedAction();
        assertFalse(vault.hasQueuedAction());
    }

    function testExecuteQueuedOnlyGuardian() public {
        _fulfill(5);
        vm.warp(block.timestamp + vault.ACTION_TIMELOCK());
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vault.executeQueuedAction();
    }

    // claims keep working even when sales are paused (never trap funds)
    function testClaimWorksWhilePaused() public {
        _fulfill(1); // give alice some reward
        _fulfill(5);
        vm.warp(block.timestamp + vault.ACTION_TIMELOCK());
        vm.prank(GUARDIAN);
        vault.executeQueuedAction(); // pauses sales

        uint256 pending = vault.pendingRewards(alice);
        assertGt(pending, 0);
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, pending, 1e6);
    }

    // ── trigger / epoch loop ─────────────────────────────────────────────

    function testTriggerOnlyService() public {
        vm.expectRevert(bytes(unicode"Only trigger service / 仅限触发服务"));
        vault.trigger(1);
    }

    function testTriggerLoopRequestsReasoningAndRearms() public {
        vm.prank(GUARDIAN);
        vault.startEpochLoop();
        assertTrue(vault.autoTriggerEnabled());
        uint256 armedId = vault.lastTriggerRequestId();
        assertGt(armedId, 0);

        // trigger service fires the epoch callback
        triggerSvc.fire(address(vault), armedId);
        assertGt(vault.lastReasoningRequestId(), 0); // reasoning requested
        assertGt(vault.lastTriggerRequestId(), armedId); // re-armed next epoch
    }

    function testAutoTriggerDisabledIsNoop() public {
        // autoTrigger is off by default (configureAgent does not enable it)
        assertFalse(vault.autoTriggerEnabled());
        triggerSvc.fire(address(vault), 1); // should just return
        assertEq(vault.lastReasoningRequestId(), 0);
    }

    receive() external payable {}
}
