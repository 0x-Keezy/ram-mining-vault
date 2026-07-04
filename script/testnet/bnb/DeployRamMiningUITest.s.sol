// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "src/RamMiningVault.sol";
import {TestNvdaToken} from "src/TestNvdaToken.sol";
import {TestPriceFeed} from "src/TestPriceFeed.sol";
import {TestRamOracle} from "src/TestRamOracle.sol";

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
        uint256 seasonEnd = block.timestamp + 90 days; // > RIG_LIFE so rigs get the full 60d
        uint256 ramBnbPrice = 2e12; // 1 "RAM" (tnvda double-role) = 0.000002 BNB

        vm.startBroadcast();

        // 1) mocks: tokenized-NVIDIA (tNVDA, double role: reward token AND the "RAM" tax token for Phase-2
        //    sinks) + two 8-dec price feeds + the Phase-2 test RAM-price oracle (fixed, trusted).
        TestNvdaToken tnvda = new TestNvdaToken();
        TestPriceFeed nvdaUsdFeed = new TestPriceFeed(8, 130e8); // ~$130 NVDA
        TestPriceFeed bnbUsdFeed = new TestPriceFeed(8, 600e8); // ~$600 BNB
        TestRamOracle ramOracle = new TestRamOracle(ramBnbPrice);

        // 2) factory (for the beacon + implementation), then a REAL vault via direct BeaconProxy (test-only
        //    path). Phase-2 pricing is LAUNCHER-ARMED via the initialize params (oracle + cage) — no Guardian
        //    round-trip needed on testnet (chain-97 Guardian is Flap's address, not ours).
        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();
        BeaconProxy proxy = new BeaconProxy(
            factory.beacon(),
            abi.encodeCall(
                RamMiningVaultUpgradeable.initialize,
                (
                    address(tnvda),
                    address(tnvda),
                    address(nvdaUsdFeed),
                    address(bnbUsdFeed),
                    basePriceWei,
                    seasonEnd,
                    address(ramOracle),
                    ramBnbPrice / 2,
                    ramBnbPrice * 2,
                    DEPLOYER // test treasury wallet: the deployer itself (production uses the dedicated treasury)
                )
            )
        );
        RamMiningVaultUpgradeable vault = RamMiningVaultUpgradeable(payable(address(proxy)));

        // 3) SEED the two-phase economy end-to-end, following the v3 ENTRY GATE (a fresh wallet may only
        //    enter with the Micro in BNB — EntryRigMustBeMicro): Micro entry, then growth through the RAM
        //    sinks (Hyper rig #2 paid in RAM, and an upgrade of the entry rig paying the RAM difference).
        tnvda.mint(DEPLOYER, 50_000e18);
        tnvda.approve(address(vault), type(uint256).max);
        vault.buyMiningContract{value: basePriceWei}(0); // rig #1: Micro (the ONLY legal BNB entry), power 10, 1d
        vault.buyMiningContract(3); // rig #2: Hyper in RAM, power 420, 90d (85% of the RAM burned)
        vault.upgradeRig(0, 1); // rig #1 Micro → Core in RAM (diff price), power 40 fresh — lifetime stays 1d

        // 4) SEED rewards: donate — distributes pro-rata to the active (wear-decaying) power
        vault.donateReward(400e18);

        vm.stopBroadcast();

        console.log("=== RAM Mining UI TEST vault v3/Fase2 (BNB testnet, chain 97) ===");
        console.log("VAULT (point the UI here):", address(vault));
        console.log("tNVDA reward+RAM token:   ", address(tnvda));
        console.log("RAM price oracle (test):  ", address(ramOracle));
        console.log("Factory:                  ", address(factory));
        console.log("NVDA/USD feed (mock):     ", address(nvdaUsdFeed));
        console.log("BNB/USD feed (mock):      ", address(bnbUsdFeed));
        console.log("Miner (owns the 2 rigs):  ", DEPLOYER);
        console.log("seasonEnd:                ", seasonEnd);
    }
}
