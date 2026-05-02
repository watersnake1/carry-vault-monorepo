// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IAdapter
/// @notice Common interface implemented by all third-party protocol adapters
///         (HyperLend, Sentiment, HyperSwap, HyperCore). Lets PositionManager
///         treat venues uniformly. See Technical Spec §7.3.
interface IAdapter {
    function venue() external view returns (string memory);
    function isHealthy() external view returns (bool);
}