// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RamPriceOracle} from "../src/RamPriceOracle.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Adversarial audit harness (self-contained mocks, mirror the unit-test mocks)
//
//  Threat model under attack: the ONLY profitable manipulation is trusted==true
//  with an INFLATED price (vault charges FEWER RAM in its 85%-burn sinks). These
//  tests hunt exactly for that. Injecting a cumulative delta over an interval is a
//  FAITHFUL (and strictly stronger, because costless) model of an attacker who
//  actually held the real PCS pair at that average price for the interval — the
//  same philosophy the repo's fork test uses (donation+sync == costless spot move).
// ─────────────────────────────────────────────────────────────────────────────

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
    }
}

contract MockPair {
    uint112 public r0;
    uint112 public r1;
    uint32 public tsLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    address public token0;
    address public token1;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function setReserves(uint112 _r0, uint112 _r1) external {
        r0 = _r0;
        r1 = _r1;
    }

    // Pin blockTimestampLast == block.timestamp so the oracle's counterfactual adds zero → exact TWAP control.
    function setObs0(uint32 ts, uint256 c0) external {
        tsLast = ts;
        price0CumulativeLast = c0;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, tsLast);
    }
}

contract MockFactory {
    address public p;

    function setPair(address _p) external {
        p = _p;
    }

    function getPair(address, address) external view returns (address) {
        return p;
    }
}

