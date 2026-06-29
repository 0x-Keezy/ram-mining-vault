// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable, AggregatorV3Interface} from "../src/RamMiningVault.sol";

/// @title RAM mainnet-fork test against the REAL tokenized-NVIDIA token (NVDAB) on BNB mainnet — KEEPER model.
/// @notice The honest way to test the v2 keeper/RFQ acquisition + distribution against a real regulated asset and
///         the real Chainlink NVDA/USD feed, without spending funds (RWAs are mainnet-only; no NVDA on testnet).
///
/// Runs ONLY when BNB_RPC_URL is set (otherwise it returns early so the suite stays green). The reward token and
/// feeds default to the verified mainnet addresses but can be overridden by env vars:
///   - BNB_RPC_URL       : a BNB mainnet RPC (REQUIRED; never hardcoded).
///   - FORK_BLOCK        : optional block number to pin (use a recent WEEKDAY block so NVDA/USD is fresh).
///   - NVDAX_ADDRESS     : the reward token (defaults to NVDAB 0x02Fca66C…7436).
///   - NVDA_USD_FEED     : Chainlink NVDA/USD (defaults to 0xea5c2Cbb…99B8, 8 dec).
///   - BNB_USD_FEED      : Chainlink BNB/USD  (defaults to 0x0567F232…42aeE, 8 dec).
///
/// IMPORTANT (weekend-freeze honesty): staleness is NOT relaxed. The reward-feed staleness bound stays at a real
/// 2h. If the forked block lands when NVDA/USD is frozen (nights/weekends), the test asserts the keeper path
/// REVERTS on staleness (the de-facto acquisition pause). If the feed is fresh (market open), it runs the full
/// keeper fill + distribute + claim against the real asset.
contract RamMiningVaultForkTest is Test {
    address constant GUARDIAN_MAINNET = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant BNB_MAINNET_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant RAM_TOKEN = address(0x4A11);

    // verified mainnet defaults (from the RAM v2 design doc §10)
    address constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address constant NVDA_USD = 0xea5c2Cbb5cD57daC24E26180b19a929F3E9699B8;
    address constant BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    address constant MINER = address(0xA11CE);
    address constant KEEPER = address(0xBEEF);

    // real bound (2h) that still catches the weekend freeze; overridable via env to exercise the fresh-market path
    // on a weekend (when the live feed is hours-stale) without weakening the production default.
    function _rewardStale() internal view returns (uint256) {
        return vm.envOr("REWARD_STALE", uint256(2 hours));
    }

    /// @dev Deploy + set realistic oracle guards. Split out to keep the test function's stack shallow.
    function _deployForkVault(address nvda) internal returns (RamMiningVaultUpgradeable vault) {
        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();
        bytes memory vaultData = abi.encode(
            nvda,
            vm.envOr("NVDA_USD_FEED", NVDA_USD),
            vm.envOr("BNB_USD_FEED", BNB_USD),
            uint256(0.001 ether),
            block.timestamp + 30 days
        );
        vm.prank(BNB_MAINNET_VAULT_PORTAL);
        vault = RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), address(this), vaultData)));
        // realistic real bounds — NOT relaxed to mask the weekend freeze.
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

        // a miner buys power. Read basePriceWei() BEFORE the prank — an external call inside {value:...} would
        // otherwise consume vm.prank (Foundry gotcha) and the rig would go to the test contract, not MINER.
        vm.deal(MINER, 1 ether);
        uint256 rigPrice = vault.basePriceWei();
        vm.prank(MINER);
        vault.buyMiningContract{value: rigPrice}(0);
        // simulate BNB fees arriving in the vault treasury
        vm.deal(address(vault), 5 ether);

        if (_feedFresh(vault.rewardPriceFeed(), _rewardStale())) {
            _runFreshMarketPath(vault, nvda);
        } else {
            emit log("NVDA/USD feed stale at this block (market closed) -> keeper path must revert (de-facto pause)");
            _runFrozenFeedPath(vault);
        }
    }

    /// Market OPEN: full keeper fill + distribute + claim against the real NVDAB, then an acquisition-pause check.
    function _runFreshMarketPath(RamMiningVaultUpgradeable vault, address nvda) internal {
        // arm the deviation band reference at the live price (required before caps), then the egress caps
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
        uint256 quoted = vault.quoteSellToVault(1e18);
        assertGt(quoted, 0, "oracle quote should be positive");

        uint256 keeperBnbBefore = KEEPER.balance; // mainnet fork inherits any real pre-existing balance
        vm.startPrank(KEEPER);
        IERC20(nvda).approve(address(vault), 1e18);
        assertEq(vault.sellRewardToVault(1e18, 0), quoted, "paid == quote");
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

        // simulate acquisition pause: sells revert, but claims still work
        vm.prank(GUARDIAN_MAINNET);
        vault.pauseAcquisition();
        vm.prank(whale);
        IERC20(nvda).transfer(KEEPER, 1e18);
        vm.startPrank(KEEPER);
        IERC20(nvda).approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Acquisition paused / 收购已暂停"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    /// Market CLOSED (feed frozen): the hard staleness check is the de-facto pause — the quote/sell must revert.
    function _runFrozenFeedPath(RamMiningVaultUpgradeable vault) internal {
        vm.expectRevert(bytes(unicode"Stale feed / 预言机数据过期"));
        vault.quoteSellToVault(1e18);
    }
}
