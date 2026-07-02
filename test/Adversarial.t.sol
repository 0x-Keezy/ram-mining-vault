// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
import {NothingToRepair, NothingToClaim} from "../src/RamMiningVault.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Adversarial suite (v3 wear-ladder edges). Written by the audit review, NOT the
//  author. Every test asserts an INVARIANT that must hold under hostile timing:
//    - the aggregate `totalActivePower` never diverges from Σ live per-rig levels
//    - it collapses to EXACTLY 0 after all rigs expire (no orphan deltas)
//    - Σ claimed ≤ Σ distributed under repair/upgrade churn
//    - no underflow/double-count across claim → reschedule → claim
//
//  NOTE ON WARPS (matches the Phase-2 suite comment): setUp pins t = 100 days.
//  Under via_ir the optimizer treats block.timestamp as constant within a call, so
//  warp targets are LITERAL absolutes (vm.warp(NNN days)), never block.timestamp+X.
// ─────────────────────────────────────────────────────────────────────────────

contract AdvToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AdvFeed {
    int256 internal _answer;

    constructor(int256 a) {
        _answer = a;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

contract AdvRamOracle {
    uint256 public price;
    bool public trusted;

    function set(uint256 p, bool t) external {
        price = p;
        trusted = t;
    }

    function pokeAndGetPrice(address) external view returns (uint256, bool) {
        return (price, trusted);
    }

    function getPrice(address) external view returns (uint256, bool) {
        return (price, trusted);
    }
}

contract AdversarialTest is Test {
    address constant PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant DEV = 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1;

    uint256 constant RAM_BNB_PRICE = 2e12;
    uint256 constant CAGE_MIN = 1e12;
    uint256 constant CAGE_MAX = 4e12;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    AdvToken reward;
    AdvToken ram;
    AdvRamOracle oracle;
    AdvFeed nvdaFeed;
    AdvFeed bnbFeed;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;
    uint256 seasonEnd;

    function setUp() public {
        vm.chainId(97);
        vm.warp(100 days);
        reward = new AdvToken();
        ram = new AdvToken();
        oracle = new AdvRamOracle();
        nvdaFeed = new AdvFeed(130e8);
        bnbFeed = new AdvFeed(600e8);
        factory = new RamMiningBeaconFactory();

        seasonEnd = block.timestamp + 300 days; // long season: no season-cap interference
        oracle.set(RAM_BNB_PRICE, true);
        bytes memory vd = abi.encode(
            address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd,
            address(oracle), CAGE_MIN, CAGE_MAX, address(0x7E57)
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

    function _cur(address who, uint256 i) internal view returns (uint256 cur) {
        (, cur,,,,) = vault.getRigWear(who, i);
    }

    function _globalPower() internal view returns (uint256 p) {
        (,, p,,,,) = vault.getVaultMiningStats();
    }

    // ── A. Repair EXACTLY in the same day-bucket as a wear step ──────────────
    //
    //  The riskiest border: sb == lastSettledBucket == nowBucket. settle consumes
    //  the step, _reschedule must skip it in the unregister (skipUpToBucket) and
    //  read `live` as post-step. A double-count or a lost delta shows up as a
    //  global-power mismatch or a wrong restored level.
    function testRepairInSameBucketAsStep() public {
        _buyBnb(alice, 3); // Hyper 420, steps at 103d, 106d, 109d ...
        vault.donateReward(420 ether); // pending accrues at full power pre-step

        vm.warp(106 days); // land EXACTLY on the 2nd step bucket → live = 379
        assertEq(_cur(alice, 0), 379, "pre-repair live must be the 2-step level");

        uint256 pendingBefore = vault.pendingRewards(alice);

        vm.prank(alice);
        vault.repairRig(0);

        // age 6d of 90d → penalty 3000*6/90 = 200 bps → cap 98% → restored = 420*0.98 = 411.6 → 411
        assertEq(_cur(alice, 0), 411, "restored level wrong at a step-bucket repair");
        assertEq(_globalPower(), 411, "global power must equal the single rig's restored level");
        // pending was checkpointed into accrued, not lost, not doubled
        assertApproxEqAbs(vault.pendingRewards(alice), pendingBefore, 1e6, "pending must survive the repair");

        // and it collapses to exactly 0 when the rig eventually dies
        vm.warp(191 days); // > 90d life
        vault.donateReward(1);
        assertEq(_globalPower(), 0, "orphan power after expiry");
        assertEq(_cur(alice, 0), 0, "rig must read 0 once expired");
    }

    // ── B. Two repairs at different worn points (unregister/re-register twice) ─
    function testTwoRepairsInSequence() public {
        _buyBnb(alice, 3); // Hyper 420

        vm.warp(112 days); // 4 steps → 342
        assertEq(_cur(alice, 0), 342);
        vm.prank(alice);
        vault.repairRig(0); // age 12d → cap 96% → 403
        assertEq(_cur(alice, 0), 403);
        assertEq(_globalPower(), 403);

        vm.warp(130 days); // wear the fresh ladder again (wearStart=112d): steps at 115,118,121,124,127,130
        uint256 worn = _cur(alice, 0);
        assertLt(worn, 403, "rig should have worn after the first repair");
        vm.prank(alice);
        vault.repairRig(0); // age 30d of 90d → cap 90% → 378
        assertEq(_cur(alice, 0), 378, "second repair restored level wrong");
        assertEq(_globalPower(), 378, "global power diverged after 2 repairs");

        vm.warp(191 days);
        vault.donateReward(1);
        assertEq(_globalPower(), 0, "orphan power after 2 repairs + expiry");
    }

    // ── C. claim → repair → claim: no double-count, no underflow ─────────────
    function testClaimRepairClaimNoDoubleCount() public {
        _buyBnb(alice, 3); // Hyper 420
        vault.donateReward(100 ether);

        vm.warp(112 days); // worn to 342
        vault.donateReward(50 ether);

        vm.prank(alice);
        uint256 got1 = vault.claimRewards(); // claims everything so far
        assertApproxEqAbs(got1, 150 ether, 1e9);

        // repair immediately after the claim (same block): pending checkpoint must be 0
        vm.prank(alice);
        vault.repairRig(0);
        (,,,,, uint256 accrued) = vault.getRigWear(alice, 0);
        assertEq(accrued, 0, "no phantom reward should be checkpointed right after a full claim");

        // a second claim in the same block must find nothing (no reward arrived)
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimRewards();

        // fresh reward after repair is claimable exactly once
        vault.donateReward(40 ether);
        vm.prank(alice);
        uint256 got2 = vault.claimRewards();
        assertApproxEqAbs(got2, 40 ether, 1e9, "post-repair reward must be claimable exactly once");

        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed());
    }

    // ── D. Upgrade on the LAST living day (endTime never extended, no orphan) ─
    function testUpgradeOnLastLivingDay() public {
        _buyBnb(alice, 1); // Core 40, 7d → ends 107d, endBucket 107
        (,,,, uint256 lifeEnds0,) = vault.getRigWear(alice, 0);

        vm.warp(106 days); // nowBucket 106 < endBucket 107 → still alive on the final day
        assertTrue(_cur(alice, 0) > 0, "must be alive on day 6");

        vm.prank(alice);
        vault.upgradeRig(0, 3); // → Hyper 420 for the last day only

        (uint256 id, uint256 planId, uint256 power,,,,, bool active) = vault.getMiningContract(alice, 0);
        assertEq(planId, 3);
        assertEq(power, 420, "fresh Hyper power on the last day");
        assertTrue(active);
        assertEq(_globalPower(), 420);
        (,,,, uint256 lifeEnds1,) = vault.getRigWear(alice, 0);
        assertEq(lifeEnds1, lifeEnds0, "upgrade must NOT extend the original Core life");
        assertEq(id, 1);

        // one day later it dies; power must vanish cleanly (the 420 remainder was booked at endBucket)
        vm.warp(107 days);
        vault.donateReward(1);
        assertEq(_globalPower(), 0, "orphan power after last-day upgrade + expiry");
        assertEq(_cur(alice, 0), 0);
    }

    // ── E. Messy multi-actor lifecycle → global power must hit EXACTLY 0 ──────
    //
    //  Buys (BNB + RAM), repairs, upgrades, partial claims across many actors and
    //  timelines. After everything expires and a final settle, totalActivePower
    //  must be 0 and Σ claimed ≤ Σ distributed with no value stranded beyond dust.
    function testMessyLifecycleCollapsesToZeroClean() public {
        _buyBnb(alice, 3); // Hyper 420 (90d), ends 190d
        _buyBnb(bob, 2); // Mega 130 (30d), ends 130d
        vault.donateReward(100 ether);

        vm.warp(109 days);
        _buyRam(alice, 1); // alice growth rig: Core (7d) in RAM, ends 116d
        vault.donateReward(60 ether);

        vm.warp(115 days);
        vm.prank(bob);
        vault.repairRig(0); // bob Mega mid-life repair
        vm.prank(alice);
        vault.upgradeRig(1, 3); // alice's Core growth rig → Hyper power for its last day
        vault.donateReward(80 ether);

        vm.warp(125 days);
        vm.prank(alice);
        vault.claimRewards(); // partial claim mid-flight

        // Warp well past every life (Hyper alice[0] ends 190d) and past nothing-left.
        vm.warp(200 days);
        vault.donateReward(1); // final settle

        assertEq(_globalPower(), 0, "TOTAL ACTIVE POWER MUST COLLAPSE TO EXACTLY ZERO");

        vm.prank(alice);
        try vault.claimRewards() {} catch {}
        vm.prank(bob);
        try vault.claimRewards() {} catch {}

        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed(), "claimed exceeded distributed");
        uint256 stranded = vault.totalRewardDistributed() - vault.totalRewardClaimed();
        assertLe(stranded, 1e9, "value stranded beyond dust");
    }
}
