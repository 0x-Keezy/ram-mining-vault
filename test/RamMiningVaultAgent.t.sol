// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
import {InvalidLever, OnlyGuardian, OnlyTriggerService, StaleRequest} from "../src/RamMiningVault.sol";
import {ITriggerReceiver} from "../src/flap/IFlapTriggerService.sol";

contract AgentRewardToken is ERC20 {
    constructor() ERC20("Test NVIDIA", "tNVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal Chainlink feed mock (8 dec) — the agent tests never sell, feeds just need to be valid.
contract AgentPriceFeed {
    uint8 public decimals = 8;
    int256 internal _answer;

    constructor(int256 answer_) {
        _answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
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
    AgentPriceFeed nvdaFeed;
    AgentPriceFeed bnbFeed;
    MockAIProvider ai;
    MockTriggerService triggerSvc;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days);
        reward = new AgentRewardToken();
        nvdaFeed = new AgentPriceFeed(130e8);
        bnbFeed = new AgentPriceFeed(600e8);
        ai = new MockAIProvider();
        triggerSvc = new MockTriggerService();
        factory = new RamMiningBeaconFactory();

        uint256 seasonEnd = block.timestamp + 60 days;
        bytes memory vaultData =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        vault = RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vaultData)));

        vm.prank(GUARDIAN);
        vault.configureAgent(address(ai), address(triggerSvc), 1, 0, uint64(1 days));

        // an active miner + BNB reserve
        vm.deal(alice, 10 ether);
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vault.buyMiningContract{value: price}(0);
        vm.deal(address(vault), 10 ether);
    }

    function _fulfill(uint8 choice) internal {
        vm.prank(GUARDIAN);
        uint256 id = vault.requestReasoning();
        ai.fulfill(address(vault), id, choice);
    }

    // ── config / access ────────────────────────────────────────────────

    function testConfigureAgentOnlyGuardian() public {
        vm.expectRevert(OnlyGuardian.selector);
        vault.configureAgent(address(ai), address(triggerSvc), 1, 0, uint64(1 days));
    }

    function testOnlyProviderCanFulfill() public {
        vm.expectRevert(); // FlapAIConsumerOnlyProvider
        vault.fulfillReasoning(1, 0);
    }

    function testInvalidLeverReverts() public {
        vm.prank(GUARDIAN);
        uint256 id = vault.requestReasoning();
        vm.expectRevert(InvalidLever.selector);
        ai.fulfill(address(vault), id, 4); // LEVER_COUNT == 4 -> 4 (old PAUSE lever) is now out of range
    }

    // ── levers ───────────────────────────────────────────────────────────

    function testLeverHoldNoop() public {
        uint256 premiumBefore = vault.keeperPremiumBps();
        _fulfill(0);
        assertEq(vault.lastLever(), 0);
        assertEq(vault.keeperPremiumBps(), premiumBefore);
    }

    function testLeverRetainNoop() public {
        uint256 premiumBefore = vault.keeperPremiumBps();
        _fulfill(3);
        assertEq(vault.lastLever(), 3);
        assertEq(vault.keeperPremiumBps(), premiumBefore);
    }

    function testLeverRaisePremium() public {
        uint256 before = vault.keeperPremiumBps();
        _fulfill(1);
        assertEq(vault.keeperPremiumBps(), before + vault.PREMIUM_STEP_BPS());
    }

    function testLeverLowerPremium() public {
        // raise once so there's room to lower
        _fulfill(1);
        uint256 raised = vault.keeperPremiumBps();
        _fulfill(2);
        assertEq(vault.keeperPremiumBps(), raised - vault.PREMIUM_STEP_BPS());
    }

    function testLeverRaiseAndLowerPremiumClamped() public {
        // raise to MAX (1.04)
        for (uint256 i = 0; i < 20; i++) {
            _fulfill(1);
        }
        assertEq(vault.keeperPremiumBps(), vault.MAX_PREMIUM_BPS());
        // lower to MIN (1.02 — never below Flap's recommended floor)
        for (uint256 i = 0; i < 40; i++) {
            _fulfill(2);
        }
        assertEq(vault.keeperPremiumBps(), vault.MIN_PREMIUM_BPS());
    }

    // No-pause model: lever 4 (the old PAUSE_ACQUISITION) no longer exists; LEVER_COUNT == 4 so any choice ≥ 4
    // reverts as an invalid lever (covered by testInvalidLeverReverts). All remaining levers only move the
    // clamped premium and execute immediately — there is no queued/timelocked action machinery anymore.
    function testNoQueuedActionMachinery() public {
        // the queued-action selectors were removed with the pause lever
        (bool a,) = address(vault).call(abi.encodeWithSignature("executeQueuedAction()"));
        (bool b,) = address(vault).call(abi.encodeWithSignature("cancelQueuedAction()"));
        assertTrue(!a && !b, "no queued-action selector may exist");
    }

    // ── trigger / epoch loop ─────────────────────────────────────────────

    function testTriggerOnlyService() public {
        vm.expectRevert(OnlyTriggerService.selector);
        vault.trigger(1);
    }

    function testTriggerLoopRequestsReasoningAndRearms() public {
        vm.prank(GUARDIAN);
        vault.startEpochLoop();
        assertTrue(vault.autoTriggerEnabled());
        uint256 armedId = vault.lastTriggerRequestId();
        assertGt(armedId, 0);

        triggerSvc.fire(address(vault), armedId);
        assertGt(vault.lastReasoningRequestId(), 0);
        assertGt(vault.lastTriggerRequestId(), armedId);
    }

    function testAutoTriggerDisabledIsNoop() public {
        assertFalse(vault.autoTriggerEnabled());
        triggerSvc.fire(address(vault), 1);
        assertEq(vault.lastReasoningRequestId(), 0);
    }

    // ── B2 anti-replay: requestId is validated AND consumed (retryUndelivered/retryTrigger are public) ──

    function testFulfillRejectsReplayedRequestId() public {
        vm.prank(GUARDIAN);
        uint256 id = vault.requestReasoning();
        ai.fulfill(address(vault), id, 1); // first fulfillment consumes lastReasoningRequestId
        assertEq(vault.lastReasoningRequestId(), 0);

        // replaying the SAME (already consumed) id must revert — a stale decision can't re-apply to fresh funds
        vm.expectRevert(StaleRequest.selector);
        ai.fulfill(address(vault), id, 1);
    }

    function testFulfillRejectsUnknownRequestId() public {
        vm.prank(GUARDIAN);
        vault.requestReasoning(); // arms lastReasoningRequestId
        // a different id than the pending one must revert
        vm.expectRevert(StaleRequest.selector);
        ai.fulfill(address(vault), 999_999, 1);
    }

    function testTriggerRejectsReplayedRequestId() public {
        vm.prank(GUARDIAN);
        vault.startEpochLoop();
        uint256 armedId = vault.lastTriggerRequestId();

        triggerSvc.fire(address(vault), armedId); // consumes armedId, re-arms a fresh one
        // firing the old (consumed) trigger id again must revert
        vm.expectRevert(StaleRequest.selector);
        triggerSvc.fire(address(vault), armedId);
    }

    receive() external payable {}
}
