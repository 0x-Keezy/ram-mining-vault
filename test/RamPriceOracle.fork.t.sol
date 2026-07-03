// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RamPriceOracle} from "../src/RamPriceOracle.sol";
import {IPortalLens, IPortalTypes} from "../src/flap/IPortal.sol";

/// @dev Minimal PCS V2 pair surface for the attack simulation (donation + sync moves the spot).
interface IPairFork {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sync() external;
}

/// @title RamPriceOracle — BSC mainnet fork test (REAL Flap portal, REAL PancakeSwap V2 pair).
/// @notice Proves the production oracle against live state without spending funds. Runs ONLY when BNB_RPC_URL is
///         set (otherwise vm.skip keeps the suite honest). Three scenarios, mirroring the design's threat model:
///           (a) GRADUATED pair: build a mature TWAP and sanity-check it against live reserves (±20%).
///           (b) CURVE token: the price equals the portal's marginal curve price.
///           (c) ATTACK: move the real pair's spot ~2x and prove the priced value barely moves (truncation+min).
///
/// @dev The manipulation in (c) is a WBNB donation + `sync()`. This is a COSTLESS (and therefore strictly
///      STRONGER) manipulation than a real buy that must respect the constant-product invariant and the token's
///      transfer tax: it moves the exact same observable state (reserves + accumulators) that the oracle reads,
///      with none of an attacker's real-world cost. Resisting it is a conservative, faithful proof of defense.
contract RamPriceOracleForkTest is Test {
    // Verified on-chain (research 2026-07-02).
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0; // Flap portal proxy v5.14.15
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73; // PancakeSwap V2 factory
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // A real GRADUATED flap token (status DEX) and its live PCS V2 pair (~94 WBNB per side).
    address constant GRAD_TOKEN = 0x091652EBc0A0238d7151a868f22D7CfD2a267777;
    address constant GRAD_PAIR = 0xCd915c6d8A207F754F62541Ca12E85bD7e1e2Ac0;
    // A real token still on the bonding curve (status Tradable, pool == 0).
    address constant CURVE_TOKEN = 0x6BcC641D1eF33c4d7A2C9536a3E0356F77Ff7777;

    uint256 constant FLOOR = 10 ether; // 10 WBNB liquidity floor (well under the ~94 WBNB pool)
    uint16 constant TRUNC = 5000; // ±50%

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: set BNB_RPC_URL to run the RamPriceOracle mainnet fork test");
            vm.skip(true);
            return false;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 56, "fork must be BNB mainnet");
        return true;
    }

    function _pokeAdvance(RamPriceOracle oracle, uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        oracle.poke();
    }

    /// @dev Live spot price of 1e18 RAM in WBNB wei, straight from reserves (what the mature TWAP should track).
    function _spotE18(RamPriceOracle oracle) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPairFork(GRAD_PAIR).getReserves();
        if (oracle.ramIsToken0()) return (uint256(r1) * 1e18) / uint256(r0);
        return (uint256(r0) * 1e18) / uint256(r1);
    }

    // ── (a) mature TWAP tracks live reserves, and (c) attack resistance ─────────────────────

    function testForkGraduatedTwapAndAttack() public {
        if (!_fork()) return;

        RamPriceOracle oracle =
            new RamPriceOracle(PORTAL, GRAD_TOKEN, WBNB, FACTORY, FLOOR, TRUNC);
        assertEq(oracle.pair(), GRAD_PAIR, "resolved the canonical pair");
        assertTrue(oracle.ramIsToken0(), "GRAD < WBNB => token0");

        // Build a mature TWAP: 8 five-minute intervals (40 min) at the (constant, on the fork) live spot.
        oracle.poke(); // seed
        for (uint256 i = 0; i < 8; i++) {
            _pokeAdvance(oracle, 5 minutes);
        }

        (uint256 priceBefore, bool trBefore) = oracle.getPrice(GRAD_TOKEN);
        uint256 spotBefore = _spotE18(oracle);
        emit log_named_uint("(a) mature TWAP price (wei/1e18 RAM)", priceBefore);
        emit log_named_uint("(a) live spot price     (wei/1e18 RAM)", spotBefore);
        assertTrue(trBefore, "(a) mature + liquid => trusted");
        // Sanity: the mature TWAP tracks live reserves within 20%.
        assertLe(priceBefore, (spotBefore * 120) / 100, "(a) TWAP <= spot +20%");
        assertGe(priceBefore, (spotBefore * 80) / 100, "(a) TWAP >= spot -20%");

        // ── (c) ATTACK: donate WBNB to the pair and sync() to ~double the WBNB-per-RAM spot ──
        (uint112 ar0, uint112 ar1,) = IPairFork(GRAD_PAIR).getReserves();
        uint256 wbnbReserve = oracle.ramIsToken0() ? uint256(ar1) : uint256(ar0);
        // Set the pair's WBNB balance to ~2x its reserve, then sync -> reserve (and spot) ~doubles.
        deal(WBNB, GRAD_PAIR, wbnbReserve * 2);
        IPairFork(GRAD_PAIR).sync();

        uint256 spotAfter = _spotE18(oracle);
        emit log_named_uint("(c) live spot AFTER attack", spotAfter);
        assertGe(spotAfter, (spotBefore * 150) / 100, "(c) attack really moved spot >= +50%");

        // Let the manipulated price integrate for one interval, then poke and read.
        _pokeAdvance(oracle, 5 minutes);
        (uint256 priceAfter, bool trAfter) = oracle.getPrice(GRAD_TOKEN);
        emit log_named_uint("(c) oracle price AFTER attack", priceAfter);
        assertTrue(trAfter, "(c) still trusted (mature)");

        // The priced value must barely move: truncation caps the interval to +50% and min() picks the lagging
        // TWAP30 -> expected ~+8%. We allow <=+15% for window-edge/rounding slack; spot moved ~+100%.
        uint256 moveBps = priceAfter > priceBefore ? ((priceAfter - priceBefore) * 10_000) / priceBefore : 0;
        emit log_named_uint("(c) oracle move (bps)", moveBps);
        emit log_named_uint("(c) spot   move (bps)", ((spotAfter - spotBefore) * 10_000) / spotBefore);
        assertLe(priceAfter, (priceBefore * 115) / 100, "(c) oracle price moved <= +15% despite ~2x spot");
    }

    // ── (b) curve token price == portal marginal price ──────────────────────────────────────

    function testForkCurveTokenPrice() public {
        if (!_fork()) return;

        // Read the live portal state for the curve token.
        IPortalTypes.TokenStateV8Safe memory s = IPortalLens(PORTAL).getTokenV8Safe(CURVE_TOKEN);
        emit log_named_uint("(b) portal status", s.status);
        emit log_named_uint("(b) portal price (wei/1e18 token)", s.price);
        emit log_named_address("(b) portal pool", s.pool);

        RamPriceOracle oracle =
            new RamPriceOracle(PORTAL, CURVE_TOKEN, WBNB, FACTORY, FLOOR, TRUNC);

        (uint256 price, bool trusted) = oracle.getPrice(CURVE_TOKEN);
        emit log_named_uint("(b) oracle curve price", price);
        emit log_named_string("(b) oracle trusted", trusted ? "true" : "false");

        if (s.status == 1 && s.pool == address(0) && s.price > 0) {
            // Still on the curve as expected: the oracle serves min(marginal, trailing) == the marginal price
            // (the constructor seeds the trailing anchor at the same value in the same block).
            assertTrue(trusted, "(b) curve trusted");
            assertEq(price, s.price, "(b) curve price == portal marginal price");
        } else {
            // The reference token changed state since the research snapshot (outside our control) — don't fail
            // the suite for it; just record what happened.
            emit log("(b) NOTE: reference curve token is no longer in the expected curve state; skipping equality");
        }
    }
}
