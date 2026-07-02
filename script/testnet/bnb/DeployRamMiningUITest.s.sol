// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "src/RamMiningVault.sol";
import {TestNvdaToken} from "src/TestNvdaToken.sol";
import {TestPriceFeed} from "src/TestPriceFeed.sol";

/// @title DeployRamMiningUITest
/// @notice TESTNET-ONLY (chain 97). Deploys mocks + a REAL RamMiningVault instance (direct BeaconProxy, bypassing
///         Flap's VaultPortal + the production dev-lock — both are production security features, irrelevant to a UI
///         data test) and SEEDS it with real on-chain state so the bespoke UI can read live numbers: buys 2 rigs
///         (permissionless) and donates NVDA rewards (permissionless) to the active miner. The testnet Guardian is a
///         Flap address, so the keeper path is not armed here — rig power + donated rewards are enough to light up
///         the UI (total power, rigs sold, my rigs, claimable, distributed).
/// @dev THROWAWAY test wallet only. Run:
///      forge script script/testnet/bnb/DeployRamMiningUITest.s.sol:DeployRamMiningUITest \
///        --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --private-key <TEST_KEY>
contract DeployRamMiningUITest is Script {
    address constant DEPLOYER = 0xD3e8ca00BCe8b6Bed274e1c6e700b5f6655d16E6; // funded testnet test wallet

    function run() external {
        uint256 basePriceWei = 0.001 ether;
        uint256 seasonEnd = block.timestamp + 60 days;

        vm.startBroadcast();

        // 1) mocks: tokenized-NVIDIA (tNVDA) + two 8-dec price feeds (testnet has no real Chainlink NVDA/USD)
        TestNvdaToken tnvda = new TestNvdaToken();
        TestPriceFeed nvdaUsdFeed = new TestPriceFeed(8, 130e8); // ~$130 NVDA
        TestPriceFeed bnbUsdFeed = new TestPriceFeed(8, 600e8); // ~$600 BNB

        // 2) factory (for the beacon + implementation), then a REAL vault via direct BeaconProxy (test-only path)
        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();
        BeaconProxy proxy = new BeaconProxy(
            factory.beacon(),
            abi.encodeCall(
                RamMiningVaultUpgradeable.initialize,
                (address(tnvda), address(tnvda), address(nvdaUsdFeed), address(bnbUsdFeed), basePriceWei, seasonEnd)
            )
        );
        RamMiningVaultUpgradeable vault = RamMiningVaultUpgradeable(payable(address(proxy)));

        // 3) SEED real state: buy a Micro (plan 0) + a Mega (plan 2) rig — permissionless, BNB goes to the treasury
        vault.buyMiningContract{value: basePriceWei}(0); // Micro: power 10, 1d
        vault.buyMiningContract{value: basePriceWei * 8}(2); // Mega: power 130, 30d

        // 4) SEED rewards: mint tNVDA to the deployer, then donate — distributes pro-rata to the active rigs
        tnvda.mint(DEPLOYER, 5_000e18);
        tnvda.approve(address(vault), type(uint256).max);
        vault.donateReward(400e18);

        vm.stopBroadcast();

        console.log("=== RAM Mining UI TEST vault (BNB testnet, chain 97) ===");
        console.log("VAULT (point the UI here):", address(vault));
        console.log("tNVDA reward token:       ", address(tnvda));
        console.log("Factory:                  ", address(factory));
        console.log("NVDA/USD feed (mock):     ", address(nvdaUsdFeed));
        console.log("BNB/USD feed (mock):      ", address(bnbUsdFeed));
        console.log("Miner (owns the 2 rigs):  ", DEPLOYER);
        console.log("seasonEnd:                ", seasonEnd);
    }
}
