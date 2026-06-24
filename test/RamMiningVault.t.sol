// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable, IRamSwapRouter} from "../src/RamMiningVault.sol";
import {VaultDataSchema, VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

/// @dev Mintable ERC20 standing in for tokenized NVIDIA (NVDAx) in deterministic tests.
contract MockRewardToken is ERC20 {
    constructor() ERC20("Test NVIDIA", "tNVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal PancakeSwap-like router: takes BNB, mints reward 1:1 to `to`. Enforces amountOutMin (slippage).
contract MockSwapRouter is IRamSwapRouter {
    MockRewardToken public reward;
    address public wbnb = address(0x1111);

    constructor(MockRewardToken _reward) {
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
        uint256 out = msg.value; // 1 BNB -> 1 tNVDA for test determinism
        require(out >= amountOutMin, "MockRouter: slippage");
        reward.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }
}

/// @dev Buyer contract whose receive() reverts — used to test the safe-refund path.
contract RevertingBuyer {
    function buy(RamMiningVaultUpgradeable v, uint256 plan) external payable {
        v.buyMiningContract{value: msg.value}(plan);
    }

    receive() external payable {
        revert("no refunds");
    }
}

contract RamMiningVaultTest is Test {
    address constant BNB_TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant RAM_TOKEN = address(0x4A11); // taxToken placeholder (not held by vault)

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    MockRewardToken reward;
    MockSwapRouter router;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;
    uint256 seasonEnd;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days); // start on a clean bucket boundary, away from bucket 0
        reward = new MockRewardToken();
        router = new MockSwapRouter(reward);
        factory = new RamMiningBeaconFactory();

        seasonEnd = block.timestamp + 60 days;
        bytes memory vaultData = abi.encode(address(reward), address(router), basePrice, seasonEnd);

        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        address vaultAddress = factory.newVault(RAM_TOKEN, address(0), address(this), vaultData);
        vault = RamMiningVaultUpgradeable(payable(vaultAddress));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        reward.mint(address(this), 10_000_000 ether); // for donateReward injections
        reward.approve(address(vault), type(uint256).max);
    }

    // helper: inject reward into the accumulator (simulates fee->NVDA arriving)
    function _inject(uint256 amount) internal {
        vault.donateReward(amount);
    }

    function _buy(address who, uint256 plan) internal {
        (uint256 price,,,) = vault.getPlan(plan);
        vm.prank(who);
        vault.buyMiningContract{value: price}(plan);
    }

    // ── schema / config ────────────────────────────────────────────────

    function testFactorySchema() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 4);
        assertEq(s.fields[0].name, "rewardToken");
        assertEq(s.fields[1].name, "swapRouter");
        assertEq(s.fields[2].name, "basePriceWei");
        assertEq(s.fields[3].name, "seasonEnd");
        assertFalse(s.isArray);
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(RAM_TOKEN));
    }

    function testVaultSchema() public view {
        VaultUISchema memory ui = vault.vaultUISchema();
        assertEq(ui.vaultType, "RamMiningVault");
        assertEq(ui.methods.length, 6);
        assertEq(ui.methods[4].name, "buyMiningContract");
        assertTrue(ui.methods[4].isWriteMethod);
        assertEq(ui.methods[4].inputs[1].fieldType, "msg.value");
        assertEq(ui.methods[5].name, "claimRewards");
        assertTrue(ui.methods[5].isWriteMethod);
    }

    function testInitConfig() public view {
        assertEq(vault.taxToken(), RAM_TOKEN);
        assertEq(vault.rewardToken(), address(reward));
        assertEq(vault.swapRouter(), address(router));
        assertEq(vault.basePriceWei(), basePrice);
        assertEq(vault.seasonEnd(), seasonEnd);
    }

    // ── core: buy + real-yield claim ───────────────────────────────────

    function testBuyAndClaimShareBased() public {
        _buy(alice, 0); // 10 power
        _inject(100 ether); // alice is the only power -> gets all
        assertApproxEqAbs(vault.pendingRewards(alice), 100 ether, 100);

        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, 100 ether, 100);
        assertApproxEqAbs(reward.balanceOf(alice), 100 ether, 100);
        assertEq(vault.pendingRewards(alice), 0);
    }

    function testProportionalSplit() public {
        _buy(alice, 0); // 10 power
        _buy(bob, 1); // 40 power -> total 50
        _inject(50 ether);

        // alice 10/50 = 10 ether, bob 40/50 = 40 ether
        assertApproxEqAbs(vault.pendingRewards(alice), 10 ether, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 40 ether, 1e6);
    }

    function testRewardWhileNoPowerGoesToFirstMiner() public {
        // No rigs yet -> reward held as undistributed
        _inject(30 ether);
        assertEq(vault.rewardUndistributed(), 30 ether);
        assertEq(vault.pendingRewards(alice), 0);

        _buy(alice, 0);
        // buying does not distribute; next injection flushes undistributed to alice
        _inject(0.000000000001 ether); // tiny extra; both go to alice (only miner)
        assertApproxEqAbs(vault.pendingRewards(alice), 30 ether, 1e9);
    }

    // ── per-rig expiry (lazy buckets) ──────────────────────────────────

    function testExpiryFreezesRigButActiveKeepsEarning() public {
        _buy(alice, 0); // Micro 10 power, 1 day
        _buy(bob, 1); // Core 40 power, 7 days -> total 50
        _inject(50 ether); // alice 10, bob 40

        // warp past alice's 1-day rig (but bob still active)
        vm.warp(block.timestamp + 2 days);
        _inject(40 ether); // only bob's 40 power active now -> all to bob

        // alice frozen at her pre-expiry share (~10 ether), gets none of the 2nd injection
        assertApproxEqAbs(vault.pendingRewards(alice), 10 ether, 1e6);
        // bob: 40 (first) + 40 (second) = 80
        assertApproxEqAbs(vault.pendingRewards(bob), 80 ether, 1e6);

        // totalActivePower dropped to 40 after settlement
        (,, uint256 power,,,,) = vault.getVaultMiningStats();
        assertEq(power, 40);
    }

    // ── reward funding via swap (deployToReward) ───────────────────────

    function testDeployToRewardSwapsAndDistributes() public {
        _buy(alice, 0);
        vm.deal(address(vault), 5 ether); // simulate BNB fees received

        vm.prank(GUARDIAN);
        uint256 out = vault.deployToReward(2 ether, 1 ether);
        assertEq(out, 2 ether); // mock 1:1
        assertApproxEqAbs(vault.pendingRewards(alice), 2 ether, 100);
        assertEq(vault.totalNativeDeployed(), 2 ether);
    }

    function testDeployToRewardOnlyGuardian() public {
        vm.deal(address(vault), 5 ether);
        vm.expectRevert();
        vault.deployToReward(1 ether, 0);
    }

    function testDeployToRewardSlippageReverts() public {
        _buy(alice, 0);
        vm.deal(address(vault), 5 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes("MockRouter: slippage"));
        vault.deployToReward(1 ether, 2 ether); // minOut > out
    }

    // ── edges / audit-fix coverage ─────────────────────────────────────

    function testMaxRigsCap() public {
        for (uint256 i = 0; i < 16; i++) {
            _buy(alice, 0);
        }
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Too many rigs / 矿机数量过多"));
        vault.buyMiningContract{value: price}(0);
    }

    function testRefundExcess() public {
        uint256 before = alice.balance;
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vault.buyMiningContract{value: price + 1 ether}(0);
        // only price consumed, 1 ether refunded
        assertEq(alice.balance, before - price);
    }

    function testRefundRevertingBuyerReverts() public {
        RevertingBuyer rb = new RevertingBuyer();
        vm.deal(address(rb), 10 ether);
        (uint256 price,,,) = vault.getPlan(0);
        vm.expectRevert();
        rb.buy{value: price + 1 ether}(vault, 0);
    }

    function testPausableBlocksBuy() public {
        vm.prank(GUARDIAN);
        vault.pauseVault();
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert();
        vault.buyMiningContract{value: price}(0);

        vm.prank(GUARDIAN);
        vault.unpauseVault();
        _buy(alice, 0);
        (uint256 count,,,,) = vault.getUserMinerStats(alice);
        assertEq(count, 1);
    }

    function testBuyAfterSeasonEndReverts() public {
        vm.warp(seasonEnd + 1);
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Mining season ended / 挖矿赛季已结束"));
        vault.buyMiningContract{value: price}(0);
    }

    function testEmergencyWithdrawNativeGuardianCooldown() public {
        vm.deal(address(vault), 3 ether);
        vm.prank(GUARDIAN);
        vault.emergencyWithdrawNative(GUARDIAN);
        assertEq(address(vault).balance, 0);

        // second call within cooldown reverts
        vm.deal(address(vault), 1 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Cooldown / 冷却期"));
        vault.emergencyWithdrawNative(GUARDIAN);
    }

    function testEmergencyWithdrawOnlyGuardian() public {
        vm.deal(address(vault), 1 ether);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vault.emergencyWithdrawNative(alice);
    }

    // ── factory upgrade timelock ───────────────────────────────────────

    function testUpgradeTimelock() public {
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();

        vm.prank(GUARDIAN);
        factory.scheduleUpgrade(address(newImpl));

        // too early
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Timelock not elapsed / 时间锁未到"));
        factory.executeUpgrade();

        vm.warp(block.timestamp + factory.UPGRADE_DELAY());
        vm.prank(GUARDIAN);
        factory.executeUpgrade();
        assertEq(factory.beaconImplementation(), address(newImpl));
    }

    function testScheduleUpgradeOnlyGuardian() public {
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.scheduleUpgrade(address(newImpl));
    }

    // ── invariants ─────────────────────────────────────────────────────

    function testNoDoubleClaim() public {
        _buy(alice, 0);
        _inject(10 ether);
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Nothing to claim / 无可领取"));
        vault.claimRewards();
    }

    function testInvariantClaimedLeqDistributed() public {
        _buy(alice, 1); // 40
        _buy(bob, 2); // 130
        _inject(100 ether);
        vm.warp(block.timestamp + 1 days);
        _inject(50 ether);

        vm.prank(alice);
        vault.claimRewards();
        vm.warp(block.timestamp + 2 days);
        _inject(33 ether);
        vm.prank(bob);
        vault.claimRewards();

        // Σ claimed never exceeds Σ distributed; vault balance covers remaining pending
        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed());
        uint256 outstanding = vault.pendingRewards(alice) + vault.pendingRewards(bob);
        assertGe(reward.balanceOf(address(vault)) + 1e6, outstanding); // +dust tolerance
    }

    function testGetMiningContractView() public {
        _buy(alice, 2); // Mega: 130 power, 30 days
        (uint256 id, uint256 planId, uint256 power,,,, uint256 pending, bool active) =
            vault.getMiningContract(alice, 0);
        assertEq(id, 1);
        assertEq(planId, 2);
        assertEq(power, 130);
        assertEq(pending, 0);
        assertTrue(active);
    }

    // S4 (Flap rule 005/006): receive() must stay well under the 1,000,000 gas budget.
    function testReceiveGasUnder1M() public {
        vm.deal(address(this), 2 ether);
        uint256 g = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 used = g - gasleft();
        assertTrue(ok, "receive failed");
        assertLe(used, 1_000_000, "receive() must stay under 1M gas (Flap rule 005)");
    }

    receive() external payable {}
}
