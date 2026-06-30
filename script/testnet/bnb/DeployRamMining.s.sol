// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {RamMiningBeaconFactory} from "src/RamMiningVault.sol";
import {TestNvdaToken} from "src/TestNvdaToken.sol";
import {TestPriceFeed} from "src/TestPriceFeed.sol";

/// @title DeployRamMining
/// @notice Deploys the RAM keeper/RFQ mining building blocks to BNB testnet (chainId 97): a mock tokenized-NVIDIA
///         (tNVDA), two mock 8-decimal price feeds (NVDA/USD + BNB/USD — testnet has no real Chainlink NVDA/USD),
///         and the beacon-backed factory. The vault itself is launched through Flap's VaultPortal on testnet.flap.sh
///         using the factory address + the v2 `vaultData` logged below.
///
/// @dev THE DEPLOYER PRIVATE KEY MUST BE TREATED AS BURNED — testnet only, never reuse for mainnet/funds.
///      v2 vaultData = abi.encode(rewardToken, rewardPriceFeed, bnbPriceFeed, basePriceWei, seasonEnd).
///      Usage (run by the user with a funded testnet wallet):
///
///      forge script script/testnet/bnb/DeployRamMining.s.sol:DeployRamMining \
///          --rpc-url https://bsc-testnet-rpc.publicnode.com \
///          --broadcast \
///          --private-key <PRIVATE_KEY>
contract DeployRamMining is Script {
    function run() external {
        vm.startBroadcast();

        // 1) testnet reward token mock (mainnet: use the real NVDAB 0x02Fca66C…7436)
        TestNvdaToken rewardToken = new TestNvdaToken();

        // 2) mock 8-dec price feeds (mainnet: real Chainlink NVDA/USD + BNB/USD). Seed ~$130 NVDA / ~$600 BNB.
        TestPriceFeed nvdaUsdFeed = new TestPriceFeed(8, 130e8);
        TestPriceFeed bnbUsdFeed = new TestPriceFeed(8, 600e8);

        // 3) RAM mining factory (beacon + implementation)
        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();

        vm.stopBroadcast();

        // suggested launch params for Flap (basePrice 0.001 BNB, 60-day season)
        uint256 basePriceWei = 0.001 ether;
        uint256 seasonEnd = block.timestamp + 60 days;

        console.log("=== RAM Mining testnet deploy (keeper/RFQ v2) ===");
        console.log("RamMiningBeaconFactory:", address(factory));
        console.log("Beacon:                ", factory.beacon());
        console.log("Vault implementation:  ", factory.beaconImplementation());
        console.log("Reward token (tNVDA):  ", address(rewardToken));
        console.log("NVDA/USD feed (mock):  ", address(nvdaUsdFeed));
        console.log("BNB/USD feed (mock):   ", address(bnbUsdFeed));
        console.log("--- Flap launch vaultData (abi.encode in this order) ---");
        console.log("rewardToken:    ", address(rewardToken));
        console.log("rewardPriceFeed:", address(nvdaUsdFeed));
        console.log("bnbPriceFeed:   ", address(bnbUsdFeed));
        console.log("basePriceWei:   ", basePriceWei);
        console.log("seasonEnd:      ", seasonEnd);
    }
}
