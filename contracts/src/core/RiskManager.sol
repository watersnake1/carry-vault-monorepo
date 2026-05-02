// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title RiskManager
/// @notice Owns the canonical LTV definitions and runs the stress cascade.
/// @dev See Technical Spec §6 (LTV computation) and §4 (cascade).
contract RiskManager {
    address public immutable vaultCore;
    address public immutable positionManager;
    address public immutable oracleLayer;

    enum Stage { None, A, B, C }
    enum Profile { Conservative, Risky }

    struct ProfileParams {
        uint16 hypeLegLeverageBps;          // 15000 / 30000
        uint16 fundingLegLeverageBps;
        uint16 targetUserFacingLtvBps;      // 3000 / 5000
        uint16 autoDeleverageTriggerBps;    // 4500 / 6000
        uint16 hardLiquidationCapBps;       // 5500 / 6500
        uint8  maxConcurrentFundingPositions;
    }

    mapping(uint8 => ProfileParams) public profiles;

    event CascadeStageEntered(address indexed user, Stage stage, uint256 ltvBefore);
    event CascadeStageCompleted(address indexed user, Stage stage, uint256 ltvAfter);

    constructor(address _vaultCore, address _positionManager, address _oracleLayer) {
        vaultCore = _vaultCore;
        positionManager = _positionManager;
        oracleLayer = _oracleLayer;
        // TODO: initialize default profile parameter sets per Risk Framework §2
    }

    // ─── LTV view functions (Technical Spec §6) ──────────────────────────────
    function userFacingLtv(address user) external view returns (uint256 bps) { /* TODO */ }
    function protocolLtv(address user)   external view returns (uint256 bps) { /* TODO */ }
    function combinedEconomicLtv(address user) external view returns (uint256 bps) { /* TODO */ }

    // ─── Cascade (Technical Spec §3.3) ───────────────────────────────────────
    function executeCascade(address user) external {
        // TODO: Stage A — instruct PositionManager.closeFundingLeg
        // TODO: Stage B — instruct PositionManager.reduceHypeLeg in 25% chunks
        // TODO: Stage C — instruct PositionManager.sellHypeSpot, repay loans, force-close user
    }

    // Pre-flight check used by StrategyEngine before opening positions.
    function validatePositionOpen(address user, uint256 newPositionUsd, Profile profile) external view returns (bool) {
        // TODO: enforce concentration ceilings, OI caps, vol ceiling
    }
}