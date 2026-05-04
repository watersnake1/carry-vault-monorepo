// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { AccessControl }   from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { VaultCore }       from "./VaultCore.sol";

/// @title  StrategyEngine
/// @notice Two sub-strategies: a fixed HYPE perp leg (set at deposit, locked for
///         the life of the loan) and a dynamic funding-rate scout that rotates
///         across non-HYPE HyperCore markets selected by risk-adjusted carry.
/// @dev    See Technical Spec §2.2, §3.1 (scout), §3.2 (rebalance trigger),
///         and Risk Framework §3.1–3.3 (entry/exit conditions).
contract StrategyEngine is AccessControl, ReentrancyGuard {

    /* ─────────────────────────────────────────────────────────────────────
       Enums
       ─────────────────────────────────────────────────────────────────── */

    /// @dev Side of the perp position relative to the underlying.
    enum PerpSide { LONG, SHORT }

    /// @dev Whitelist tier for the funding-leg scout.
    ///      TIER_1 = deep, established HyperCore-native pairs (BTC, ETH, SOL, ...).
    ///      TIER_2 = whitelisted HIP-3 markets with sustained liquidity.
    enum MarketTier { EXCLUDED, TIER_1, TIER_2 }

    /// @dev Asset class drives vol-ceiling lookup at entry (Risk Framework §3.2).
    enum AssetClass { CRYPTO, EQUITY, COMMODITY, FX }

    /* ─────────────────────────────────────────────────────────────────────
       Structs
       ─────────────────────────────────────────────────────────────────── */

    /// @notice Whitelisted market metadata.
    struct MarketEntry {
        bytes32     marketId;
        MarketTier  tier;
        AssetClass  assetClass;
        address     deployer;       // 0x0 for native HyperCore; non-zero for HIP-3
        uint64      whitelistedAt;  // for HIP-3 "must age in" rule
        bool        active;
    }

    /// @notice One slot in the scout's current target portfolio. All users'
    ///         funding-leg margin is split across this portfolio proportionally.
    struct PortfolioPosition {
        bytes32   marketId;
        PerpSide  side;
        uint16    weightBps;        // share of funding-leg notional (sums to 10000)
        uint64    enteredAt;
    }

    /// @notice Tracks how long a challenger market has been beating the current
    ///         portfolio's worst slot. See Technical Spec §3.1.1.
    struct HysteresisState {
        bytes32   challengerMarket;
        PerpSide  challengerSide;
        uint256   challengerScore;
        uint64    challengeStartedAt;
    }

    /* ─────────────────────────────────────────────────────────────────────
       Constants — entry conditions and risk caps
       Numeric values are first-pass; final values come from backtest
       calibration (Risk Framework §9 open items).
       ─────────────────────────────────────────────────────────────────── */

    // Hysteresis (Technical Spec §3.1.1)
    uint16 public constant HYSTERESIS_SCORE_ADVANTAGE_BPS = 2500;   // 25% advantage required
    uint64 public constant HYSTERESIS_TIME_WINDOW_SEC     = 4 hours;
    uint64 public constant FUNDING_SIGN_PERSISTENCE_SEC   = 8 hours;
    uint64 public constant COOLDOWN_AFTER_STRESS_SEC      = 24 hours;
    uint64 public constant MAX_HOLDING_PERIOD_SEC         = 7 days;  // force re-eval

    // Net carry threshold (Risk Framework §3.2)
    uint16 public constant MIN_NET_CARRY_BPS              = 300;     // 3% APR after costs

    // OI bands (Risk Framework §3.1)
    uint16 public constant MIN_OI_PCT_BPS                 = 100;     // 1% of market OI
    uint16 public constant MAX_OI_PCT_TIER1_BPS           = 500;     // 5% for native HyperCore
    uint16 public constant MAX_OI_PCT_TIER2_BPS           = 300;     // 3% for HIP-3

    // Vol ceilings at entry (Risk Framework §3.2)
    uint16 public constant VOL_CEILING_CRYPTO_BPS         = 15000;   // 150% annualized
    uint16 public constant VOL_CEILING_EQUITY_BPS         = 6000;    // 60%
    uint16 public constant VOL_CEILING_COMMODITY_BPS      = 8000;    // 80%
    uint16 public constant VOL_CEILING_FX_BPS             = 2500;    // 25%

    // HIP-3 specific
    uint16 public constant DEPTH_FACTOR_HIP3_BPS          = 15000;   // 1.5x slippage multiplier
    uint64 public constant HIP3_MIN_AGE_SEC               = 30 days; // age-in requirement

    // Per-profile caps (Risk Framework §2)
    uint8  public constant MAX_CONCURRENT_POSITIONS_CONSERVATIVE        = 2;
    uint8  public constant MAX_CONCURRENT_POSITIONS_RISKY               = 4;
    uint16 public constant SINGLE_PAIR_CONCENTRATION_CONSERVATIVE_BPS   = 4000;  // 40%
    uint16 public constant SINGLE_PAIR_CONCENTRATION_RISKY_BPS          = 6000;  // 60%
    uint16 public constant PER_DEPLOYER_CAP_CONSERVATIVE_BPS            = 2500;  // 25%
    uint16 public constant PER_DEPLOYER_CAP_RISKY_BPS                   = 4000;  // 40%

    uint16 public constant BPS_DENOM                      = 10000;

    /* ─────────────────────────────────────────────────────────────────────
       Immutable peer-contract references
       Auth for inter-contract calls is by address comparison rather than
       AccessControl roles — cheaper and clearer for one-to-one trust.
       ─────────────────────────────────────────────────────────────────── */

    address public immutable vaultCore;
    address public immutable positionManager;
    address public immutable oracleLayer;
    address public immutable riskManager;

    /* ─────────────────────────────────────────────────────────────────────
       Storage — whitelist
       ─────────────────────────────────────────────────────────────────── */

    /// @notice Whitelisted market IDs the scout can rotate into. Iterable via
    ///         length getter; entries indexed by `marketEntries[id]`.
    bytes32[] public whitelistedMarketIds;

    /// @notice Per-market metadata.
    mapping(bytes32 => MarketEntry) public marketEntries;

    /// @notice Base assets the funding leg is forbidden from entering. HYPE
    ///         is added in the constructor; admin can extend the set.
    /// @dev    Key is keccak256(bytes(symbol)) e.g. keccak256("HYPE").
    mapping(bytes32 => bool) public excludedBaseAssets;

    /* ─────────────────────────────────────────────────────────────────────
       Storage — scout state
       ─────────────────────────────────────────────────────────────────── */

    /// @notice Current scout-selected target portfolio. All active users'
    ///         funding-leg margin is allocated across this portfolio. A single
    ///         shared portfolio rather than per-user is the V1/V2 simplification;
    ///         per-user portfolios are V3 work (Sharpe-weighted sizing).
    PortfolioPosition[] public currentPortfolio;

    /// @notice Last time the scout evaluated and updated currentPortfolio.
    uint64 public lastScoutEvaluationAt;

    /// @notice Hysteresis tracking for the next-best rotation candidate.
    HysteresisState public hysteresis;

    /* ─────────────────────────────────────────────────────────────────────
       Storage — caps and cooldowns
       ─────────────────────────────────────────────────────────────────── */

    /// @notice Total notional currently allocated to each HIP-3 deployer
    ///         across the entire vault. Used to enforce per-deployer caps
    ///         on portfolio rotations.
    mapping(address => uint256) public deployerNotionalUsd;

    /// @notice Per-user post-stress lockout. While `block.timestamp 
    ///         userCooldownUntil[user]`, the user's funding leg stays flat.
    mapping(address => uint64) public userCooldownUntil;

    /* ─────────────────────────────────────────────────────────────────────
       Events
       ─────────────────────────────────────────────────────────────────── */

    // Lifecycle (HYPE leg is opened/managed via PositionManager; these events
    // fire when StrategyEngine *decides* an action, before delegation.)
    event HypeLegOpenTriggered(
        address indexed user,
        VaultCore.HypeLegDirection direction,
        uint256 marginUsd,
        uint16  leverageBps
    );
    event HypeLegReduceTriggered(address indexed user, uint16 percentBps);

    // Scout
    event FundingLegEvaluated(uint64 timestamp, uint256 candidatesEvaluated);
    event PortfolioRotated(bytes32[] removedMarkets, bytes32[] addedMarkets);
    event HysteresisChallengerSet(bytes32 indexed marketId, PerpSide side, uint256 score);
    event HysteresisChallengerCleared();

    // Whitelist admin
    event MarketWhitelisted(bytes32 indexed marketId, MarketTier tier, AssetClass class, address deployer);
    event MarketUnwhitelisted(bytes32 indexed marketId);
    event BaseAssetExclusionSet(bytes32 indexed baseAssetHash, bool excluded);

    // Caps and cooldowns
    event UserCooldownSet(address indexed user, uint64 until);
    event DeployerNotionalUpdated(address indexed deployer, uint256 notional);

    /* ─────────────────────────────────────────────────────────────────────
       Custom errors
       ─────────────────────────────────────────────────────────────────── */

    error ZeroAddress();
    error UnauthorizedCaller(address caller);

    error MarketNotWhitelisted(bytes32 marketId);
    error MarketAlreadyWhitelisted(bytes32 marketId);
    error MarketNotActive(bytes32 marketId);
    error MarketNotAged(bytes32 marketId, uint64 whitelistedAt);
    error BaseAssetIsExcluded(bytes32 baseAssetHash);

    error VolCeilingExceeded(bytes32 marketId, uint256 vol);
    error ConcentrationCeilingExceeded(bytes32 marketId, uint16 weightBps);
    error DeployerCapExceeded(address deployer, uint256 currentNotional);
    error InsufficientCarry(int256 netCarryBps);
    error InvalidPortfolioWeights(uint256 totalBps);
    error TooManyConcurrentPositions(uint256 supplied, uint256 max);

    error HysteresisNotMet(uint256 currentScore, uint256 challengerScore);
    error HysteresisChallengerStale(uint64 challengerStartedAt, uint64 nowTs);
    error CooldownActive(address user, uint64 until);

    /* ─────────────────────────────────────────────────────────────────────
       Constructor
       ─────────────────────────────────────────────────────────────────── */

    /// @param _vaultCore       VaultCore contract address.
    /// @param _positionManager PositionManager contract address.
    /// @param _oracleLayer     OracleLayer contract address.
    /// @param _riskManager     RiskManager contract address.
    /// @param admin            Multisig holding DEFAULT_ADMIN_ROLE for whitelist mgmt.
    constructor(
        address _vaultCore,
        address _positionManager,
        address _oracleLayer,
        address _riskManager,
        address admin
    ) {
        if (_vaultCore       == address(0)) revert ZeroAddress();
        if (_positionManager == address(0)) revert ZeroAddress();
        if (_oracleLayer     == address(0)) revert ZeroAddress();
        if (_riskManager     == address(0)) revert ZeroAddress();
        if (admin            == address(0)) revert ZeroAddress();

        vaultCore       = _vaultCore;
        positionManager = _positionManager;
        oracleLayer     = _oracleLayer;
        riskManager     = _riskManager;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // HYPE always excluded from the funding leg (Strategy Overview v0.2,
        // and confirmed in Risk Framework §1.2).
        bytes32 hypeAssetHash = keccak256(bytes("HYPE"));
        excludedBaseAssets[hypeAssetHash] = true;
        emit BaseAssetExclusionSet(hypeAssetHash, true);
    }

    /* ─────────────────────────────────────────────────────────────────────
       Modifiers
       ─────────────────────────────────────────────────────────────────── */

    modifier onlyVaultCore() {
        if (msg.sender != vaultCore) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyRiskManager() {
        if (msg.sender != riskManager) revert UnauthorizedCaller(msg.sender);
        _;
    }

    // functions start here
    function openHypeLeg(address /*user*/, uint8 /*direction*/, uint256 /*marginHype*/, uint16 /*leverageBps*/) external onlyVaultCore {
    // TODO: validate against RiskManager, instruct PositionManager. See Spec §3.
    }

    function activateUserFundingLeg(address /*user*/, uint256 /*marginHype*/) external onlyVaultCore {
    // TODO: allocate user's funding margin across currentPortfolio.
    }

    /* ─────────────────────────────────────────────────────────────────────
       Function stubs — implementations come in subsequent commits.
       ───────────────────────────────────────────────────────────────────

       Called by VaultCore at deposit:
         function openHypeLeg(
             address user,
             VaultCore.HypeLegDirection direction,
             uint256 marginUsd,
             uint16  leverageBps
         ) external onlyVaultCore;

       Called by VaultCore.rebalance() (keeper-driven):
         function evaluateFundingLeg() external returns (PortfolioPosition[] memory);

       Called by RiskManager during cascade:
         function closeFundingLeg(address user) external onlyRiskManager;        // Stage A
         function reduceHypeLeg(address user, uint256 percentBps) external onlyRiskManager;  // Stage B

       Called by RiskManager after stress events:
         function setUserCooldown(address user, uint64 until) external onlyRiskManager;

       Admin (DEFAULT_ADMIN_ROLE):
         function whitelistMarket(
             bytes32     marketId,
             MarketTier  tier,
             AssetClass  class,
             address     deployer
         ) external;
         function unwhitelistMarket(bytes32 marketId) external;
         function setExcludedBaseAsset(bytes32 baseAssetHash, bool excluded) external;
         function triggerScoutEvaluation() external;     // emergency manual trigger

       Internal (helpers):
         function _rankCandidateMarkets(...) internal returns (...);              // Spec §3.1
         function _respectsHysteresis(bytes32 challenger, uint256 score) internal view returns (bool);
         function _computeNetCarryBps(bytes32 marketId, uint256 positionUsd) internal view returns (int256);
         function _isCooldownActive(address user) internal view returns (bool);

       Views:
         function getCurrentPortfolio() external view returns (PortfolioPosition[] memory);
         function getWhitelistLength() external view returns (uint256);
         function getMarketEntry(bytes32 marketId) external view returns (MarketEntry memory);
       ─────────────────────────────────────────────────────────────── */
}