// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
import {
    RamPricingNotArmed,
    RigExpired,
    InvalidUpgrade,
    UnexpectedValue,
    NothingToRepair,
    TooManyRigs,
    EntryRigMustBeMicro,
    InsufficientPayment,
    StaleFeed,
    BadConfig
} from "../src/RamMiningVault.sol";

contract P2MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract P2MockFeed {
    int256 internal _answer;
    uint256 internal _updatedAt; // 0 = always fresh (mirrors block.timestamp); nonzero = pinned (stale tests)

    constructor(int256 a) {
        _answer = a;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function refreshTo(int256 a) external {
        _answer = a;
    }

    /// @dev Pin `updatedAt` so a later vm.warp makes the feed STALE (v3.2 USD-sink fail-closed tests).
    function setUpdatedAt(uint256 t) external {
        _updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 upd = _updatedAt == 0 ? block.timestamp : _updatedAt;
        return (1, _answer, upd, upd, 1);
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
    using stdStorage for StdStorage;

    address constant PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant DEV = 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant TREASURY = address(0x7E57); // dedicated 15%-share treasury wallet

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
    // $0.60 (8 dec) — calibrated to basePrice × the mock BNB/USD ($600) so the BNB and USD tables agree at t0
    // (exactly what the launcher does on launch day). Keeps every legacy RAM-unit expectation numerically intact:
    // usd·1e36/(bnbUsd·price) == bnbCost·1e18/price when usd = bnbCost·bnbUsd/1e18.
    uint256 basePriceUsd = 6e7;
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
            address(reward), address(nvdaFeed), address(bnbFeed), basePrice, basePriceUsd, seasonEnd,
            address(oracle), CAGE_MIN, CAGE_MAX, TREASURY
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

    /// @dev v3 entry-gate: a fresh wallet may only buy plan 0 (Micro) with BNB. For any higher tier this
    ///      helper performs the LEGAL post-gate flow — mark the wallet as already-entered (stdstore) and buy
    ///      through the RAM path — so every scenario keeps the exact same rig (power/duration/id), the same
    ///      clock and the same math, with no extra entry rig. RAM pricing is armed in setUp.
    function _buyBnb(address who, uint256 plan) internal {
        if (plan != 0) {
            _enter(who);
            _buyRam(who, plan);
            return;
        }
        (uint256 price,,,) = vault.getPlan(plan);
        vm.prank(who);
        vault.buyMiningContract{value: price}(plan);
    }

    /// @dev Mark `who` as already-entered (the post-gate precondition), without minting an entry rig.
    function _enter(address who) internal {
        stdstore.target(address(vault)).sig("hasEnteredBefore(address)").with_key(who).checked_write(true);
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
        assertEq(ram.balanceOf(TREASURY), units - burned); // 15% paid out to the dedicated treasury wallet
        assertEq(ram.balanceOf(address(vault)), 0); // nothing retained in the vault
        (uint256 paid, uint256 burnedStat, uint256 treasuryPaid,,,,) = vault.getRamEconomyStats();
        assertEq(paid, units);
        assertEq(burnedStat, burned);
        assertEq(treasuryPaid, units - burned);
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

    // ── entry gate (v3): a fresh wallet's BNB rig must be the Micro ─────
    // Found in live testnet QA (2026-07-03): without this gate a fresh wallet bought the Hyper straight
    // in BNB and never touched the RAM economy. High tiers must flow through the RAM sinks.

    function testEntryGateRejectsEveryNonMicroFirstBuy() public {
        for (uint256 plan = 1; plan < 4; plan++) {
            (uint256 price,,,) = vault.getPlan(plan);
            vm.prank(alice);
            vm.expectRevert(EntryRigMustBeMicro.selector);
            vault.buyMiningContract{value: price}(plan);
        }
        // nothing happened: the wallet is still fresh and holds no rigs
        assertFalse(vault.hasEnteredBefore(alice));
        (uint256 count,,,,) = vault.getUserMinerStats(alice);
        assertEq(count, 0);
        assertEq(vault.totalNativePaid(), 0);
    }

    function testEntryUnderpayReverts() public {
        // judge MENOR-1: the entry payment check itself had no direct test (pre-existing gap, now that the
        // entry path changed it gets one)
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(InsufficientPayment.selector);
        vault.buyMiningContract{value: price - 1}(0);
    }

    function testEntryGateOverpayingDoesNotBypass() public {
        // paying the Hyper price (or more) for a non-entry plan still reverts — the gate is on the plan,
        // not on the amount
        (uint256 hyperPrice,,,) = vault.getPlan(3);
        vm.prank(alice);
        vm.expectRevert(EntryRigMustBeMicro.selector);
        vault.buyMiningContract{value: hyperPrice * 2}(3);
    }

    function testEntryGateMicroThenRamHyperIsTheIntendedPath() public {
        assertEq(vault.ENTRY_PLAN_ID(), 0);
        _buyBnb(alice, 0); // entry: Micro in BNB — the ONLY legal first buy
        (uint256 hyperPrice,, uint256 hyperDuration,) = vault.getPlan(3);
        uint256 units = _ramUnitsFor(hyperPrice); // growth: Hyper paid fully in RAM (100x base, USD-target)
        uint256 before = ram.balanceOf(alice);
        _buyRam(alice, 3);
        assertEq(ram.balanceOf(alice), before - units);
        (uint256 count, uint256 power,,,) = vault.getUserMinerStats(alice);
        assertEq(count, 2); // Micro (entry) + Hyper (growth)
        assertEq(power, 100 + 1065); // v3.2 rebalanced table powers (flat yield-per-$, ~+5% commitment premium)
        // the Hyper carries its full audited duration
        (,,,, uint256 endTime,,, bool active) = vault.getMiningContract(alice, 1);
        assertTrue(active);
        assertEq(endTime, block.timestamp + hyperDuration);
    }

    function testEntryGateUpgradeFromMicroStaysAvailable() public {
        _buyBnb(alice, 0); // Micro entry
        uint256 before = ram.balanceOf(alice);
        (uint256 microPrice,,,) = vault.getPlan(0);
        (uint256 corePrice,,,) = vault.getPlan(1);
        vm.prank(alice);
        vault.upgradeRig(0, 1); // evolve the entry rig itself: pay the Core-Micro difference in RAM
        assertEq(ram.balanceOf(alice), before - _ramUnitsFor(corePrice - microPrice));
        (, uint256 planId, uint256 power,,,,, bool active) = vault.getMiningContract(alice, 0);
        assertTrue(active);
        assertEq(planId, 1);
        assertEq(power, 400);
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
        _buyBnb(alice, 3); // Hyper: 1065 power (v3.2 table), 90d, bought at t = 100 days
        (, uint256 p0,,) = vault.getPlan(3);
        assertEq(p0, 1065);
        (, uint256 cur,,,,) = _wear(alice, 0);
        assertEq(cur, 1065);

        vm.warp(103 days); // 1 step: 1065×0.95 = 1011.75 → 1011
        (, cur,,,,) = _wear(alice, 0);
        assertEq(cur, 1011);

        vm.warp(106 days); // 2 steps: 1011×0.95 = 960.45 → 960
        (, cur,,,,) = _wear(alice, 0);
        assertEq(cur, 960);

        vm.warp(159 days); // deep into the 90d life (still alive): floor = 1065×0.47 = 500.55 → 500
        (uint256 lvl, uint256 cur2, uint256 floorP,,,) = _wear(alice, 0);
        assertEq(lvl, 1065); // schedule start level unchanged (no repair)
        assertEq(floorP, 500);
        assertEq(cur2, 500); // decayed to the floor, NEVER zero while alive
    }

    /// @dev Aggregate machinery consistency: after settle, global active power equals the rig's live level.
    function testWearAggregateMatchesPerRig() public {
        _buyBnb(alice, 3); // Hyper 1065
        vm.warp(block.timestamp + 7 days); // two steps settled (1011 → 960)
        vault.donateReward(1); // forces _settleExpiries
        (, uint256 cur,,,,) = _wear(alice, 0);
        (,, uint256 globalPower,,,,) = vault.getVaultMiningStats();
        assertEq(globalPower, cur);
        assertEq(cur, 960);
    }

    function testWearAdjustsRewardSplit() public {
        _buyBnb(alice, 2); // Mega 560, 30d
        vm.warp(block.timestamp + 3 days + 1 hours); // alice stepped: 560×0.95 = 532
        _buyBnb(bob, 1); // Core 400, fresh (its first step is 3d away)
        vault.donateReward(932 ether); // settles: total power = 532 + 400 = 932
        assertApproxEqAbs(vault.pendingRewards(alice), 532 ether, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 400 ether, 1e6);
    }

    // ── repair ──────────────────────────────────────────────────────────

    function testRepairRestoresPowerRespectsAgeCapAndLife() public {
        _buyBnb(alice, 3); // Hyper 1065, 90d
        (,,,, uint256 lifeEnds0,) = _wear(alice, 0);

        vm.warp(block.timestamp + 12 days); // 4 steps: 1065→1011→960→912→866
        (, uint256 cur,,,,) = _wear(alice, 0);
        assertEq(cur, 866);
        vault.donateReward(866 ether); // some pending at the worn level
        uint256 pendingBefore = vault.pendingRewards(alice);
        assertApproxEqAbs(pendingBefore, 866 ether, 1e6);

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

        // age 12d of the Hyper's 90d → penalty 3000×12/90 = 400 bps → cap 96% → restored = 1065×0.96 = 1022.4 → 1022
        (uint256 lvl, uint256 cur2,,, uint256 lifeEnds1, uint256 accrued) = _wear(alice, 0);
        assertEq(lvl, 1022);
        assertEq(cur2, 1022);
        assertEq(lifeEnds1, lifeEnds0); // RIG_LIFE wall NEVER extended
        assertApproxEqAbs(accrued, pendingBefore, 1e6); // pending checkpointed, not lost

        // aggregate consistent after reschedule
        (,, uint256 globalPower,,,,) = vault.getVaultMiningStats();
        assertEq(globalPower, 1022);

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
        _buyBnb(alice, 1); // Core 400, 7d
        vm.warp(block.timestamp + 6 days); // 2 steps: 400→380→361 (still alive: dies at 7d)
        (, uint256 cur,,,,) = _wear(alice, 0);
        assertEq(cur, 361);
        (,,,, uint256 lifeEnds0,) = _wear(alice, 0);

        (uint256 oldPrice,,,) = vault.getPlan(1);
        (uint256 newPrice, uint256 newPower,,) = vault.getPlan(2); // Mega 560
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

    // ── v3.2 USD-target sink (fixed USD stickers, BNB/USD feed in the growth path) ─

    uint256 constant BNB_USD_P2 = 600e8; // the fixture's mock BNB/USD answer (8 dec)

    /// @dev The USD → RAM units conversion the vault performs: usd·1e36 / (bnbUsd·ramPrice).
    function _usdUnits(uint256 usd) internal pure returns (uint256) {
        return (usd * 1e36) / (BNB_USD_P2 * RAM_BNB_PRICE);
    }

    function testGetPlanUsdTable() public view {
        assertEq(vault.basePriceUsd(), basePriceUsd);
        assertEq(vault.getPlanUsd(0), basePriceUsd); // ×1
        assertEq(vault.getPlanUsd(1), basePriceUsd * 5); // ×5
        assertEq(vault.getPlanUsd(2), basePriceUsd * 25); // ×25
        assertEq(vault.getPlanUsd(3), basePriceUsd * 100); // ×100
    }

    function testQuoteAndChargeMatchUsdTarget() public {
        // quote = the plan's fixed USD target converted at the live BNB/USD + caged RAM price
        (uint256 quoted, bool trusted) = vault.quoteRigInRam(1);
        assertTrue(trusted);
        assertEq(quoted, _usdUnits(basePriceUsd * 5));

        // and the actual charge matches the quote exactly
        _buyBnb(alice, 0);
        uint256 before = ram.balanceOf(alice);
        _buyRam(alice, 1);
        assertEq(before - ram.balanceOf(alice), quoted);
    }

    function testUsdStickerConstantWhenBnbMoves() public {
        _buyBnb(alice, 0);
        (uint256 unitsAt600,) = vault.quoteRigInRam(1);

        // BNB halves in USD → the SAME $-sticker costs twice the BNB → twice the RAM units
        bnbFeed.refreshTo(300e8);
        (uint256 unitsAt300,) = vault.quoteRigInRam(1);
        assertEq(unitsAt300, unitsAt600 * 2);
        assertEq(vault.getPlanUsd(1), basePriceUsd * 5); // the USD sticker itself never moves

        // charge follows the live conversion
        uint256 before = ram.balanceOf(alice);
        _buyRam(alice, 1);
        assertEq(before - ram.balanceOf(alice), unitsAt300);
    }

    function testStaleBnbFeedBlocksGrowthNotEntryNorClaim() public {
        // alice is a live miner with a growth Core (bought while the feed is fresh)
        _buyBnb(alice, 0);
        _buyRam(alice, 1);
        vault.donateReward(10 ether);

        // pin the BNB/USD feed and outrun bnbFeedMaxStale (default 2h) → the feed is now STALE
        bnbFeed.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + 3 hours);

        // growth purchases fail CLOSED (never a mis-priced sink)…
        vm.prank(alice);
        vm.expectRevert(StaleFeed.selector);
        vault.buyMiningContract(0);
        vm.prank(alice);
        vm.expectRevert(StaleFeed.selector);
        vault.upgradeRig(1, 2); // Core → Mega hits the USD charge
        vm.expectRevert(StaleFeed.selector);
        vault.quoteRigInRam(1); // quotes are honest: they revert exactly like the buy would

        // …but the BNB entry gate and claims never touch the BNB/USD feed
        vm.deal(bob, 1 ether);
        (uint256 microPrice,,,) = vault.getPlan(0);
        vm.prank(bob);
        vault.buyMiningContract{value: microPrice}(0); // fresh wallet still enters
        vm.prank(alice);
        assertGt(vault.claimRewards(), 0); // claim always available

        // feed recovers → growth resumes
        bnbFeed.setUpdatedAt(0);
        _buyRam(alice, 0);
    }

    function testRepairAndUpgradeChargeUsdTargets() public {
        _buyBnb(alice, 3); // Hyper
        vm.warp(block.timestamp + 6 days); // worn (2 steps) → repairable, still young (age cap 98%)

        // repair: repairCostBps (40%) of the plan's USD target
        (uint256 repairQuote, bool t1) = vault.quoteRepairInRam(alice, 0);
        assertTrue(t1);
        assertEq(repairQuote, _usdUnits((basePriceUsd * 100 * 4000) / 10000));

        // upgrade: the USD-target DIFFERENCE between the plans
        _enter(bob);
        vm.deal(bob, 1 ether);
        _buyRam(bob, 1); // bob holds a Core growth rig
        (uint256 upQuote, bool t2) = vault.quoteUpgradeInRam(bob, 0, 2);
        assertTrue(t2);
        assertEq(upQuote, _usdUnits(basePriceUsd * 25 - basePriceUsd * 5));
        uint256 before = ram.balanceOf(bob);
        vm.prank(bob);
        vault.upgradeRig(0, 2);
        assertEq(before - ram.balanceOf(bob), upQuote);
    }

    function testBasePriceUsdZeroRevertsBadConfig() public {
        bytes memory vd = abi.encode(
            address(reward), address(nvdaFeed), address(bnbFeed), basePrice, uint256(0), seasonEnd,
            address(oracle), CAGE_MIN, CAGE_MAX, TREASURY
        );
        vm.prank(PORTAL);
        vm.expectRevert(BadConfig.selector);
        factory.newVault(address(ram), address(0), DEV, vd);
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
