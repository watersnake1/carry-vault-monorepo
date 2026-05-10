// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/* ─────────────────────────────────────────────────────────────────────────
   Minimal peer interfaces — used by LTV/health reads in subsequent commits.
   For now the stubs short-circuit before calling these.
   ──────────────────────────────────────────────────────────────────────── */

interface IVaultCoreMin {
    // Resolves the user's chosen risk profile. Will be wired up when VaultCore
    // exposes a typed getUserPosition() getter (Group 5 in the function list).
    function getUserRiskProfile(address user) external view returns (uint8);
    function getUserSpotReserveBalance(address user)  external view returns (uint256);
    function updateSpotReserve(address user, uint256 newBalance) external;
    function forceClose(address user) external;
}

interface IPositionManagerMin {
    function getPerpNotionalUsd(address user)        external view returns (uint256);
    function getPerpMarginEquityUsd(address user)    external view returns (uint256);
    function getHyperLendCollateralValue(address user) external view returns (uint256);
    function getHyperLendDebt(address user)          external view returns (uint256);
    function getPerpMarketId(address user)             external view returns (bytes32);

    function swapHypeToUsdc(uint256 hypeAmount)                          external returns (uint256);
    function depositToPerpMargin(address user, uint256 usdcAmount)       external;
    function closePerpPositionPartial(address user, uint16 percentBps)   external;
}

interface IOracleLayerMin {
    function maintenanceMarginBps(bytes32 marketId) external view returns (uint16);
}

