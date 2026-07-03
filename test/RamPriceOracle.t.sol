// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RamPriceOracle} from "../src/RamPriceOracle.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Fully-controllable mocks
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Mock Flap portal. Returns a settable TokenStateV8Safe (only status/price/pool matter here).
contract MockPortal is IPortalTypes {
    uint8 public s_status;
    uint256 public s_price;
    address public s_pool;
    bool public s_revert;

    function set(uint8 st, uint256 pr, address po) external {
        s_status = st;
        s_price = pr;
        s_pool = po;
    }

    function setRevert(bool v) external {
        s_revert = v;
    }

    function getTokenV8Safe(address) external view returns (TokenStateV8Safe memory st) {
        require(!s_revert, "portal down");
        st.status = s_status;
        st.price = s_price;
        st.pool = s_pool;
        // all other fields default to zero
    }
}

/// @dev Mock PancakeSwap V2 pair. The test injects the price accumulators DIRECTLY and pins blockTimestampLast to
///      the current time so the oracle's counterfactual extrapolation adds zero — giving exact control of the TWAP.
contract MockPair {
    uint112 public r0;
    uint112 public r1;
    uint32 public tsLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    address public token0;
    address public token1;
    bool public s_revert;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function setReserves(uint112 _r0, uint112 _r1) external {
        r0 = _r0;
        r1 = _r1;
    }

    /// @dev Set price0CumulativeLast and pin blockTimestampLast to `ts` (pass block.timestamp to zero the counterfactual).
    function setObs0(uint32 ts, uint256 c0) external {
        tsLast = ts;
        price0CumulativeLast = c0;
    }

    function setRevert(bool v) external {
        s_revert = v;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        require(!s_revert, "pair down");
        return (r0, r1, tsLast);
    }
}

