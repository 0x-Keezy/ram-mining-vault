// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {RamMiningBeaconFactory} from "src/RamMiningVault.sol";
import {TestNvdaToken} from "src/TestNvdaToken.sol";

/// @title DeployRamMining
/// @notice Deploys the RAM mining beacon-backed vault factory + a testnet tokenized-NVIDIA mock to BNB testnet
///         (chainId 97). The factory is registered with Flap; the vault is launched via Flap's VaultPortal using
///         the params logged below (vaultData = abi.encode(rewardToken, swapRouter, basePriceWei, seasonEnd)).
///
/// @dev THE DEPLOYER PRIVATE KEY MUST BE TREATED AS BURNED — testnet only, never reuse for mainnet/funds.
///      Usage (run by the user with a funded testnet wallet):
///
///      forge script script/testnet/bnb/DeployRamMining.s.sol:DeployRamMining \
///          --rpc-url https://bsc-testnet-dataseed.bnbchain.org \
///          --broadcast \
///          --private-key <PRIVATE_KEY>
contract DeployRamMining is Script {
    // PancakeSwap V2 router on BNB testnet (chain 97). Confirm on-chain before relying on it.
    address constant PANCAKE_ROUTER_TESTNET = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    function run() external {
        vm.startBroadcast();

        // 1) testnet reward token (replace with the real NVDAx address on mainnet)
        TestNvdaToken rewardToken = new TestNvdaToken();

        // 2) RAM mining factory (beacon + implementation)
        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();

        vm.stopBroadcast();

        // suggested launch params for Flap (basePrice 0.001 BNB, 60-day season)
        uint256 basePriceWei = 0.001 ether;
        uint256 seasonEnd = block.timestamp + 60 days;

        console.log("=== RAM Mining testnet deploy ===");
        console.log("RamMiningBeaconFactory:", address(factory));
        console.log("Beacon:                ", factory.beacon());
        console.log("Vault implementation:  ", factory.beaconImplementation());
        console.log("Reward token (tNVDA):  ", address(rewardToken));
        console.log("Swap router (Pancake): ", PANCAKE_ROUTER_TESTNET);
        console.log("--- Flap launch vaultData params ---");
        console.log("rewardToken:  ", address(rewardToken));
        console.log("swapRouter:   ", PANCAKE_ROUTER_TESTNET);
        console.log("basePriceWei: ", basePriceWei);
        console.log("seasonEnd:    ", seasonEnd);
    }
}
