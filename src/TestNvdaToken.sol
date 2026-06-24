// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @title TestNvdaToken
/// @notice Mock tokenized-NVIDIA reward token for BNB testnet (chain 97), where no real NVDAx exists.
///         Free-transfer, 18 decimals, mintable — stands in for xStocks NVDAx while iterating on testnet.
///         On mainnet, point the RAM vault at the real NVDAx address instead.
contract TestNvdaToken is ERC20 {
    constructor() ERC20("Test Tokenized NVIDIA", "tNVDA") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
