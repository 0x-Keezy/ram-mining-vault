// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";

/// @title RAM mainnet-fork test against a REAL tokenized-NVIDIA token on BNB mainnet.
/// @notice This is the honest way to test the swap + distribution with a real asset and real liquidity, without
///         spending funds or legal exposure (no NVDA exists on any public testnet — RWAs are mainnet-only).
///
/// Runs ONLY when both env vars are set (otherwise it returns early so the suite stays green):
///   - BNB_RPC_URL    : a BNB mainnet RPC (Alchemy/QuickNode/Chainstack/official)
///   - NVDAX_ADDRESS  : the verified on-chain address of the tokenized NVIDIA token (e.g. xStocks NVDAx).
///                      MUST be confirmed on-chain before relying on results (free-transfer NVDAx/NVDAB only;
///                      NOT Ondo/Dinari which are KYC/permissioned and would break distribution).
///
/// PancakeSwap V2 router (BNB mainnet): 0x10ED43C718714eb63d5aA57B78B54704E256024E
contract RamMiningVaultForkTest is Test {
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant GUARDIAN_MAINNET = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    // VaultPortal resolves per-chain inside the factory; on mainnet (56) the portal is fixed.
    address constant BNB_MAINNET_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant RAM_TOKEN = address(0x4A11);

    function testForkSwapAndDistributeRealNvda() public {
        string memory rpc = vm.envOr("BNB_RPC_URL", string(""));
        address nvda = vm.envOr("NVDAX_ADDRESS", address(0));
        if (bytes(rpc).length == 0 || nvda == address(0)) {
            emit log("SKIP: set BNB_RPC_URL and NVDAX_ADDRESS to run the real-NVDA fork test");
            return;
        }

        vm.createSelectFork(rpc);
        assertEq(block.chainid, 56, "fork must be BNB mainnet");

        RamMiningBeaconFactory factory = new RamMiningBeaconFactory();
        uint256 basePrice = 0.001 ether;
        uint256 seasonEnd = block.timestamp + 30 days;
        bytes memory vaultData = abi.encode(nvda, PANCAKE_ROUTER, basePrice, seasonEnd);

        vm.prank(BNB_MAINNET_VAULT_PORTAL);
        address vaultAddr = factory.newVault(RAM_TOKEN, address(0), address(this), vaultData);
        RamMiningVaultUpgradeable vault = RamMiningVaultUpgradeable(payable(vaultAddr));

        // a miner buys power
        address miner = address(0xA11CE);
        vm.deal(miner, 1 ether);
        vm.prank(miner);
        vault.buyMiningContract{value: basePrice}(0);

        // simulate BNB fees arriving, then deploy into REAL NVDA via PancakeSwap
        vm.deal(vaultAddr, 1 ether);
        vm.prank(GUARDIAN_MAINNET);
        uint256 out = vault.deployToReward(0.5 ether, 0); // 0 minOut: liquidity-dependent
        assertGt(out, 0, "should receive real NVDA from the swap");

        // miner can claim real NVDA
        assertGt(vault.pendingRewards(miner), 0);
        vm.prank(miner);
        uint256 got = vault.claimRewards();
        assertEq(IERC20(nvda).balanceOf(miner), got);
        assertGt(got, 0);
    }
}