/// @dev Mock V2 factory returning a settable pair.
contract MockFactory {
    address public p;

    function setPair(address _p) external {
        p = _p;
    }

    function getPair(address, address) external view returns (address) {
        return p;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests
// ─────────────────────────────────────────────────────────────────────────────

contract RamPriceOracleTest is Test {
    // RAM < WBNB so ramIsToken0 == true (WBNB reserve is r1, WBNB-per-RAM = price0).
    address constant RAM = address(0x0000000000000000000000000000000000001001);
    address constant WBNB = address(0x0000000000000000000000000000000000002002);

    uint256 constant Q112 = uint256(1) << 112;
    uint256 constant FLOOR = 10 ether; // WBNB reserve floor
    uint16 constant TRUNC = 5000; // ±50%
    uint256 constant P = 2e12; // ~ the real reference token's ~2.09e12 wei per 1e18 RAM

    MockPortal portal;
    MockFactory factory;
    MockPair pair;
    RamPriceOracle oracle;

    uint256 cum; // running raw cumulative fed to the pair

    function setUp() public {
        vm.warp(1_000_000); // a sane non-zero start time
        portal = new MockPortal();
        factory = new MockFactory();
        pair = new MockPair(RAM, WBNB);
        pair.setReserves(uint112(1e27), uint112(100 ether)); // r1 = 100 WBNB ≥ FLOOR
        factory.setPair(address(pair));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _uq(uint256 e18) internal pure returns (uint256) {
        return (e18 * Q112) / 1e18; // inverse of the oracle's _uqToE18
    }

    function _deployCurve(uint256 price) internal {
        portal.set(1, price, address(0)); // Tradable, curve (pool == 0)
        oracle = new RamPriceOracle(address(portal), RAM, WBNB, address(factory), FLOOR, TRUNC);
    }

    function _deployGraduated() internal {
        portal.set(4, 0, address(pair)); // DEX, price 0 post-graduation (verified on-chain)
        oracle = new RamPriceOracle(address(portal), RAM, WBNB, address(factory), FLOOR, TRUNC);
    }

    /// @dev Advance `dt`, inject a raw interval whose average price == priceE18, pin the pair, and record.
    function _step(uint256 dt, uint256 priceE18) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        cum += _uq(priceE18) * dt;
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke();
    }

    /// @dev Seed the first observation at the current time (no interval).
    function _seed() internal {
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke();
    }

    function _buildMaturePool(uint256 price, uint256 intervals) internal {
        _seed();
        for (uint256 i = 0; i < intervals; i++) {
            _step(300, price); // 5-min intervals
        }
    }

    function _assertApprox(uint256 a, uint256 b, uint256 tolBps, string memory tag) internal pure {
        uint256 hi = (b * (10_000 + tolBps)) / 10_000;
        uint256 lo = (b * (10_000 - tolBps)) / 10_000;
        assertLe(a, hi, tag);
        assertGe(a, lo, tag);
    }

    // ── constructor / config ─────────────────────────────────────────────────

    function testConstructorRejectsBadConfig() public {
        vm.expectRevert();
        new RamPriceOracle(address(0), RAM, WBNB, address(factory), FLOOR, TRUNC);
        vm.expectRevert(); // token == wbnb
        new RamPriceOracle(address(portal), RAM, RAM, address(factory), FLOOR, TRUNC);
        vm.expectRevert(); // zero floor
        new RamPriceOracle(address(portal), RAM, WBNB, address(factory), 0, TRUNC);
        vm.expectRevert(); // trunc > 5000
        new RamPriceOracle(address(portal), RAM, WBNB, address(factory), FLOOR, 5001);
        vm.expectRevert(); // trunc == 0
        new RamPriceOracle(address(portal), RAM, WBNB, address(factory), FLOOR, 0);
    }

    function testForeignTokenReturnsUntrusted() public {
        _deployCurve(P);
        (uint256 pr, bool tr) = oracle.getPrice(address(0xDEAD));
        assertEq(pr, 0);
        assertFalse(tr);
        (pr, tr) = oracle.pokeAndGetPrice(address(0xDEAD));
        assertEq(pr, 0);
        assertFalse(tr);
    }

    // ── curve phase ────────────────────────────────────────────────────────────

    function testCurveBasic() public {
        _deployCurve(P); // constructor seeds the trailing anchor at P
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr, "curve trusted");
        assertEq(pr, P, "curve price == min(P, trail=P)");
    }

    /// min(marginal now, trailing ≥5min old) defeats a same-tx pump of the curve.
    function testCurveMinTrailingDefeatsPump() public {
        _deployCurve(P); // trail seeded at P
        // Attacker pumps the curve marginal price to 5x in the same block (no time passes -> trail stays P).
        portal.set(1, 5 * P, address(0));
        (uint256 pr, bool tr) = oracle.pokeAndGetPrice(RAM);
        assertTrue(tr);
        assertEq(pr, P, "pump defeated: min(5P, trail P) == P");

        // After ≥5min the trailing anchor legitimately advances toward the new level.
        vm.warp(block.timestamp + 301);
        vm.roll(block.number + 1);
        oracle.poke();
        (pr, tr) = oracle.getPrice(RAM);
        assertEq(pr, 5 * P, "trailing caught up: min(5P,5P)");
    }

    function testCurveDownwardUsesLowerMarginal() public {
        _deployCurve(P); // trail P
        portal.set(1, P / 2, address(0)); // marginal drops
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr);
        assertEq(pr, P / 2, "min(P/2, P) == P/2 (fast crash capture)");
    }

    // ── grace (freeze) + transition ─────────────────────────────────────────────

    function testTransitionFreezesCurveAndServesGrace() public {
        _deployCurve(P);
        // a couple of curve pokes keep lastCurvePrice fresh
        vm.warp(block.timestamp + 301);
        vm.roll(block.number + 1);
        portal.set(1, P, address(0));
        oracle.poke();

        // graduation: pool != 0, curve price now 0 (as verified on mainnet)
        portal.set(4, 0, address(pair));
        (uint256 pr, bool tr) = oracle.pokeAndGetPrice(RAM);
        assertTrue(tr, "grace trusted (freeze exists)");
        assertEq(pr, P, "grace serves the frozen final curve price");
        assertEq(oracle.graduationFrozen(), P, "freeze cached");
        assertEq(oracle.pair(), address(pair), "pair resolved at transition");
        assertTrue(oracle.ramIsToken0(), "RAM is token0 (RAM < WBNB)");
    }

    function testGraceWithoutFreezeDegrades() public {
        // Deployed AFTER graduation -> no curve was ever seen -> no freeze -> grace degrades (safe over-charge).
        _deployGraduated();
        (uint256 pr, bool tr) = oracle.pokeAndGetPrice(RAM);
        assertEq(pr, 0);
        assertFalse(tr, "no freeze, immature pool -> degraded");
    }

    // ── pool TWAP ────────────────────────────────────────────────────────────────

    function testTwapBasicFlat() public {
        _deployGraduated();
        _buildMaturePool(P, 7); // 7 intervals * 5min = 35min of flat P
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr, "mature + liquid -> trusted");
        _assertApprox(pr, P, 100, "flat TWAP == P"); // 1% tol for integer rounding
    }

    function testImmatureBelowWindowDegrades() public {
        _deployGraduated();
        _buildMaturePool(P, 3); // only 3 intervals = 15min < 25min window
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertEq(pr, 0);
        assertFalse(tr, "immature TWAP -> degraded");
    }

    /// A +1000x one-interval spike is truncated (and min() picks the lagging TWAP30) -> tiny move.
    function testTruncationSpikeUp() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        _step(300, 1000 * P); // one interval spikes 1000x
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr);
        // Without defense this would be ~150x P (TWAP30) or 1000x (TWAP5). With ±50% trunc + min ⇒ ≤ ~+9%.
        assertLe(pr, (P * 112) / 100, "1000x spike neutered to <=+12%");
        assertGe(pr, P, "still moved up a touch");
    }

    /// A -1000x one-interval crash: TWAP5 hits the -50% truncation floor and min() picks it -> exactly ~0.5P.
    function testTruncationCrashAndMinPicksTwap5() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        _step(300, P / 1000); // crash
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr);
        _assertApprox(pr, P / 2, 300, "crash floored at -50% via TWAP5 min"); // 3% tol
    }

    function testLiquidityFloorUntrusted() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        (, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr, "trusted while liquid");
        // WBNB reserve drops under the floor -> degrade.
        pair.setReserves(uint112(1e27), uint112(FLOOR - 1));
        (uint256 pr, bool tr2) = oracle.getPrice(RAM);
        assertEq(pr, 0);
        assertFalse(tr2, "thin pool -> degraded");
    }

    // ── gap / re-seed (blocker #1) ───────────────────────────────────────────────

    function testGapReseedRequiresSecondPoke() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        (, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr, "mature before gap");

        // Gap > MAX_AGE (10min) with no poke -> the live interval is stale -> read-time degrade.
        vm.warp(block.timestamp + 20 minutes);
        vm.roll(block.number + 1);
        (uint256 pr, bool trStale) = oracle.getPrice(RAM);
        assertEq(pr, 0);
        assertFalse(trStale, "stale ring (6h-TWAP guard) degrades at read");

        // First poke after the gap only RE-SEEDs (no interval) -> still degraded.
        cum += _uq(P) * 20 minutes;
        pair.setObs0(uint32(block.timestamp), cum);
        (uint256 pr2, bool tr2) = oracle.pokeAndGetPrice(RAM);
        assertEq(pr2, 0);
        assertFalse(tr2, "first post-gap poke re-seeds only -> degraded");
        assertEq(oracle.observationCount(), 1, "history discarded on re-seed");

        // A 2nd poke ≥5min later starts a fresh interval, but the TWAP must re-mature (≥25min) before trust.
        _step(300, P);
        (, bool tr3) = oracle.getPrice(RAM);
        assertFalse(tr3, "one fresh interval is not yet mature");

        for (uint256 i = 0; i < 6; i++) {
            _step(300, P);
        }
        (uint256 pr4, bool tr4) = oracle.getPrice(RAM);
        assertTrue(tr4, "re-matured after the gap");
        _assertApprox(pr4, P, 100, "re-matured price == P");
    }

    // ── dedupe / div-by-zero ─────────────────────────────────────────────────────

    function testBlockDedupe() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        uint8 c0 = oracle.observationCount();
        // Two pokes in the SAME block must not add two observations.
        cum += _uq(P) * 300;
        vm.warp(block.timestamp + 300);
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke();
        uint8 c1 = oracle.observationCount();
        oracle.poke(); // same block -> deduped
        uint8 c2 = oracle.observationCount();
        assertEq(c2, c1, "same-block second poke deduped");
        assertLe(c1 - c0, 1, "at most one obs per block");
    }

    function testSameTimestampNoDivByZero() public {
        _deployGraduated();
        _seed();
        // poke again at the exact same timestamp (dt == 0) — must not revert.
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke();
        (uint256 pr, bool tr) = oracle.pokeAndGetPrice(RAM);
        assertEq(pr, 0); // still just a seed, immature
        assertFalse(tr);
    }

    // ── portal / pair outages degrade, never revert ──────────────────────────────

    function testPortalOutageInCurveDegrades() public {
        _deployCurve(P);
        portal.setRevert(true);
        (uint256 pr, bool tr) = oracle.pokeAndGetPrice(RAM); // must not revert
        assertEq(pr, 0);
        assertFalse(tr);
    }

    function testPortalOutageAfterGraduationFallsBackToPool() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        // Portal proxy goes down; we already witnessed graduation (freeze latched via pair) -> pool still prices.
        portal.setRevert(true);
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        assertTrue(tr, "portal down but mature pool still trusted");
        _assertApprox(pr, P, 100, "pool price served with portal down");
    }

    function testPairOutageDegrades() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        pair.setRevert(true);
        (uint256 pr, bool tr) = oracle.getPrice(RAM); // must not revert
        assertEq(pr, 0);
        assertFalse(tr);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────────

    /// Invariants under random (price, dt) sequences: pokeAndGetPrice never reverts; trusted ⇒ price > 0;
    /// and a >10min gap ALWAYS degrades afterward.
    function testFuzzSequenceInvariants(uint256[8] memory prices, uint16[8] memory dts) public {
        _deployGraduated();
        _seed();
        for (uint256 i = 0; i < 8; i++) {
            uint256 price = bound(prices[i], P / 100, P * 100);
            uint256 dt = bound(uint256(dts[i]), 300, 600); // valid spacing 5–10 min
            vm.warp(block.timestamp + dt);
            vm.roll(block.number + 1);
            cum += _uq(price) * dt;
            pair.setObs0(uint32(block.timestamp), cum);
            (uint256 pr, bool tr) = oracle.pokeAndGetPrice(RAM); // must never revert
            if (tr) assertGt(pr, 0, "trusted price must be > 0");
        }
        // A >10min gap must always degrade the next read (no stale TWAP served).
        vm.warp(block.timestamp + 11 minutes);
        vm.roll(block.number + 1);
        (uint256 prg, bool trg) = oracle.getPrice(RAM);
        assertEq(prg, 0, "gap price zero");
        assertFalse(trg, "gap always degrades");
    }

    function testFuzzUqRoundTrip(uint256 e18) public pure {
        e18 = bound(e18, 1, 1e24);
        uint256 uq = (e18 * Q112) / 1e18;
        uint256 back = (uq * 1e18) / Q112;
        // round-trip within integer floor error
        assertApproxEqAbs(back, e18, (e18 / 1e6) + 2, "uq round-trip");
    }
}
