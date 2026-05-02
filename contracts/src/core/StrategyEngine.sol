// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title StrategyEngine
/// @notice Manages two sub-strategies: a fixed HYPE perp leg (set at deposit) and
///         a dynamic funding-rate scout that rotates across non-HYPE HyperCore
///         markets selected by risk-adjusted carry.
/// @dev See Technical Spec §3.1 (funding scout) and §3.2 (rebalance trigger).
contract StrategyEngine {
    address public immutable vaultCore;
    address public immutable positionManager;
    address public immutable oracleLayer;
    address public immutable riskManager;

    enum HypeLegDirection { None, Long, Short }

    event HypeLegOpened(address indexed user, HypeLegDirection direction, uint256 marginUsd, uint16 leverageBps);
    event FundingLegRotated(address indexed user, bytes32 indexed fromMarket, bytes32 indexed toMarket);

    constructor(address _vaultCore, address _positionManager, address _oracleLayer, address _riskManager) {
        vaultCore = _vaultCore;
        positionManager = _positionManager;
        oracleLayer = _oracleLayer;
        riskManager = _riskManager;
    }

    // Called by VaultCore at deposit; opens the user-chosen HYPE leg.
    function openHypeLeg(address user, HypeLegDirection direction, uint256 marginUsd, uint16 leverageBps) external {
        // TODO: validate inputs against RiskManager caps (Technical Spec §6)
        // TODO: instruct PositionManager to open the HyperCore perp
        // TODO: emit HypeLegOpened
    }

    // Called by KeeperBot via VaultCore.rebalance(); returns target funding-leg state.
    function evaluateFundingLeg(address user) external returns (bytes32[] memory targetMarkets) {
        // TODO: rank candidate markets per Technical Spec §3.1
        // TODO: apply hysteresis vs current positions (§3.1.1)
    }

    // Cascade-only entry points (Risk Manager invokes these).
    function closeFundingLeg(address user) external { /* TODO: §4.1 Stage A */ }
    function reduceHypeLeg(address user, uint256 percentBps) external { /* TODO: §4.2 Stage B */ }
}