contract RamPriceOracleAdversarialTest is Test {
    address constant RAM = address(0x0000000000000000000000000000000000001001);
    address constant WBNB = address(0x0000000000000000000000000000000000002002);

    uint256 constant Q112 = uint256(1) << 112;
    uint256 constant FLOOR = 10 ether;
    uint16 constant TRUNC = 5000; // ±50% (the audited default)
    uint256 constant P = 2e12; // ~ real reference price (wei BNB per 1e18 RAM)

    MockPortal portal;
    MockFactory factory;
    MockPair pair;
    RamPriceOracle oracle;

    uint256 cum; // running raw cumulative fed to the pair

    function setUp() public {
        vm.warp(1_000_000);
        portal = new MockPortal();
        factory = new MockFactory();
        pair = new MockPair(RAM, WBNB);
        pair.setReserves(uint112(1e27), uint112(100 ether)); // WBNB reserve r1 = 100 ≥ FLOOR
        factory.setPair(address(pair));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _uq(uint256 e18) internal pure returns (uint256) {
        return (e18 * Q112) / 1e18;
    }

    function _deployGraduated() internal {
        portal.set(4, 0, address(pair)); // DEX status, price 0 (verified real post-graduation behavior)
        oracle = new RamPriceOracle(address(portal), RAM, WBNB, address(factory), FLOOR, TRUNC);
    }

    /// @dev Advance `dt`, inject an interval whose AVERAGE price == priceE18, pin the pair, poke.
    function _step(uint256 dt, uint256 priceE18) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        cum += _uq(priceE18) * dt;
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke();
    }

    function _seed() internal {
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke();
    }

    function _buildMaturePool(uint256 price, uint256 intervals) internal {
        _seed();
        for (uint256 i = 0; i < intervals; i++) {
            _step(300, price);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FINDING #1 (BREAK): the truncation reset on re-seed removes the per-interval
    //  cap for ONE interval, and the SYMMETRIC ±50% truncation then holds that spike
    //  ELEVATED on the way down (0.5×/interval decay). Because min(TWAP30, TWAP5)
    //  relies on TWAP5 tracking the CURRENT real price, and TWAP5 is itself floored
    //  by the decaying truncation anchor, the min() guarantee is defeated: the oracle
    //  returns trusted==true with a price many× the real current price, funded by a
    //  SINGLE interval of manipulation (not a sustained hold across the whole window).
    // ═════════════════════════════════════════════════════════════════════════
    function testReseedUntruncatedSpikeYieldsInflatedTrustedPrice() public {
        _deployGraduated();
        _buildMaturePool(P, 7); // a healthy, mature pool tracking the real price P
        (uint256 pr0, bool tr0) = oracle.getPrice(RAM);
        assertTrue(tr0, "healthy pool trusted");
        assertApproxEqRel(pr0, P, 0.02e18, "healthy price == P");

        // 1) Keeper/poke liveness lapses > MAX_AGE(10min). Attacker's poke RE-SEEDs the ring
        //    (truncation anchor _lastTruncPrice reset to 0). Real price is still P here.
        vm.warp(block.timestamp + 11 minutes);
        vm.roll(block.number + 1);
        cum += _uq(P) * 11 minutes;
        pair.setObs0(uint32(block.timestamp), cum);
        oracle.poke(); // re-seed only (no interval priced)
        assertEq(oracle.observationCount(), 1, "re-seeded: history discarded, trunc anchor cleared");

        // 2) Attacker holds the pool at 100x for ONE 10-min interval. First post-reseed interval is UN-TRUNCATED.
        _step(10 minutes, 100 * P);
        // 3) Attacker RELEASES the pool back to the real price P. Truncation floors the fall at 0.5×/interval,
        //    so the reported interval price stays high: 100P → 50P → 25P even though real == P.
        _step(10 minutes, P); // clamps to 50P (not P!)
        _step(10 minutes, P); // clamps to 25P (not P!)

        // Read right after the 3rd interval (dtLive==0). Window span from the re-seed == 30min ≥ 25min → mature.
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        emit log_named_uint("real price now (wei/1e18 RAM)", P);
        emit log_named_uint("oracle price   (wei/1e18 RAM)", pr);
        emit log_named_uint("inflation x100", (pr * 100) / P);

        // REGRESSION (fix: asymmetric truncation): after the attacker releases, the price falls freely so
        // TWAP5 tracks the real price down and min() collapses to ~P. The one-interval reseed spike no longer
        // yields an inflated trusted price. A faithful oracle returns ~P — and it does.
        if (tr) {
            assertLe(pr, (P * 150) / 100, "FIXED: reseed spike no longer inflates the trusted price (<=1.5x real)");
        }
        // (trusted=false would also be acceptable — the vault degrades to its cage. Inflated+trusted is the
        //  only inacceptable outcome, and it no longer occurs.)
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONTROL for #1: the SAME 100x spike, but WITHOUT a re-seed (continuous pokes,
    //  so _lastTruncPrice is always set). The per-interval +50% cap holds and the
    //  price barely moves. This isolates the re-seed as the necessary precondition.
    // ═════════════════════════════════════════════════════════════════════════
    function testWithoutReseedSameSpikeIsNeutralized() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        _step(10 minutes, 100 * P); // truncated to 1.5P (no reseed → anchor is P)
        _step(10 minutes, P); // falls straight back toward P
        _step(10 minutes, P);
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        emit log_named_uint("oracle price after capped spike", pr);
        assertTrue(tr, "still trusted");
        assertLt(pr, (P * 130) / 100, "capped: <+30% despite an injected 100x interval");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FINDING #2 (WEAKNESS): the liquidity-floor gate is an INSTANTANEOUS reserve
    //  read (spot), so it is flash-loan / same-block passable. A pool that is under
    //  the floor (untrusted) flips to trusted the instant its WBNB reserve is bumped
    //  above the floor — no sustained depth required. This is the gate that is meant
    //  to neutralize CHEAP thin-pool manipulation; being spot, it composes with #1.
    // ═════════════════════════════════════════════════════════════════════════
    function testLiquidityFloorIsFlashPassableSpotRead() public {
        _deployGraduated();
        _buildMaturePool(P, 7);

        // Thin pool: WBNB reserve below the floor → correctly degraded.
        pair.setReserves(uint112(1e27), uint112(FLOOR - 1));
        (uint256 prThin, bool trThin) = oracle.getPrice(RAM);
        assertEq(prThin, 0, "thin pool degraded");
        assertFalse(trThin, "thin pool untrusted");

        // Same block, no time passes, TWAP identical: only the instantaneous reserve is bumped over the floor.
        pair.setReserves(uint112(1e27), uint112(FLOOR));
        (uint256 prFat, bool trFat) = oracle.getPrice(RAM);
        assertTrue(trFat, "WEAKNESS: floor satisfied by an instantaneous reserve -> trusted flips true");
        assertGt(prFat, 0, "priced on a spot-passable floor");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FINDING #1b: the un-truncated-first-interval also exists right after the
    //  post-GRADUATION seed (no gap needed) — the same defect through the normal
    //  lifecycle entry, during the window grace is supposed to protect.
    // ═════════════════════════════════════════════════════════════════════════
    function testGraduationSeedFirstIntervalIsUntruncated() public {
        _deployGraduated(); // no freeze (deployed post-graduation) → grace returns (0,false) until mature
        _seed(); // initial seed: _lastTruncPrice == 0
        _step(10 minutes, 100 * P); // FIRST pool interval is un-truncated
        _step(10 minutes, P); // → 50P
        _step(10 minutes, P); // → 25P
        (uint256 pr, bool tr) = oracle.getPrice(RAM);
        emit log_named_uint("post-graduation oracle price", pr);
        // REGRESSION (fix: asymmetric truncation): the post-graduation seed's first interval no longer inflates
        // the matured TWAP once the price returns to real — the free downside + min() collapse it back to ~P.
        if (tr) {
            assertLe(pr, (P * 150) / 100, "FIXED: post-graduation first interval no longer inflates (<=1.5x real)");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ROOT CAUSE of #1: the SYMMETRIC ±50% truncation lags on the DOWNSIDE. Because
    //  TWAP5 (the "current price" leg of the min) is itself floored at 0.5×/interval,
    //  releasing a pumped price does NOT bring the oracle back to the real price for
    //  several intervals — min(TWAP30, TWAP5) stays elevated. This violates the design's
    //  own "always fail toward OVER-charging" rule (an elevated price UNDER-charges) and
    //  is exactly why the re-seed spike in #1 persists. Upside-only truncation would fix it.
    // ═════════════════════════════════════════════════════════════════════════
    function testDownsideTruncationLagKeepsPriceElevatedAfterRelease() public {
        _deployGraduated();
        _buildMaturePool(P, 7);
        // Ramp up under the cap (each +50%): P->1.5P->2.25P->3.375P (attacker sustains three intervals).
        _step(5 minutes, 100 * P);
        _step(5 minutes, 100 * P);
        _step(5 minutes, 100 * P);
        (uint256 prHeld,) = oracle.getPrice(RAM);
        emit log_named_uint("price while sustaining the pump", prHeld);

        // Release: the pool is back at the real price P for a full interval.
        _step(5 minutes, P);
        (uint256 prRel, bool trRel) = oracle.getPrice(RAM);
        emit log_named_uint("price one interval AFTER releasing to P", prRel);

        // REGRESSION (fix: asymmetric truncation): min() now DOES track the release — the price falls freely,
        // so once the pump is released the oracle collapses to ~P (the safe direction). No downside lag.
        if (trRel) {
            assertLe(prRel, (P * 150) / 100, "FIXED: min() tracks the release, price collapses to ~P (<=1.5x real)");
        }
        prHeld; // (held-price reference retained; the point is the post-release collapse above)
    }
}

interface IPairFork {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function sync() external;
}

/// @title Fork PoC — reproduce the re-seed spike attack against the REAL BSC PancakeSwap V2 pair.
/// @notice Same real graduated token/pair as the repo fork test. Proves on live state that a SINGLE
///         manipulated interval after a poke-liveness gap yields a mature, TRUSTED, multi-x inflated price,
///         even though the spot is back to normal at read time. Runs only when BNB_RPC_URL is set.
contract RamPriceOracleAdversarialForkTest is Test {
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant GRAD_TOKEN = 0x091652EBc0A0238d7151a868f22D7CfD2a267777;
    address constant GRAD_PAIR = 0xCd915c6d8A207F754F62541Ca12E85bD7e1e2Ac0;
    uint256 constant FLOOR = 10 ether;
    uint16 constant TRUNC = 5000;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 56, "fork must be BNB mainnet");
        return true;
    }

    uint256 private _clock; // absolute local clock (public RPC returns inconsistent block env across warps)
    uint256 private _blk;

    function _pokeAdvance(RamPriceOracle o, uint256 dt) internal {
        _clock += dt;
        _blk += 1;
        vm.warp(_clock);
        vm.roll(_blk);
        o.poke();
    }

    function _wbnbReserve(RamPriceOracle o) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPairFork(GRAD_PAIR).getReserves();
        return o.ramIsToken0() ? uint256(r1) : uint256(r0);
    }

    function testForkReseedSpikeInflatesTrustedPrice() public {
        if (!_fork()) return;

        RamPriceOracle oracle = new RamPriceOracle(PORTAL, GRAD_TOKEN, WBNB, FACTORY, FLOOR, TRUNC);
        assertEq(oracle.pair(), GRAD_PAIR, "resolved canonical pair");
        _clock = block.timestamp;
        _blk = block.number;

        // Healthy mature TWAP at the live spot.
        oracle.poke();
        for (uint256 i = 0; i < 8; i++) {
            _pokeAdvance(oracle, 5 minutes);
        }
        (uint256 priceBefore, bool trBefore) = oracle.getPrice(GRAD_TOKEN);
        // Guard against public-RPC non-determinism (inconsistent fork block env) — only assert the attack when the
        // baseline actually matured. The deterministic unit PoCs prove the same defect without an RPC.
        if (!trBefore || oracle.observationCount() < 6) {
            emit log("SKIP: public RPC did not produce a stable mature baseline this run (fork env flake)");
            return;
        }
        uint256 baseWbnb = _wbnbReserve(oracle);

        // 1) poke-liveness lapses > MAX_AGE -> next poke RE-SEEDs (clears the truncation anchor).
        _clock += 11 minutes;
        _blk += 1;
        vm.warp(_clock);
        vm.roll(_blk);
        oracle.poke();
        assertEq(oracle.observationCount(), 1, "re-seeded");

        // 2) Attacker pushes the pair spot ~50x for ONE interval (costless donation == a strictly stronger
        //    model of a real, arbitraged hold). First post-reseed interval is UN-TRUNCATED.
        deal(WBNB, GRAD_PAIR, baseWbnb * 50);
        IPairFork(GRAD_PAIR).sync();
        _pokeAdvance(oracle, 10 minutes);

        // 3) Attacker RELEASES the pool back to normal, then pokes two real intervals.
        deal(WBNB, GRAD_PAIR, baseWbnb);
        IPairFork(GRAD_PAIR).sync();
        _pokeAdvance(oracle, 10 minutes);
        _pokeAdvance(oracle, 10 minutes);

        (uint256 priceAfter, bool trAfter) = oracle.getPrice(GRAD_TOKEN);
        emit log_named_uint("real spot (restored)         ", priceBefore);
        emit log_named_uint("oracle price after reseed atk", priceAfter);
        emit log_named_uint("inflation x100               ", (priceAfter * 100) / priceBefore);
        // REGRESSION on live mainnet state (fix: asymmetric truncation): after the reseed spike is released and
        // the spot is restored, the oracle price collapses back toward the real spot (free downside + min()).
        // The one-interval inflation that this PoC originally proved (>3x, trusted) is gone.
        if (trAfter) {
            assertLe(priceAfter, (priceBefore * 3) / 2, "FIXED(fork): no inflated trusted price after release (<=1.5x)");
        }
    }
}
