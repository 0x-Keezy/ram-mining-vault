// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @title FlapDeployed
/// @notice Returns the deployed VaultPortal address for each supported chain
library FlapDeployed {
    /// @notice Returns the VaultPortal address for the current chain
    /// @return The VaultPortal contract address
    function vaultPortal() public view returns (address) {
        uint256 chainId = block.chainid;

        // BNB Mainnet
        if (chainId == 56) {
            return 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
        }

        // BNB Testnet
        if (chainId == 97) {
            return 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        }

        revert("FlapDeployed: unsupported chain");
    }
}
