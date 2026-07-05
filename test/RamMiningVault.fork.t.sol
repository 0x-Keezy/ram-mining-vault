// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable, AggregatorV3Interface} from "../src/RamMiningVault.sol";

/// @dev Mintable RAM tax-token stand-in deployed INTO the fork (the real RAM token doesn't exist pre-launch).
///      Needed since the v3 entry gate: a fresh wallet may only buy the Micro with BNB, so the long-lived
///      Hyper this test requires must be bought through the (armed) RAM path — the legal post-gate flow.
contract ForkRamToken is ERC20 {
    constructor() ERC20("Fork RAM", "fRAM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fixed-price RAM oracle for the fork vault (same shape as the unit suites' mock).
contract ForkRamOracle {
    uint256 internal constant PRICE = 2e12; // 1 RAM = 0.000002 BNB

    function pokeAndGetPrice(address) external pure returns (uint256, bool) {
        return (PRICE, true);
    }

    function getPrice(address) external pure returns (uint256, bool) {
        return (PRICE, true);
    }
}

/// @title RAM mainnet-fork test against the REAL tokenized-NVIDIA token (NVDAB) on BNB mainnet — KEEPER model.
/// @notice The honest way to test the v2 keeper/RFQ acquisition + distribution against a real regulated asset and
///         the real Chainlink NVDA/USD feed, without spending funds (RWAs are mainnet-only; no NVDA on testnet).
///
/// Runs ONLY when BNB_RPC_URL is set (otherwise it returns early so the suite stays green). The reward token and
/// feeds default to the verified mainnet addresses but can be overridden by env vars:
///   - BNB_RPC_URL       : a BNB mainnet RPC (REQUIRED; never hardcoded).
///   - FORK_BLOCK        : optional block number to pin (a weekend block is great — it proves continuous operation).
///   - NVDAX_ADDRESS     : the reward token (defaults to NVDAB 0x02Fca66C…7436).
///   - NVDA_USD_FEED     : Chainlink NVDA/USD (defaults to 0xea5c2Cbb…99B8, 8 dec).
///   - BNB_USD_FEED      : Chainlink BNB/USD  (defaults to 0x0567F232…42aeE, 8 dec).
///   - REWARD_STALE      : NVDA/USD staleness bound (defaults to 7d, Flap #8; may be set up to 30d).
///
/// WEEKEND CONTINUOUS OPERATION (Flap #8): the NVDA/USD staleness bound is GENEROUS (7d default). Per Flap's
/// guidance the vault must NOT pause buys/fills off-hours — a stock feed frozen over a weekend is still within the
/// 7d bound, so the keeper fill OPERATES at the last (Friday) print. This INVERTS the old "weekend-freeze =
/// de-facto pause" behaviour. A genuinely dead feed (older than the bound) still reverts (the dead-feed safety
/// wall, covered as a unit test). This fork test proves the real fill + distribute + claim path against NVDAB.
contract RamMiningVaultForkTest is Test {
    address constant GUARDIAN_MAINNET = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant BNB_MAINNET_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant RAM_TOKEN = address(0x4A11);

    // verified mainnet feeds (NVDA/USD provided by Flap 2026-06-30, verified on-chain: 8-dec, "NVDA / USD" ~$194.70;
    // BNB/USD = canonical Chainlink BSC aggregator, verified 8-dec "BNB / USD" ~$550, ~30s fresh).
    address constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    // Flap's canonical NVDA/USD aggregator (Ondo + Chainlink + Pyth Pro), per stocks_factory_state.md.
    // This is the feed the production vaultData will point rewardPriceFeed at (2026-07-04 decision).
    address constant NVDA_USD = 0xea5c2Cbb5cD57daC24E26180b19a929F3E9699B8;
    address constant BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    address constant MINER = address(0xA11CE);
    address constant KEEPER = address(0xBEEF);

    // Generous NVDA/USD staleness (Flap #8): weekend-frozen feeds keep operating; only a genuinely dead feed
    // (older than this bound, ≤ MAX_REWARD_FEED_STALE = 30d) reverts. Overridable via env.
    function _rewardStale() internal view returns (uint256) {
        return vm.envOr("REWARD_STALE", uint256(7 days));
    }

    ForkRamToken internal forkRam;

    /// @dev Deploy + set realistic oracle guards. Split out to keep the test function's stack shallow.
    ///      v3 entry gate: the RAM sink pricing is ARMED at creation (mock RAM token + fixed-price oracle
    ///      deployed into the fork) so the test can hold the long-lived Hyper through the LEGAL flow
    ///      (Micro entry in BNB + Hyper growth in RAM). Keeper/claim paths never touch the RAM oracle.
    function _deployForkVault(address nvda) internal returns (RamMiningVaultUpgradeable vault) {
        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();
        forkRam = new ForkRamToken();
        ForkRamOracle ramOracle = new ForkRamOracle();
        bytes memory vaultData = abi.encode(
            nvda,
            vm.envOr("NVDA_USD_FEED", NVDA_USD),
            vm.envOr("BNB_USD_FEED", BNB_USD),
            uint256(0.001 ether),
            uint256(10e8), // $10 Micro USD-target (8 dec) → Hyper $1,000; sinks read the LIVE BNB/USD feed on the fork
            block.timestamp + 120 days,
            address(ramOracle),
            uint256(1e12),
            uint256(4e12),
            address(0x7E57)
        );
        vm.prank(BNB_MAINNET_VAULT_PORTAL);
        vault = RamMiningVaultUpgradeable(payable(factory.newVault(address(forkRam), address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vaultData)));
        // BNB/USD tight (24/7), NVDA/USD generous (weekend continuous operation per Flap #8).
        vm.prank(GUARDIAN_MAINNET);
        vault.setOracleGuards(500, 2 hours, _rewardStale());
    }

    function _feedFresh(address feed, uint256 maxStale) internal view returns (bool) {
        (, int256 ans,, uint256 upd,) = AggregatorV3Interface(feed).latestRoundData();
        return ans > 0 && block.timestamp >= upd && block.timestamp - upd <= maxStale;
    }

    function _liveNvdaUsd(address feed) internal view returns (uint256) {
        (, int256 ans,,,) = AggregatorV3Interface(feed).latestRoundData();
        return uint256(ans);
    }

    function testForkKeeperFillAndDistributeRealNvda() public {
        string memory rpc = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: set BNB_RPC_URL to run the real-NVDAB keeper fork test");
            vm.skip(true); // report as SKIPPED (not PASSED) so the suite count is honest without an RPC
            return;
        }
        address nvda = vm.envOr("NVDAX_ADDRESS", NVDAB);

        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        assertEq(block.chainid, 56, "fork must be BNB mainnet");

        RamMiningVaultUpgradeable vault = _deployForkVault(nvda);

        // a miner acquires a long-lived (Hyper) rig through the LEGAL v3 flow — entry gate: the first rig
        // must be the Micro in BNB; the Hyper is then bought through the armed RAM path. Read prices BEFORE
        // the prank — an external call inside {value:...} would otherwise consume vm.prank (Foundry gotcha).
        vm.deal(MINER, 1 ether);
        (uint256 microPrice,,,) = vault.getPlan(0);
        vm.prank(MINER);
        vault.buyMiningContract{value: microPrice}(0); // entry rig (Micro, 1d — expires before the stale warp)
        // v3.2 USD-sink: the Hyper now targets $1,000 in RAM at the LIVE BNB/USD price — mint with ample
        // headroom so the buy succeeds across any live price / cage-floor path (worst case ≈ 3.6e24 units).
        forkRam.mint(MINER, 1e25);
        vm.prank(MINER);
        forkRam.approve(address(vault), type(uint256).max);
        vm.prank(MINER);
        vault.buyMiningContract(3); // growth rig: Hyper (90d) paid in RAM — keeps the miner alive at the wall
        // simulate BNB fees arriving in the vault treasury
        vm.deal(address(vault), 5 ether);

        if (_feedFresh(vault.rewardPriceFeed(), _rewardStale())) {
            // Normal case with the generous bound: weekday OR weekend, the fill OPERATES (Flap #8).
            _runContinuousFillPath(vault, nvda);
        } else {
            // Only reached if the pinned block has an NVDA/USD feed older than the staleness bound (genuinely
            // dead / very long holiday): the dead-feed safety wall must make the quote/sell revert.
            emit log("NVDA/USD feed older than the staleness bound (dead feed) -> keeper path must revert");
            _runDeadFeedPath(vault);
        }
    }

    /// Continuous operation: full keeper fill + distribute + claim against the real NVDAB (weekday or weekend).
    function _runContinuousFillPath(RamMiningVaultUpgradeable vault, address nvda) internal {
        // arm the deviation band reference at the live price (required before caps), then the egress caps.
        // compute the live reference BEFORE the prank — vault.rewardPriceFeed() is an external call that would
        // otherwise consume vm.prank and make setReferencePrice run as a non-guardian ("Only Guardian").
        uint256 liveRef = _liveNvdaUsd(vault.rewardPriceFeed());
        vm.prank(GUARDIAN_MAINNET);
        vault.setReferencePrice(liveRef);
        vm.prank(GUARDIAN_MAINNET);
        vault.setKeeperLimits(100 ether, 100 ether);

        // a keeper sources real NVDAB from a large holder (Binance deposit) — robust vs deal() on this ERC-8056
        // proxy (uiMultiplier makes deal() unreliable); a real transfer gives a true 1:1 balance.
        address whale = 0x8894E0a0c962CB723c1976a4421c95949bE2D4E3; // Binance 51, ~85% of NVDAB supply
        vm.prank(whale);
        IERC20(nvda).transfer(KEEPER, 1e18);
        uint256 quoted = vault.quoteRWAToVault(1e18);
        assertGt(quoted, 0, "oracle quote should be positive");

        uint256 keeperBnbBefore = KEEPER.balance; // mainnet fork inherits any real pre-existing balance
        vm.startPrank(KEEPER);
        IERC20(nvda).approve(address(vault), 1e18);
        assertEq(vault.sellRWAToVault(1e18, 0), quoted, "paid == quote");
        vm.stopPrank();
        assertEq(KEEPER.balance - keeperBnbBefore, quoted, "keeper received BNB");
        assertGt(IERC20(nvda).balanceOf(address(vault)), 0, "vault holds real NVDAB");

        // miner can claim real NVDAB
        assertGt(vault.pendingRewards(MINER), 0);
        uint256 minerNvdaBefore = IERC20(nvda).balanceOf(MINER); // robust to any fork-inherited balance
        vm.prank(MINER);
        uint256 got = vault.claimRewards();
        assertEq(IERC20(nvda).balanceOf(MINER) - minerNvdaBefore, got);
        assertGt(got, 0);

        // dead-feed safety wall ON THE REAL FEED: warp past the staleness bound; the long-lived rig keeps the
        // miner active, so the NEXT sell must FAIL-CLOSED (not on "no miners") — the real wall fires. The exact
        // revert reason depends on how the real Chainlink NVDA/USD feed reports a long-dead round: it may return a
        // positive-but-old answer ("Stale feed" via the updatedAt check) OR zero out its round ("Bad feed price"
        // via the answer<=0 guard — verified: this feed returns answer<=0 when queried far past its last round).
        // Both are fail-closed (no BNB leaves), which is the safety property under test, so accept either.
        vm.warp(block.timestamp + _rewardStale() + 1 days);
        vm.prank(whale);
        IERC20(nvda).transfer(KEEPER, 1e18);
        vm.startPrank(KEEPER);
        IERC20(nvda).approve(address(vault), 1e18);
        vm.expectRevert(); // dead/stale real feed → sell reverts (fail-closed); reason is feed-reporting-dependent
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
        // sanity: no BNB left the vault on the blocked fill (the wall held)
        assertEq(KEEPER.balance - keeperBnbBefore, quoted, "no extra BNB egress after the staleness wall");
    }

    /// Dead feed (older than the staleness bound): the hard staleness/answer guard makes the quote revert
    /// (fail-closed). Reason is feed-reporting-dependent ("Stale feed" if positive-but-old, "Bad feed price" if the
    /// real feed zeroed its round) — both block the quote, which is the property under test.
    function _runDeadFeedPath(RamMiningVaultUpgradeable vault) internal {
        vm.expectRevert();
        vault.quoteRWAToVault(1e18);
    }
}