/// @title  RiskManager
/// @notice Owns profile parameters, LTV/health computation, and the stress
///         cascade. Read by VaultCore at deposit and by KeeperBot during
///         rebalance.
/// @dev    Aligned to Technical Spec v0.3 §6 (health computation) and §4 (cascade).
contract RiskManager is AccessControl {

    /* ─────────────────────────── Enums ─────────────────────────── */

    enum Profile { Conservative, Risky }
    enum Stage   { None, A, B, C }

    /* ─────────────────────────── Structs ─────────────────────────── */

    /// @notice All profile-driven risk parameters in one place. Set in
    ///         constructor; mutable by admin via setProfileParams.
    struct ProfileParams {
        // HyperLend (lending leg)
        uint16 hyperLendTargetLtvBps;        // 3000 / 5000
        uint16 hyperLendAutoDeleverageBps;   // 4500 / 6000
        uint16 hyperLendHardLiquidationBps;  // 5500 / 6500

        // Perp (yield leg)
        uint32 perpEffectiveLeverageBps;     // 50000 (5x) / 100000 (10x)
        uint16 liquidationDistanceFloorBps;  // 1500 / 800
        uint16 liquidationDistanceStageABps; // 2000 / 1200 — Stage A trigger

        // Allocation
        uint16 reserveSplitBps;              // 1500 / 500

        // Cascade thresholds (health-factor terms; 10000 = 1.0)
        uint16 cascadeTriggerHealthBps;      // 10500 = 1.05
        uint16 safeHealthTargetBps;          // 12000 = 1.20
    }

    /* ─────────────────────────── Constants ─────────────────────────── */

    uint256 public constant BPS_DENOM = 10000;
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant STAGE_A_CHUNK_HYPE = 5e17;   // 0.5 HYPE per replenish chunk
    uint16  public constant STAGE_B_CHUNK_BPS  = 2500;   // close 25% of notional per chunk

    /* ─────────── Immutable peer refs ─────────── */
    address public vaultCore;
    address public immutable positionManager;
    address public immutable oracleLayer;
    bool public initialized;

    /* ─────────────────────────── Storage ─────────────────────────── */

    mapping(uint8 => ProfileParams) internal _profiles;

    /* ─────────────────────────── Events ─────────────────────────── */

    event ProfileParamsUpdated(uint8 indexed profile, ProfileParams params);
    event CascadeStageEntered(address indexed user, Stage stage, uint256 healthBefore);
    event CascadeStageCompleted(address indexed user, Stage stage, uint256 healthAfter);
    event CascadeForceClose(address indexed user);


    error PerpNoLongerUnsafe();   // optional, used only as a guardrail

    modifier onlyAuthorizedCascade() {
        if (msg.sender != vaultCore && !hasRole(KEEPER_ROLE, msg.sender)) {
            revert UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /* ─────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error UnknownProfile(uint8 profile);
    error InvalidProfileParams();
    error UnauthorizedCaller(address caller);
    error CascadeNotImplemented();
    event Initialized(address vaultCore);
    
    error AlreadyInitialized();

    /* ─────────────────────────── Constructor ─────────────────────────── */

    constructor(address _positionManager, address _oracleLayer) {
        if (_positionManager == address(0)) revert ZeroAddress();
        if (_oracleLayer     == address(0)) revert ZeroAddress();

        positionManager = _positionManager;
        oracleLayer     = _oracleLayer;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Conservative — sized to survive ~15% adverse perp move (Risk Framework §2)
        _profiles[uint8(Profile.Conservative)] = ProfileParams({
            hyperLendTargetLtvBps:        3000,    // 30%
            hyperLendAutoDeleverageBps:   4500,    // 45%
            hyperLendHardLiquidationBps:  5500,    // 55%
            perpEffectiveLeverageBps:     50000,   // 5x
            liquidationDistanceFloorBps:  1500,    // 15%
            liquidationDistanceStageABps: 2000,    // 20%
            reserveSplitBps:              1500,    // 15%
            cascadeTriggerHealthBps:      10500,   // 1.05
            safeHealthTargetBps:          12000    // 1.20
        });

        // Risky — sized to survive ~8% adverse perp move (Risk Framework §2)
        _profiles[uint8(Profile.Risky)] = ProfileParams({
            hyperLendTargetLtvBps:        5000,    // 50%
            hyperLendAutoDeleverageBps:   6000,    // 60%
            hyperLendHardLiquidationBps:  6500,    // 65%
            perpEffectiveLeverageBps:     100000,  // 10x
            liquidationDistanceFloorBps:  800,     // 8%
            liquidationDistanceStageABps: 1200,    // 12%
            reserveSplitBps:              500,     // 5%
            cascadeTriggerHealthBps:      10500,   // 1.05
            safeHealthTargetBps:          12000    // 1.20
        });
    }

    function initialize(address _vaultCore) external {
        if (initialized)              revert AlreadyInitialized();
        if (_vaultCore == address(0)) revert ZeroAddress();
        vaultCore   = _vaultCore;
        initialized = true;
        emit Initialized(_vaultCore);
    }

    /* ─────────────────────────── Profile getters ─────────────────────────── */

    function getProfileParams(uint8 profile) external view returns (ProfileParams memory) {
        if (profile > uint8(Profile.Risky)) revert UnknownProfile(profile);
        return _profiles[profile];
    }

    function getPerpLeverageForProfile(uint8 profile) external view returns (uint32) {
        if (profile > uint8(Profile.Risky)) revert UnknownProfile(profile);
        return _profiles[profile].perpEffectiveLeverageBps;
    }

    function getReserveSplitForProfile(uint8 profile) external view returns (uint16) {
        if (profile > uint8(Profile.Risky)) revert UnknownProfile(profile);
        return _profiles[profile].reserveSplitBps;
    }

    function getHyperLendTargetLtv(uint8 profile) external view returns (uint16) {
        if (profile > uint8(Profile.Risky)) revert UnknownProfile(profile);
        return _profiles[profile].hyperLendTargetLtvBps;
    }

    /* ─────────────────────────── Admin ─────────────────────────── */

    function setProfileParams(uint8 profile, ProfileParams calldata params)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (profile > uint8(Profile.Risky)) revert UnknownProfile(profile);
        if (params.hyperLendAutoDeleverageBps  <= params.hyperLendTargetLtvBps)        revert InvalidProfileParams();
        if (params.hyperLendHardLiquidationBps <= params.hyperLendAutoDeleverageBps)   revert InvalidProfileParams();
        if (params.liquidationDistanceStageABps <= params.liquidationDistanceFloorBps) revert InvalidProfileParams();
        if (params.safeHealthTargetBps         <= params.cascadeTriggerHealthBps)      revert InvalidProfileParams();
        if (params.perpEffectiveLeverageBps == 0)                                       revert InvalidProfileParams();

        _profiles[profile] = params;
        emit ProfileParamsUpdated(profile, params);
    }

    /* ─────────────────────────── LTV / health views ─────────────────────────── */

    /// @notice HyperLend leg LTV in basis points (10000 = 100%).
    function hyperLendLtv(address user) public view returns (uint256 bps) {
        uint256 collateral = IPositionManagerMin(positionManager).getHyperLendCollateralValue(user);
        if (collateral == 0) return 0;

        uint256 debt = IPositionManagerMin(positionManager).getHyperLendDebt(user);
        return (debt * BPS_DENOM) / collateral;
    }

    /// @notice Perp leg effective leverage in basis points (10000 = 1x).
    function perpEffectiveLeverage(address user) public view returns (uint256 bps) {
        uint256 margin = IPositionManagerMin(positionManager).getPerpMarginEquityUsd(user);
        if (margin == 0) return 0;

        uint256 notional = IPositionManagerMin(positionManager).getPerpNotionalUsd(user);
        return (notional * BPS_DENOM) / margin;
    }

    /// @notice Perp leg liquidation distance in basis points of mark.
    ///         Computed as (margin − mmRequirement) × 10000 / notional.
    function perpLiquidationDistance(address user) public view returns (uint256 bps) {
        uint256 notional = IPositionManagerMin(positionManager).getPerpNotionalUsd(user);
        uint256 margin   = IPositionManagerMin(positionManager).getPerpMarginEquityUsd(user);
        if (notional == 0 || margin == 0) return 0;

        bytes32 marketId = IPositionManagerMin(positionManager).getPerpMarketId(user);
        uint16 mmBps     = IOracleLayerMin(oracleLayer).maintenanceMarginBps(marketId);

        uint256 mmRequirement = (notional * uint256(mmBps)) / BPS_DENOM;
        if (margin <= mmRequirement) return 0;

        uint256 safety = margin - mmRequirement;
        return (safety * BPS_DENOM) / notional;
    }

    /// @notice Combined health factor across both legs. Higher = safer.
    ///         10000 = at threshold, > 10000 = safe, < 10000 = below threshold.
    /// @dev    Composition is real; the leaf reads are stubs. As leaves get
    ///         implemented this returns increasingly accurate values.
    function combinedHealth(address user) public view returns (uint256 healthBps) {
        Profile p = _userProfile(user);
        ProfileParams memory params = _profiles[uint8(p)];

        uint256 ltv = hyperLendLtv(user);
        uint256 lendHealth;
        if (ltv == 0) {
            lendHealth = type(uint256).max;
        } else {
            lendHealth = (uint256(params.hyperLendHardLiquidationBps) * BPS_DENOM) / ltv;
        }

        uint256 perpNotional = IPositionManagerMin(positionManager).getPerpNotionalUsd(user);
        uint256 perpHealth;
        if (perpNotional == 0 || params.liquidationDistanceFloorBps == 0) {
            perpHealth = type(uint256).max;     // no perp position → no perp risk
        } else {
            uint256 dist = perpLiquidationDistance(user);
            perpHealth = (dist * BPS_DENOM) / uint256(params.liquidationDistanceFloorBps);
        }

        healthBps = lendHealth < perpHealth ? lendHealth : perpHealth;
    }

    /// @notice Whether the user's combined health requires cascade activation.
    function requiresCascade(address user) external view returns (bool) {
        Profile p = _userProfile(user);
        return combinedHealth(user) < uint256(_profiles[uint8(p)].cascadeTriggerHealthBps);
    }

    /// @notice Convenience view for the dashboard — returns all metrics at once.
    function getHealthSnapshot(address user) external view returns (
        uint256 hyperLendLtvBps,
        uint256 perpLeverageBps,
        uint256 liquidationDistanceBps,
        uint256 healthBps,
        bool    cascadeRequired
    ) {
        hyperLendLtvBps        = hyperLendLtv(user);
        perpLeverageBps        = perpEffectiveLeverage(user);
        liquidationDistanceBps = perpLiquidationDistance(user);
        healthBps              = combinedHealth(user);

        uint256 trigger = uint256(_profiles[uint8(_userProfile(user))].cascadeTriggerHealthBps);
        cascadeRequired = healthBps < trigger;
    }

    /* ─────────────────────────── Cascade (stub) ─────────────────────────── */

    /// @notice Run the stress cascade for a user. See Technical Spec §3.3.
    /// @dev    Stub — full implementation requires PositionManager + StrategyEngine
    ///         cascade callbacks (closePerpLeg, reducePerpLeg, repayHyperLend, etc.)
    ///         to be wired up first.
    function executeCascade(address user) external onlyAuthorizedCascade {
        Profile p = _userProfile(user);
        ProfileParams memory params = _profiles[uint8(p)];
        uint256 target     = uint256(params.safeHealthTargetBps);
        uint256 floor      = uint256(params.liquidationDistanceFloorBps);
        uint256 targetDist = (target * floor) / BPS_DENOM;

        uint256 healthBefore = combinedHealth(user);

        // Stage A — replenish margin if perp could still be improved
        if (_perpCouldBeImproved(user, targetDist)) {
            emit CascadeStageEntered(user, Stage.A, healthBefore);
            _executeStageA(user, targetDist);
            emit CascadeStageCompleted(user, Stage.A, combinedHealth(user));
        }
        if (combinedHealth(user) >= target) return;

        // Stage B — partial close if perp still has room
        if (_perpCouldBeImproved(user, targetDist)) {
            emit CascadeStageEntered(user, Stage.B, combinedHealth(user));
            _executeStageB(user, targetDist);
            emit CascadeStageCompleted(user, Stage.B, combinedHealth(user));
        }
        if (combinedHealth(user) >= target) return;

        // Stage C — force close (lending leg is the bottleneck, or all margin/notional exhausted)
        emit CascadeStageEntered(user, Stage.C, combinedHealth(user));
        IVaultCoreMin(vaultCore).forceClose(user);
        emit CascadeForceClose(user);
    }

    function _perpCouldBeImproved(address user, uint256 targetDist) internal view returns (bool) {
        uint256 notional = IPositionManagerMin(positionManager).getPerpNotionalUsd(user);
        if (notional == 0) return false;
        return perpLiquidationDistance(user) < targetDist;
    }

    function _executeStageA(address user, uint256 targetDist) internal {
        uint256 reserve = IVaultCoreMin(vaultCore).getUserSpotReserveBalance(user);

        while (reserve > 0 && perpLiquidationDistance(user) < targetDist) {
            uint256 chunkHype = reserve < STAGE_A_CHUNK_HYPE ? reserve : STAGE_A_CHUNK_HYPE;

            uint256 usdc = IPositionManagerMin(positionManager).swapHypeToUsdc(chunkHype);
            IPositionManagerMin(positionManager).depositToPerpMargin(user, usdc);

            reserve -= chunkHype;
            IVaultCoreMin(vaultCore).updateSpotReserve(user, reserve);
        }
    }

    function _executeStageB(address user, uint256 targetDist) internal {
        while (perpLiquidationDistance(user) < targetDist) {
            uint256 notional = IPositionManagerMin(positionManager).getPerpNotionalUsd(user);
            if (notional == 0) break;
            IPositionManagerMin(positionManager).closePerpPositionPartial(user, STAGE_B_CHUNK_BPS);
        }
    }

    /* ─────────────────────────── Internal helpers ─────────────────────────── */

    /// @dev Resolves the user's chosen risk profile from VaultCore.
    ///      Stub returns Conservative until VaultCore exposes a typed getter.
    function _userProfile(address user) internal view returns (Profile) {
        // TODO: return Profile(IVaultCoreMin(vaultCore).getUserRiskProfile(user))
        uint8 raw = IVaultCoreMin(vaultCore).getUserRiskProfile(user);
        return Profile(raw);    
    }
}