// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title OracleLayer
/// @notice Reads HyperCore's native precompile for funding rates, marks, oracle
///         prices, and OI. Computes TWAPs used by the rebalance trigger.
/// @dev See Technical Spec §2.2 and §3.1.
contract OracleLayer {
    address public immutable hyperCoreAdapter;

    uint64 public constant STALE_THRESHOLD_SEC = 60;
    uint64 public lastReadAt;

    struct MarketSnapshot {
        bytes32 marketId;
        uint256 markPx;             // 1e18 fixed-point
        int256  fundingHourly;      // signed 1e18 fixed-point (decimal, e.g. 24e12 = 0.0024%)
        uint256 openInterestUsd;
        uint64  observedAt;
    }

    mapping(bytes32 => MarketSnapshot) public latest;
    mapping(bytes32 => int256[]) internal fundingHistory;   // ring buffer per market

    event Refreshed(uint64 timestamp, uint256 marketsUpdated);

    constructor(address _hyperCoreAdapter) {
        hyperCoreAdapter = _hyperCoreAdapter;
    }

    /// @notice Pulls latest values from HyperCore for all whitelisted markets.
    function refresh() external {
        // TODO: call into HyperCoreAdapter.readAll() and write to `latest`
        // TODO: append to fundingHistory ring buffers
        // TODO: update lastReadAt
        // TODO: emit Refreshed
    }

    function isStale() public view returns (bool) {
        return (block.timestamp - lastReadAt) > STALE_THRESHOLD_SEC;
    }

    /// @notice 8-hour TWAP of funding for a given market.
    function fundingTwap(bytes32 marketId, uint64 windowSec) external view returns (int256) {
        // TODO: compute time-weighted average from fundingHistory
    }

    function realizedVol90d(bytes32 marketId) external view returns (uint256) {
        // TODO: computed from price history (separate buffer); std dev of log returns annualized
    }
}