// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
import {
    RamPricingNotArmed,
    RigExpired,
    InvalidUpgrade,
    UnexpectedValue,
    NothingToRepair,
    TooManyRigs
} from "../src/RamMiningVault.sol";

contract P2MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract P2MockFeed {
    int256 internal _answer;

    constructor(int256 a) {
        _answer = a;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function refreshTo(int256 a) external {
        _answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

contract P2MockRamOracle {
    uint256 public price;
    bool public trusted;
    bool public revertCalls;
    uint256 public pokes;

    function set(uint256 p, bool t) external {
        price = p;
        trusted = t;
    }

    function setRevert(bool v) external {
        revertCalls = v;
    }

    function pokeAndGetPrice(address) external returns (uint256, bool) {
        require(!revertCalls, "oracle down");
        pokes += 1;
        return (price, trusted);
    }

    function getPrice(address) external view returns (uint256, bool) {
        require(!revertCalls, "oracle down");
        return (price, trusted);
    }
}

/// @title Phase-2 economy suite (v3): two-phase payments, wear ladder, repair, upgrade, caged RAM pricing.
contract RamMiningVaultPhase2Test is Test {
    address constant PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant DEV = 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant RAM_BNB_PRICE = 2e12; // 1 RAM = 0.000002 BNB
    uint256 constant CAGE_MIN = 1e12;
    uint256 constant CAGE_MAX = 4e12;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    P2MockToken reward;
    P2MockToken ram;
    P2MockRamOracle oracle;
    P2MockFeed nvdaFeed;
    P2MockFeed bnbFeed;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;
    uint256 seasonEnd;

    function setUp() public {
        vm.chainId(97);
        vm.warp(100 days); // clean bucket boundary far from 0
        reward = new P2MockToken();
        ram = new P2MockToken();
        oracle = new P2MockRamOracle();
        nvdaFeed = new P2MockFeed(130e8);
        bnbFeed = new P2MockFeed(600e8);
        factory = new RamMiningBeaconFactory();

        seasonEnd = block.timestamp + 90 days; // long enough for every plan to get its full audited duration
        // launcher-armed Phase-2: oracle + cage travel in vaultData (no Guardian round-trip needed)
        oracle.set(RAM_BNB_PRICE, true);
        bytes memory vd = abi.encode(
            address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd,
            address(oracle), CAGE_MIN, CAGE_MAX
        );
        vm.prank(PORTAL);
        vault = RamMiningVaultUpgradeable(payable(factory.newVault(address(ram), address(0), DEV, vd)));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        ram.mint(alice, 1e27);
        ram.mint(bob, 1e27);
        vm.prank(alice);
        ram.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        ram.approve(address(vault), type(uint256).max);
        reward.mint(address(this), 1e27);
        reward.approve(address(vault), type(uint256).max);
    }

    function _buyBnb(address who, uint256 plan) internal {
        (uint256 price,,,) = vault.getPlan(plan);
        vm.prank(who);
        vault.buyMiningContract{value: price}(plan);
    }

    function _buyRam(address who, uint256 plan) internal {
        vm.prank(who);
        vault.buyMiningContract(plan);
    }

    function _ramUnitsFor(uint256 bnbCost) internal pure returns (uint256) {
        return (bnbCost * 1e18) / RAM_BNB_PRICE;
    }

    // ── two-phase payment branching ─────────────────────────────────────

    function testFirstRigBnbSecondRigRamWithBurnSplit() public {
        _buyBnb(alice, 0); // entry rig: BNB
        assertTrue(vault.hasEnteredBefore(alice));
        assertEq(vault.totalNativePaid(), basePrice);

        uint256 units = _ramUnitsFor(basePrice); // Micro again, now in RAM
        uint256 aliceRamBefore = ram.balanceOf(alice);
        _buyRam(alice, 0);

        assertEq(ram.balanceOf(alice), aliceRamBefore - units);
        uint256 burned = (units * 8500) / 10000;
        assertEq(ram.balanceOf(DEAD), burned);
        assertEq(ram.balanceOf(address(vault)), units - burned);
        (uint256 paid, uint256 burnedStat, uint256 treasury,,,,) = vault.getRamEconomyStats();
        assertEq(paid, units);
        assertEq(burnedStat, burned);
        assertEq(treasury, units - burned);
        assertEq(vault.totalNativePaid(), basePrice); // BNB stat untouched by the RAM path
    }

    function testSecondRigRejectsBnb() public {
        _buyBnb(alice, 0);
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(UnexpectedValue.selector);
        vault.buyMiningContract{value: price}(0);
    }

    function testRamPathDisarmedReverts() public {
        vm.prank(GUARDIAN);
        vault.setRamPriceCage(0, 0); // disarm
        _buyBnb(alice, 0); // BNB entry still fine
        vm.prank(alice);
        vm.expectRevert(RamPricingNotArmed.selector);
        vault.buyMiningContract(0);
    }

    function testEntryFlagPersistsAcrossExpiry() public {
        _buyBnb(alice, 0);
        vm.warp(block.timestamp + 61 days); // rig expired (and compacted on next buy)
        // still a returning wallet: next rig must be RAM, not BNB
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(UnexpectedValue.selector);
        vault.buyMiningContract{value: price}(0);
        _buyRam(alice, 0); // works without value
    }

    // ── wear ladder ─────────────────────────────────────────────────────

    function testWearLadderStepsAndFloor() public {
        // NOTE: LITERAL absolute warp targets (setUp pins t=100 days). With via_ir the optimizer treats
        // TIMESTAMP as constant within a call and propagates `block.timestamp` to its use sites — even through
        // a local variable — so any warp target derived from block.timestamp after a prior warp is wrong
        // (cheatcode-only artifact; in production the timestamp IS constant within a tx).
        _buyBnb(alice, 3); // Hyper: 420 power (AUDITED table), 90d, bought at t = 100 days
        (, uint256 p0,,) = vault.getPlan(3);
        assertEq(p0, 420);
        (, uint256 cur,,,,) = _wear(alice, 0);
        assertEq(cur, 420);

        vm.warp(103 days); // 1 step: 420×0.95 = 399
        (, cur,,,,) = _wear(alice, 0);
        assertEq(cur, 399);

        vm.warp(106 days); // 2 steps: 399×0.95 = 379.05 → 379
        (, cur,,,,) = _wear(alice, 0);
        assertEq(cur, 379);

        vm.warp(159 days); // deep into the 90d life (still alive): floor = 420×0.47 = 197.4 → 197
        (uint256 lvl, uint256 cur2, uint256 floorP,,,) = _wear(alice, 0);
        assertEq(lvl, 420); // schedule start level unchanged (no repair)
        assertEq(floorP, 197);
        assertEq(cur2, 197); // decayed to the floor, NEVER zero while alive
    }

    /// @dev Aggregate machinery consistency: after settle, global active power equals the rig's live level.
    function testWearAggregateMatchesPerRig() public {
        _buyBnb(alice, 3); // Hyper 420
        vm.warp(block.timestamp + 7 days); // two steps settled (399 → 379)
        vault.donateReward(1); // forces _settleExpiries
        (, uint256 cur,,,,) = _wear(alice, 0);
        (,, uint256 globalPower,,,,) = vault.getVaultMiningStats();
        assertEq(globalPower, cur);
        assertEq(cur, 379);
    }

    function testWearAdjustsRewardSplit() public {
        _buyBnb(alice, 2); // Mega 130, 30d
        vm.warp(block.timestamp + 3 days + 1 hours); // alice stepped: 130×0.95 = 123.5 → 123
        _buyBnb(bob, 1); // Core 40, fresh (its first step is 3d away)
        vault.donateReward(163 ether); // settles: total power = 123 + 40 = 163
        assertApproxEqAbs(vault.pendingRewards(alice), 123 ether, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 40 ether, 1e6);
    }

    // ── repair ──────────────────────────────────────────────────────────

    function testRepairRestoresPowerRespectsAgeCapAndLife() public {
        _buyBnb(alice, 3); // Hyper 420, 90d
        (,,,, uint256 lifeEnds0,) = _wear(alice, 0);

        vm.warp(block.timestamp + 12 days); // 4 steps: 420→399→379→360→342
        (, uint256 cur,,,,) = _wear(alice, 0);
        assertEq(cur, 342);
        vault.donateReward(342 ether); // some pending at the worn level
        uint256 pendingBefore = vault.pendingRewards(alice);
        assertApproxEqAbs(pendingBefore, 342 ether, 1e6);

        // repair cost: planPrice × 40% → RAM units
        (uint256 planPrice,,,) = vault.getPlan(3);
        uint256 expectedUnits = _ramUnitsFor((planPrice * 4000) / 10000);
        (uint256 quoted, bool trusted) = vault.quoteRepairInRam(alice, 0);
        assertTrue(trusted);
        assertEq(quoted, expectedUnits);

        uint256 ramBefore = ram.balanceOf(alice);
        vm.prank(alice);
        vault.repairRig(0);
        assertEq(ram.balanceOf(alice), ramBefore - expectedUnits);

        // age 12d of the Hyper's 90d → penalty 3000×12/90 = 400 bps → cap 96% → restored = 420×0.96 = 403.2 → 403
        (uint256 lvl, uint256 cur2,,, uint256 lifeEnds1, uint256 accrued) = _wear(alice, 0);
        assertEq(lvl, 403);
        assertEq(cur2, 403);
        assertEq(lifeEnds1, lifeEnds0); // RIG_LIFE wall NEVER extended
        assertApproxEqAbs(accrued, pendingBefore, 1e6); // pending checkpointed, not lost

        // aggregate consistent after reschedule
        (,, uint256 globalPower,,,,) = vault.getVaultMiningStats();
        assertEq(globalPower, 403);

        // the checkpointed pending is claimable
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, pendingBefore, 1e6);
    }

    function testRepairFreshRigReverts() public {
        _buyBnb(alice, 0);
        vm.prank(alice);
        vm.expectRevert(NothingToRepair.selector);
        vault.repairRig(0); // nothing worn yet (and age-cap 100% > current is false at 100%)
    }

    function testRepairExpiredRigReverts() public {
        _buyBnb(alice, 0);
        vm.warp(block.timestamp + 61 days);
        vm.prank(alice);
        vm.expectRevert(RigExpired.selector);
        vault.repairRig(0);
    }

    // ── upgrade ─────────────────────────────────────────────────────────

    function testUpgradeTierPaysDifferenceAndRestartsWear() public {
        _buyBnb(alice, 1); // Core 40, 7d
        vm.warp(block.timestamp + 6 days); // 2 steps: 40→38→36 (still alive: dies at 7d)
        (, uint256 cur,,,,) = _wear(alice, 0);
        assertEq(cur, 36);
        (,,,, uint256 lifeEnds0,) = _wear(alice, 0);

        (uint256 oldPrice,,,) = vault.getPlan(1);
        (uint256 newPrice, uint256 newPower,,) = vault.getPlan(2); // Mega 130
        uint256 expectedUnits = _ramUnitsFor(newPrice - oldPrice);
        (uint256 quoted, bool trusted) = vault.quoteUpgradeInRam(alice, 0, 2);
        assertTrue(trusted);
        assertEq(quoted, expectedUnits);

        uint256 ramBefore = ram.balanceOf(alice);
        vm.prank(alice);
        vault.upgradeRig(0, 2);
        assertEq(ram.balanceOf(alice), ramBefore - expectedUnits);

        (uint256 id, uint256 planId, uint256 power,,,,, bool active) = vault.getMiningContract(alice, 0);
        assertEq(id, 1);
        assertEq(planId, 2);
        assertEq(power, newPower); // fresh hardware at full new-tier power
        assertTrue(active);
        (,,,, uint256 lifeEnds1,) = _wear(alice, 0);
        assertEq(lifeEnds1, lifeEnds0); // life anchored to ORIGINAL mint

        (,, uint256 globalPower,,,,) = vault.getVaultMiningStats();
        assertEq(globalPower, newPower);
    }

    function testUpgradeRejectsDowngradeAndSamePlan() public {
        _buyBnb(alice, 1); // Core (7d)
        vm.startPrank(alice);
        vm.expectRevert(InvalidUpgrade.selector);
        vault.upgradeRig(0, 1); // same plan
        vm.expectRevert(InvalidUpgrade.selector);
        vault.upgradeRig(0, 0); // downgrade
        vm.stopPrank();
    }

    // ── caged pricing (judge-mandated fail-safe shape) ──────────────────

    function testUntrustedOracleDegradesToCageMin() public {
        _buyBnb(alice, 0);
        oracle.set(RAM_BNB_PRICE, false); // untrusted → degrade
        uint256 unitsAtFloor = (basePrice * 1e18) / CAGE_MIN; // cheapest RAM assumed → MOST units
        uint256 before = ram.balanceOf(alice);
        _buyRam(alice, 0);
        assertEq(before - ram.balanceOf(alice), unitsAtFloor);
    }

    function testRevertingOracleDegradesToCageMin() public {
        _buyBnb(alice, 0);
        oracle.setRevert(true); // oracle down → try/catch → degrade, never brick
        uint256 unitsAtFloor = (basePrice * 1e18) / CAGE_MIN;
        uint256 before = ram.balanceOf(alice);
        _buyRam(alice, 0);
        assertEq(before - ram.balanceOf(alice), unitsAtFloor);
    }

    function testTrustedPriceClampedIntoCage() public {
        _buyBnb(alice, 0);
        oracle.set(CAGE_MAX * 10, true); // manipulated-high read → clamped to cageMax (fewest units bound)
        uint256 unitsAtMax = (basePrice * 1e18) / CAGE_MAX;
        uint256 before = ram.balanceOf(alice);
        _buyRam(alice, 0);
        assertEq(before - ram.balanceOf(alice), unitsAtMax);

        oracle.set(CAGE_MIN / 2, true); // manipulated-low read → clamped to cageMin
        uint256 unitsAtMin = (basePrice * 1e18) / CAGE_MIN;
        before = ram.balanceOf(alice);
        _buyRam(alice, 0);
        assertEq(before - ram.balanceOf(alice), unitsAtMin);
    }

    function testClaimNeverTouchesOracle() public {
        _buyBnb(alice, 0);
        vault.donateReward(10 ether);
        oracle.setRevert(true); // oracle dead
        vm.prank(GUARDIAN);
        vault.setRamPriceCage(0, 0); // RAM path fully disarmed
        vm.prank(alice);
        uint256 got = vault.claimRewards(); // claim MUST be oracle-independent
        assertApproxEqAbs(got, 10 ether, 100);
    }

    // ── invariant under the full Phase-2 lifecycle ──────────────────────

    function testInvariantClaimedLeDistributedUnderWearRepairUpgrade() public {
        // LITERAL absolute warps (setUp pins t=100 days; via_ir propagates block.timestamp — see ladder test)
        _buyBnb(alice, 0);
        _buyBnb(bob, 3);
        vault.donateReward(100 ether);

        vm.warp(109 days);
        vault.donateReward(50 ether);
        vm.prank(alice);
        vault.claimRewards();

        vm.warp(115 days);
        vm.prank(bob);
        vault.repairRig(0);
        _buyRam(alice, 1);
        vault.donateReward(80 ether);

        vm.warp(118 days); // alice's RAM Core (bought at 115d, 7d life) is still alive
        // NOTE: index 0 — the dead, fully-claimed Micro was compacted away by the RAM buy at 115d
        vm.prank(alice);
        vault.upgradeRig(0, 2);
        vault.donateReward(70 ether);

        vm.warp(167 days); // early rigs expired (Micro 1d, Cores 7d, Mega-upgraded 122d); Hyper still alive
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(bob);
        vault.claimRewards();

        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed());
        // no value stranded beyond dust: everything distributed is claimable by SOMEONE
        uint256 stillPending = vault.pendingRewards(alice) + vault.pendingRewards(bob);
        assertApproxEqAbs(
            vault.totalRewardClaimed() + stillPending, vault.totalRewardDistributed(), 1e9
        );
    }

    function testFuzzWearConsistency(uint256 daysFwd) public {
        daysFwd = bound(daysFwd, 1, 70);
        _buyBnb(alice, 3);
        _buyBnb(bob, 2);
        vm.warp(block.timestamp + daysFwd * 1 days);
        vault.donateReward(1); // settle
        ( , uint256 curA,,,,) = _wear(alice, 0);
        ( , uint256 curB,,,,) = _wear(bob, 0);
        (,, uint256 globalPower,,,,) = vault.getVaultMiningStats();
        assertEq(globalPower, curA + curB, "aggregate power must equal the sum of live rig levels");
        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed());
    }

    // ── helpers ─────────────────────────────────────────────────────────

    function _wear(address user, uint256 index)
        internal
        view
        returns (uint256 lvl, uint256 cur, uint256 floorP, uint256 wearStart, uint256 lifeEnds, uint256 accrued)
    {
        (lvl, cur, floorP, wearStart, lifeEnds, accrued) = vault.getRigWear(user, index);
    }
}
