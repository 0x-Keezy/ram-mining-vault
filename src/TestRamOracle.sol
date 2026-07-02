// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TestRamOracle
/// @notice TESTNET-ONLY IRamPriceOracle mock: a fixed, settable RAM price (BNB wei per 1e18 RAM) with a trust
///         flag. Lets a test vault run the Phase-2 economy (RAM-paid rigs/repairs/upgrades) without the real
///         market oracle. NEVER deploy to production — the production RamPriceOracle reads the live pair/curve.
contract TestRamOracle {
    uint256 public price;
    bool public trusted;

    constructor(uint256 _price) {
        price = _price;
        trusted = true;
    }

    /// @dev Open setter (testnet-only) so UI states (trusted/degraded) can be exercised.
    function set(uint256 _price, bool _trusted) external {
        price = _price;
        trusted = _trusted;
    }

    function pokeAndGetPrice(address) external view returns (uint256, bool) {
        return (price, trusted);
    }

    function getPrice(address) external view returns (uint256, bool) {
        return (price, trusted);
    }
}
