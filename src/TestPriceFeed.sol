// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TestPriceFeed
/// @notice Minimal AggregatorV3-compatible price feed mock (8 decimals) for BNB TESTNET only. BNB testnet has no
///         Chainlink NVDA/USD feed (stock feeds are mainnet-only), so the vault is wired to these mocks for the
///         launch smoke test. `latestRoundData()` always returns a fresh `updatedAt` (block.timestamp) so the
///         vault's staleness checks pass, and the answer is settable so ops can simulate price moves on testnet.
/// @dev    TESTNET ONLY — mainnet wires real Chainlink NVDA/USD and BNB/USD feeds via the factory's vaultData.
contract TestPriceFeed {
    uint8 public immutable decimals;
    int256 private _answer;
    uint80 private _round;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        _answer = answer_;
        _round = 1;
    }

    /// @notice Set a fresh answer (bumps the round). Open on testnet so ops can exercise price moves.
    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _round += 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_round, _answer, block.timestamp, block.timestamp, _round);
    }
}
