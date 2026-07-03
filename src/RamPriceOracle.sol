// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPortalLens, IPortalTypes} from "./flap/IPortal.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Minimal external surfaces (PancakeSwap V2 is a Uniswap V2 fork — identical ABI)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice The subset of a Uniswap/Pancake V2 pair this oracle reads. All views.
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice The single factory method used to resolve the canonical pair (view).
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title RamPriceOracle — hybrid curve/TWAP price source for the RAM tax token, denominated in BNB.
/// @author RAM (Phase-2 economy)
/// @notice Deployable as an immutable, admin-less, per-token instance. Implements `IRamPriceOracle`
///         (`pokeAndGetPrice`/`getPrice`) consumed by `RamMiningVault`: returns the price of `1e18` RAM in
///         wei of BNB plus a `trusted` flag. `trusted == false` means a reliability gate failed and the vault
///         degrades to its guardian cage (safe OVER-charging direction for a burn sink). USD conversion is done
///         by the vault via its hardened Chainlink BNB/USD feed — this contract is BNB-only by design.
///
/// @dev DESIGN (see RAM-pricing-ram-usd-oracle, red-team fixes 1–6 incorporated):
///      The golden rule — a market price is used ONLY when fresh + liquid + mature; otherwise DEGRADE.
///      Always fail toward over-charging. Phases (auto-detected from the Flap portal + the canonical PCS V2 pair):
///        1. CURVE (portal pool == 0, status Tradable): price = min(portal marginal price NOW, a trailing
///           curve sample ≥5min old). The min defeats a same-tx buy-pump-then-sink loop.
///        2. GRACE (pool != 0 but the pool TWAP is immature or reserves < floor): return the FROZEN final curve
///           price (cached at the curve→pool transition). The freshly-born pool's spot is ignored (cheaply
///           pumpable). trusted only if a freeze exists.
///        3. POOL MATURE (TWAP mature + reserves ≥ floor): min(TWAP30 truncated, TWAP5) of the PCS V2 pair,
///           computed from the price{0,1}CumulativeLast accumulators via the canonical UQ112x112 math.
///      Manipulation resistance: an 8-slot observation ring; ≥5min between observations; per-block dedupe;
///      div-by-zero guards; ±`maxTruncBps` truncation of each interval vs the previous (kills a 1-block spike);
///      a ~10min interval-age cap that RE-SEEDs after a gap (defeats the "6h-TWAP-disguised" attack — the first
///      poke after a gap only re-seeds; a 2nd poke ≥5min later is required to price); and a WBNB reserve floor.
///      Every external call (portal, factory, pair) is wrapped so the contract degrades to (0,false) instead of
///      reverting — the vault also try/catches, giving two layers of safety. Never on the claim path.
contract RamPriceOracle {
    // ── constants ────────────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint8 private constant CARD = 8; // observation ring cardinality (~40+ min of history)
    uint32 private constant MIN_PERIOD = 5 minutes; // min spacing between recorded observations
    uint32 private constant MAX_AGE = 10 minutes; // max age of the live interval before the ring is stale
    uint32 private constant MIN_WINDOW = 25 minutes; // min TWAP span to be considered mature
    uint32 private constant WINDOW = 30 minutes; // TWAP30 look-back window
    uint8 private constant STATUS_TRADABLE = 1; // IPortalTypes.TokenStatus.Tradable
    uint256 private constant MASK224 = (uint256(1) << 224) - 1;
    uint256 private constant Q112 = uint256(1) << 112;
    // Reject UQ112x112 prices ≥ 2^160 (economically impossible for an 18-dec token — would imply RAM worth more
    // than the entire BNB supply). Doubles as an overflow guard: p < 2^160 ⇒ p * 1e18 < 2^220 < 2^256.
    uint256 private constant MAX_UQ = uint256(1) << 160;

    // ── immutable configuration ──────────────────────────────────────────────
    IPortalLens public immutable portal; // Flap portal proxy (curve price + graduation signal)
    address public immutable token; // the RAM tax token this oracle prices
    address public immutable wbnb; // wrapped BNB (the quote asset / pair counter-token)
    IUniswapV2Factory public immutable factory; // PancakeSwap V2 factory (resolves the canonical pair)
    uint256 public immutable minReservesWbnb; // liquidity floor: WBNB reserve below this ⇒ untrusted
    uint16 public immutable maxTruncBps; // per-interval truncation cap in bps (e.g. 5000 = ±50%)

    // ── pair binding (resolved once, at deploy if already graduated, else at the transition) ─────────────
    address public pair; // canonical PCS V2 pair (0 until graduation resolved)
    bool public ramIsToken0; // whether RAM is token0 of the pair (WBNB-per-RAM = price0 vs price1)
    bool public pairResolved; // latch so we resolve the pair exactly once

    // ── curve-phase state ────────────────────────────────────────────────────
    uint256 public lastCurvePrice; // most recent valid curve marginal price (wei per 1e18 RAM)
    uint256 public curveTrailPrice; // trailing curve sample used for the min() anti-same-tx-pump
    uint32 public curveTrailTs; // timestamp of the trailing curve sample
    uint256 public graduationFrozen; // final curve price frozen at the curve→pool transition (0 = unset)

    // ── observation ring (the pool TWAP) ─────────────────────────────────────
    struct Observation {
        uint32 timestamp;
        uint224 truncCumulative; // integral of the TRUNCATED price, mod 2^224
    }

    Observation[CARD] private _obs;
    uint8 private _obsHead; // index of the most recent observation
    uint8 private _obsCount; // number of valid observations (0..CARD)
    uint224 private _lastRawCumulative; // raw pair cumulative at the head observation, mod 2^224
    uint224 private _lastTruncPrice; // last truncated interval price (UQ112x112) — the truncation anchor
    uint256 private _lastRecordBlock; // per-block dedupe of recorded observations

    // ── events ───────────────────────────────────────────────────────────────
    event ObservationRecorded(uint32 timestamp, uint224 truncCumulative, uint8 count);
    event GraduationFrozen(uint256 frozenPrice);
    event PairResolved(address pair, bool ramIsToken0);

    error ZeroAddress();
    error BadConfig();

    /// @param _portal Flap portal proxy (must expose getTokenV8Safe)
    /// @param _token the RAM tax token to price
    /// @param _wbnb wrapped BNB
    /// @param _factory PancakeSwap V2 factory
    /// @param _minReservesWbnb WBNB reserve floor (wei); below it the pool read is untrusted. Set to the WBNB
    ///        equivalent of the intended USD floor (~$10–20k) at deploy — the USD peg of this floor drifts with
    ///        BNB and is a deliberate, documented approximation (no Chainlink in this contract by design).
    /// @param _maxTruncBps per-interval truncation cap (1..5000 bps). 5000 = ±50% (the audited default).
    constructor(
        address _portal,
        address _token,
        address _wbnb,
        address _factory,
        uint256 _minReservesWbnb,
        uint16 _maxTruncBps
    ) {
        if (_portal == address(0) || _token == address(0) || _wbnb == address(0) || _factory == address(0)) {
            revert ZeroAddress();
        }
        if (_token == _wbnb || _minReservesWbnb == 0 || _maxTruncBps == 0 || _maxTruncBps > 5000) {
            revert BadConfig();
        }
        portal = IPortalLens(_portal);
        token = _token;
        wbnb = _wbnb;
        factory = IUniswapV2Factory(_factory);
        minReservesWbnb = _minReservesWbnb;
        maxTruncBps = _maxTruncBps;

        // Seed state from the current phase so the oracle is useful from block 0.
        (bool ok, uint8 status, uint256 price, address pool) = _readPortal();
        if (ok && pool != address(0)) {
            // Deployed post-graduation: bind the pair now. No freeze is available (we never saw the curve), so
            // GRACE will return (0,false) until the pool TWAP matures — the safe (over-charge) direction.
            _resolvePair();
        } else if (ok && status == STATUS_TRADABLE && price > 0) {
            // Deployed during curve: seed the trailing sample (a valid pre-pump anchor) and the freeze source.
            lastCurvePrice = price;
            curveTrailPrice = price;
            curveTrailTs = uint32(block.timestamp);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  IRamPriceOracle
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Record an observation (subject to the gates) then price. Called by the vault's sink txs.
    /// @dev Never reverts on internal/external failure — degrades to (0,false). `t` must equal the configured
    ///      token (this is a per-token oracle); any other token returns (0,false).
    function pokeAndGetPrice(address t) external returns (uint256 priceBnbPerRamE18, bool trusted) {
        if (t != token) return (0, false);
        _record();
        return _quote();
    }

    /// @notice View price with the current state (no observation recorded).
    function getPrice(address t) external view returns (uint256 priceBnbPerRamE18, bool trusted) {
        if (t != token) return (0, false);
        return _quote();
    }

    /// @notice Permissionless observation recorder (keeper / anyone). Keeps the TWAP warm between sinks.
    function poke() external {
        _record();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Pricing (view)
    // ─────────────────────────────────────────────────────────────────────────

    function _quote() internal view returns (uint256, bool) {
        (bool portalOk, uint8 status, uint256 cPrice, address cPool) = _readPortal();
        bool graduated = _isGraduated(portalOk, cPool);

        if (graduated) {
            // Prefer a mature pool TWAP; else the grace freeze; else degrade.
            if (pair != address(0)) {
                (uint256 pe, bool pt) = _quotePool();
                if (pt) return (pe, true);
            }
            if (graduationFrozen != 0) return (graduationFrozen, true); // GRACE
            return (0, false);
        }

        // CURVE: min(marginal price now, trailing sample). A trailing anchor must exist to be trusted.
        if (portalOk && status == STATUS_TRADABLE && cPool == address(0) && cPrice > 0) {
            uint256 trail = curveTrailPrice;
            if (trail == 0) return (0, false);
            return (cPrice < trail ? cPrice : trail, true);
        }
        return (0, false);
    }

    /// @dev Mature-pool price = min(TWAP30 truncated, TWAP5). Returns (0,false) if the pair read fails, the WBNB
    ///      reserve is under the floor, the ring is stale (live interval older than MAX_AGE), or the TWAP span is
    ///      below MIN_WINDOW (immature).
    function _quotePool() internal view returns (uint256, bool) {
        if (pair == address(0) || _obsCount == 0) return (0, false);

        (uint112 r0, uint112 r1,, bool okR) = _reserves(pair);
        if (!okR) return (0, false);
        uint256 wbnbRes = ramIsToken0 ? uint256(r1) : uint256(r0);
        if (wbnbRes < minReservesWbnb) return (0, false); // liquidity floor gate

        (uint256 cumNow, bool okC) = _currentCumulative(pair, ramIsToken0);
        if (!okC) return (0, false);
        cumNow &= MASK224;

        uint32 headTs = _obs[_obsHead].timestamp;
        uint256 dtLive = block.timestamp - headTs;
        if (dtLive > MAX_AGE) return (0, false); // stale ring — the "6h-TWAP-disguised" guard at read time

        // TWAP5 = the (truncated) live interval price.
        uint256 pLiveTrunc;
        if (dtLive == 0) {
            pLiveTrunc = _lastTruncPrice;
            if (pLiveTrunc == 0) return (0, false); // only a seed exists — no interval yet
        } else {
            uint256 rawDelta;
            unchecked {
                rawDelta = (cumNow - uint256(_lastRawCumulative)) & MASK224;
            }
            uint256 pRaw = rawDelta / dtLive;
            uint256 pt = _lastTruncPrice;
            pLiveTrunc = pt == 0 ? pRaw : _clamp(pRaw, pt);
        }

        // Extend the truncated cumulative to `now`, then anchor TWAP30 at the oldest obs within WINDOW.
        uint256 truncCumNow;
        unchecked {
            truncCumNow = (uint256(_obs[_obsHead].truncCumulative) + pLiveTrunc * dtLive) & MASK224;
        }
        (uint32 anchorTs, uint256 anchorCum, bool haveAnchor) = _anchor(block.timestamp);
        if (!haveAnchor) return (0, false);
        uint256 span = block.timestamp - anchorTs;
        if (span < MIN_WINDOW) return (0, false); // immature TWAP

        uint256 twap30Uq;
        unchecked {
            twap30Uq = ((truncCumNow - anchorCum) & MASK224) / span;
        }

        uint256 e30 = _uqToE18(twap30Uq);
        uint256 e5 = _uqToE18(pLiveTrunc);
        if (e30 == 0 || e5 == 0) return (0, false); // invalid / absurd (over MAX_UQ) ⇒ degrade
        return (e30 < e5 ? e30 : e5, true); // min() anti-inflation bias
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Observation recording (state-changing)
    // ─────────────────────────────────────────────────────────────────────────

    function _record() internal {
        (bool portalOk, uint8 status, uint256 cPrice, address cPool) = _readPortal();
        bool graduated = _isGraduated(portalOk, cPool);

        if (!graduated) {
            // CURVE bookkeeping: track the marginal price (freeze source) + maintain the ≥5min trailing anchor.
            if (portalOk && status == STATUS_TRADABLE && cPool == address(0) && cPrice > 0) {
                lastCurvePrice = cPrice;
                if (curveTrailTs == 0 || block.timestamp - curveTrailTs >= MIN_PERIOD) {
                    curveTrailPrice = cPrice;
                    curveTrailTs = uint32(block.timestamp);
                }
            }
            return; // no pool observations exist in curve phase
        }

        // Curve→pool transition: freeze the last known curve price exactly once (grace uses it).
        if (graduationFrozen == 0 && lastCurvePrice > 0) {
            graduationFrozen = lastCurvePrice;
            emit GraduationFrozen(lastCurvePrice);
        }
        if (!pairResolved) _resolvePair();
        if (pair == address(0)) return; // graduated to a non-V2 venue (not expected for a tax token) → grace

        if (block.number == _lastRecordBlock) return; // per-block dedupe

        // Liquidity floor at RECORD time too (not only at read): a 1-block flash-donation that inflates reserves
        // must not be able to write a manipulated interval into the ring. A thin pool simply records no
        // observation until real depth returns (adversarial review fix #3, anti-TOCTOU).
        (uint112 rr0, uint112 rr1,, bool okRR) = _reserves(pair);
        if (!okRR) return;
        uint256 wbnbRecRes = ramIsToken0 ? uint256(rr1) : uint256(rr0);
        if (wbnbRecRes < minReservesWbnb) return;

        (uint256 cumNow, bool okCum) = _currentCumulative(pair, ramIsToken0);
        if (!okCum) return;
        cumNow &= MASK224;

        if (_obsCount == 0) {
            _seed(uint32(block.timestamp), uint224(cumNow));
            return;
        }

        uint256 dt = block.timestamp - _obs[_obsHead].timestamp;
        if (dt == 0) return; // div-by-zero guard / same-timestamp dedupe
        if (dt < MIN_PERIOD) return; // spacing gate — history cannot be flushed by spamming

        if (dt > MAX_AGE) {
            // Stale gap: discard history and RE-SEED. This poke does NOT price; a 2nd poke ≥5min later is needed.
            _resetTo(uint32(block.timestamp), uint224(cumNow));
            return;
        }

        // Raw interval price → truncate vs the previous truncated price → extend the truncated cumulative.
        uint256 rawDelta;
        unchecked {
            rawDelta = (cumNow - uint256(_lastRawCumulative)) & MASK224;
        }
        uint256 pRaw = rawDelta / dt;
        uint256 pt = _lastTruncPrice;
        uint256 pTrunc = pt == 0 ? pRaw : _clamp(pRaw, pt);

        uint256 truncCumNow;
        unchecked {
            truncCumNow = (uint256(_obs[_obsHead].truncCumulative) + pTrunc * dt) & MASK224;
        }
        _push(uint32(block.timestamp), uint224(truncCumNow));
        _lastRawCumulative = uint224(cumNow);
        _lastTruncPrice = uint224(pTrunc);
        _lastRecordBlock = block.number;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Ring buffer helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _seed(uint32 ts, uint224 rawCum) private {
        _obs[0] = Observation(ts, rawCum); // truncCumulative baseline = raw baseline (offset cancels in deltas)
        _obsHead = 0;
        _obsCount = 1;
        _lastRawCumulative = rawCum;
        _lastTruncPrice = 0;
        _lastRecordBlock = block.number;
        emit ObservationRecorded(ts, rawCum, 1);
    }

    function _resetTo(uint32 ts, uint224 rawCum) private {
        _obs[0] = Observation(ts, rawCum);
        _obsHead = 0;
        _obsCount = 1;
        _lastRawCumulative = rawCum;
        _lastTruncPrice = 0;
        _lastRecordBlock = block.number;
        emit ObservationRecorded(ts, rawCum, 1);
    }

    function _push(uint32 ts, uint224 truncCum) private {
        uint8 h = (_obsHead + 1) % CARD;
        _obs[h] = Observation(ts, truncCum);
        _obsHead = h;
        if (_obsCount < CARD) _obsCount++;
        emit ObservationRecorded(ts, truncCum, _obsCount);
    }

    function _oldestIndex() private view returns (uint8) {
        return _obsCount < CARD ? 0 : (_obsHead + 1) % CARD;
    }

    /// @dev Oldest observation whose timestamp is within [now-WINDOW, now]. Because a >MAX_AGE gap re-seeds the
    ///      ring, every stored consecutive interval is ≤MAX_AGE, so a valid anchor implies a gap-free window.
    function _anchor(uint256 nowTs) private view returns (uint32, uint256, bool) {
        uint256 lowerBound = nowTs > WINDOW ? nowTs - WINDOW : 0;
        uint8 oldest = _oldestIndex();
        for (uint256 k = 0; k < _obsCount; k++) {
            Observation memory o = _obs[(oldest + k) % CARD];
            if (o.timestamp >= lowerBound) {
                return (o.timestamp, uint256(o.truncCumulative), true);
            }
        }
        return (0, 0, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  UQ112x112 math (adapted from the canonical Uniswap V2 FixedPoint / OracleLibrary; overflow-wrap unchecked)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev UQ112x112 fraction = (numerator << 112) / denominator. `numerator` fits in uint112 (a reserve), so
    ///      the shift never overflows uint256 and the result fits in 224 bits. Matches the pair's own _update.
    function _fraction(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        if (denominator == 0) return 0; // div-by-zero guard (empty reserve) — caller degrades
        return (numerator << 112) / denominator;
    }

    /// @dev Counterfactual current cumulative for the tracked direction (WBNB-per-RAM), extrapolated to `now`
    ///      exactly as UniswapV2OracleLibrary.currentCumulativePrices does. Returns (0,false) on any pair-read
    ///      failure so the caller degrades instead of reverting.
    function _currentCumulative(address _pair, bool _ramIsToken0) private view returns (uint256, bool) {
        (uint112 r0, uint112 r1, uint32 tsLast, bool okR) = _reserves(_pair);
        if (!okR) return (0, false);
        (uint256 stored, bool okC) = _rawCumulative(_pair, _ramIsToken0);
        if (!okC) return (0, false);

        uint32 blockTs = uint32(block.timestamp % 2 ** 32);
        if (tsLast != blockTs) {
            unchecked {
                uint32 elapsed = blockTs - tsLast; // subtraction overflow is intentional (mod 2^32)
                uint256 frac = _ramIsToken0 ? _fraction(r1, r0) : _fraction(r0, r1);
                stored += frac * elapsed; // addition overflow is intentional (mod 2^256)
            }
        }
        return (stored, true);
    }

    /// @dev UQ112x112 (WBNB per 1 RAM base unit) → wei of BNB per 1e18 RAM. Rejects p ≥ MAX_UQ (absurd/overflow).
    function _uqToE18(uint256 p) private pure returns (uint256) {
        if (p == 0 || p >= MAX_UQ) return 0;
        return (p * 1e18) / Q112;
    }

    /// @dev ASYMMETRIC truncated-oracle cap: an interval price may RISE at most `maxTruncBps` above the previous
    ///      truncated price, but may FALL freely. Rationale (adversarial review, blocker): a symmetric clamp lets
    ///      the truncated price (and thus TWAP5, the "current" leg of min()) lag HIGH for several intervals after a
    ///      manipulated spike is released — defeating the min() anti-inflation bias and yielding trusted=true at an
    ///      inflated price (the one INACCEPTABLE case). Letting the price fall freely makes TWAP5 track the real
    ///      price down the instant the attacker releases, so min() collapses to the real price. A downward
    ///      manipulation now passes through as a LOW price → the vault OVER-charges RAM → the safe direction, which
    ///      is exactly the design's "always fail toward over-charging" invariant. The upside cap still throttles a
    ///      sustained pump (a >maxTruncBps rise per interval is capped every interval), so a real attacker must hold
    ///      the pool high across the whole TWAP window — the expensive, arbitraged, normal-TWAP threat model.
    function _clamp(uint256 p, uint256 pt) private view returns (uint256) {
        uint256 hi = (pt * (BPS + maxTruncBps)) / BPS;
        if (p > hi) return hi;
        return p; // no lower clamp — prices fall freely (safe direction: low price ⇒ over-charge)
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Guarded external reads (never revert — always degrade)
    // ─────────────────────────────────────────────────────────────────────────

    function _readPortal() private view returns (bool ok, uint8 status, uint256 price, address pool) {
        try portal.getTokenV8Safe(token) returns (IPortalTypes.TokenStateV8Safe memory s) {
            return (true, s.status, s.price, s.pool);
        } catch {
            return (false, 0, 0, address(0));
        }
    }

    function _isGraduated(bool portalOk, address cPool) private view returns (bool) {
        if (portalOk) return cPool != address(0);
        // Portal down: fall back to any prior on-chain evidence of graduation. Both `graduationFrozen` and a
        // resolved `pair` are only ever set AFTER a portal-confirmed graduation, so neither can falsely trip.
        return graduationFrozen != 0 || pair != address(0);
    }

    function _reserves(address _pair) private view returns (uint112, uint112, uint32, bool) {
        try IUniswapV2Pair(_pair).getReserves() returns (uint112 r0, uint112 r1, uint32 ts) {
            return (r0, r1, ts, true);
        } catch {
            return (0, 0, 0, false);
        }
    }

    function _rawCumulative(address _pair, bool _ramIsToken0) private view returns (uint256, bool) {
        if (_ramIsToken0) {
            try IUniswapV2Pair(_pair).price0CumulativeLast() returns (uint256 c) {
                return (c, true);
            } catch {
                return (0, false);
            }
        }
        try IUniswapV2Pair(_pair).price1CumulativeLast() returns (uint256 c) {
            return (c, true);
        } catch {
            return (0, false);
        }
    }

    function _resolvePair() private {
        address p;
        try factory.getPair(token, wbnb) returns (address p_) {
            p = p_;
        } catch {
            p = address(0);
        }
        if (p != address(0)) {
            pair = p;
            ramIsToken0 = token < wbnb; // PancakeV2 factory sorts token0 < token1 by address (verified on-chain)
            pairResolved = true;
            emit PairResolved(p, ramIsToken0);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Views for tests / UI / operators
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Number of valid observations currently in the ring (0..CARD).
    function observationCount() external view returns (uint8) {
        return _obsCount;
    }

    /// @notice The most recent observation (timestamp, truncated-cumulative).
    function latestObservation() external view returns (uint32 timestamp, uint224 truncCumulative) {
        Observation memory o = _obs[_obsHead];
        return (o.timestamp, o.truncCumulative);
    }
}
