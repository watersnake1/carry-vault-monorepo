// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { AccessControl }   from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  StrategyEngine
/// @notice V1: manages a single configured perp market on HyperCore (default WTI/USDC).
///         V2: adds the multi-pair scout (rank/select/rotate across the whitelist).
/// @dev    Aligned to Strategy Overview v0.3 and Technical Spec v0.3 (Option C).
///         See Technical Spec §2.2, §3.1 (scout, V2), §3.3 (cascade callbacks).
contract StrategyEngine is AccessControl, ReentrancyGuard {

    /* ─────────────────────────── Enums ─────────────────────────── */

    /// @dev Side of a perp position relative to the underlying.
    enum PerpSide { LONG, SHORT }

    /// @dev Whitelist tier. TIER_1 = native HyperCore deep markets.
    ///      TIER_2 = HIP-3 markets with sustained liquidity.
    enum MarketTier { EXCLUDED, TIER_1, TIER_2 }

    /// @dev Drives vol-ceiling lookup and depth multipliers (Risk Framework §3.2).
    enum AssetClass { CRYPTO, EQUITY, COMMODITY, FX }

    /* ─────────────────────────── Structs ─────────────────────────── */

    /// @notice Whitelisted market metadata.
    struct MarketEntry {
        bytes32     marketId;
        MarketTier  tier;
        AssetClass  assetClass;
        address     deployer;       // 0x0 for native HyperCore; non-zero for HIP-3
        uint64      whitelistedAt;  // for HIP-3 "must age in" rule
        bool        active;
    }

    /// @notice One slot in the V2 scout's target portfolio. Reserved for future use.
    struct PortfolioPosition {
        bytes32   marketId;
        PerpSide  side;
        uint16    weightBps;        // share of funding-leg notional (sum to 10000)
        uint64    enteredAt;
    }

    /// @notice V2 hysteresis tracking. Reserved for future use.
    struct HysteresisState {
        bytes32   challengerMarket;
        PerpSide  challengerSide;
        uint256   challengerScore;
        uint64    challengeStartedAt;
    }

    /* ─────────────────────────── Constants ─────────────────────────── */

    // V2 scout parameters (Risk Framework §3.2, §3.1.1). Defined now so the
    // data model is stable; consumed by V2 scout logic in subsequent commits.
    uint16 public constant HYSTERESIS_SCORE_ADVANTAGE_BPS = 2500;
    uint64 public constant HYSTERESIS_TIME_WINDOW_SEC     = 4 hours;
    uint64 public constant FUNDING_SIGN_PERSISTENCE_SEC   = 8 hours;
    uint64 public constant COOLDOWN_AFTER_STRESS_SEC      = 24 hours;
    uint64 public constant MAX_HOLDING_PERIOD_SEC         = 7 days;
    uint16 public constant MIN_NET_CARRY_BPS              = 300;     // 3% APR
    uint16 public constant MIN_OI_PCT_BPS                 = 100;     // 1%
    uint16 public constant MAX_OI_PCT_TIER1_BPS           = 500;     // 5%
    uint16 public constant MAX_OI_PCT_TIER2_BPS           = 300;     // 3%
    uint16 public constant VOL_CEILING_CRYPTO_BPS         = 15000;
    uint16 public constant VOL_CEILING_EQUITY_BPS         = 6000;
    uint16 public constant VOL_CEILING_COMMODITY_BPS      = 8000;
    uint16 public constant VOL_CEILING_FX_BPS             = 2500;
    uint64 public constant HIP3_MIN_AGE_SEC               = 30 days;
    uint16 public constant BPS_DENOM                      = 10000;

    /* ─────────── Immutable peer refs ─────────── */
    address public immutable vaultCore;
    address public immutable positionManager;
    address public immutable oracleLayer;
    address public immutable riskManager;

    /* ─────────────────────────── Storage ─────────────────────────── */

    /// @notice The perp market the vault opens at deposit. V1 admin-settable
    ///         (single market for all users). V2 will have the scout select
    ///         from the whitelist instead of using a configured value.
    bytes32 public configuredPerpMarket;

    /// @notice Whitelist of markets the V2 scout may select from. For V1 the
    ///         configured market may but does not have to appear in this list.
    bytes32[] public whitelistedMarketIds;
    mapping(bytes32 => MarketEntry) public marketEntries;
    mapping(bytes32 => bool)        public excludedBaseAssets;  // key = keccak256(symbol)

    /// @notice V2 scout state. Populated by evaluateFundingLeg() in subsequent commits.
    PortfolioPosition[] public currentPortfolio;
    uint64 public lastScoutEvaluationAt;
    HysteresisState public hysteresis;

    /// @notice Total notional currently allocated across HIP-3 deployers.
    ///         Updated by PositionManager via calls reserved for V2.
    mapping(address => uint256) public deployerNotionalUsd;

    /// @notice Per-user post-stress lockout. Set by RiskManager during cascade.
    mapping(address => uint64) public userCooldownUntil;

    /* ─────────────────────────── Events ─────────────────────────── */

    // Configured market
    event ConfiguredPerpMarketChanged(bytes32 indexed previousMarketId, bytes32 indexed newMarketId);

    // Cascade callbacks (perp-leg lifecycle, called by RiskManager)
    event PerpLegReduceTriggered(address indexed user, uint16 percentBps);
    event PerpLegCloseTriggered(address indexed user);

    // Scout (V2)
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

    /* ─────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error ZeroBytes32();
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

    /* ─────────────────────────── Constructor ─────────────────────────── */

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

        // V1 default: WTI/USDC. Admin can change via setConfiguredPerpMarket.
        configuredPerpMarket = keccak256("WTI-USDC");

        // HYPE always excluded from any perp leg the strategy may take
        // (Strategy Overview v0.3 — perp leg is non-HYPE only).
        bytes32 hypeAssetHash = keccak256(bytes("HYPE"));
        excludedBaseAssets[hypeAssetHash] = true;
        emit BaseAssetExclusionSet(hypeAssetHash, true);
    }

    /* ─────────────────────────── Modifiers ─────────────────────────── */

    modifier onlyVaultCore() {
        if (msg.sender != vaultCore) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyRiskManager() {
        if (msg.sender != riskManager) revert UnauthorizedCaller(msg.sender);
        _;
    }

    /* ─────────────────────────── V1 entry points ─────────────────────────── */

    /// @notice The perp market opened at deposit. Read by VaultCore.depositWithProfile.
    function currentPerpMarket() external view returns (bytes32) {
        return configuredPerpMarket;
    }

    /* ─────────────────────────── Admin ─────────────────────────── */

    /// @notice Change the configured V1 perp market. Should only be invoked
    ///         when there are no active positions, or all active positions are
    ///         on the new market — VaultCore does not migrate existing
    ///         positions when this changes.
    function setConfiguredPerpMarket(bytes32 newMarketId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newMarketId == bytes32(0)) revert ZeroBytes32();
        bytes32 previous = configuredPerpMarket;
        configuredPerpMarket = newMarketId;
        emit ConfiguredPerpMarketChanged(previous, newMarketId);
    }

    /// @notice Add a market to the V2 scout whitelist.
    function whitelistMarket(
        bytes32     marketId,
        MarketTier  tier,
        AssetClass  assetClass,
        address     deployer
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (marketId == bytes32(0))                           revert ZeroBytes32();
        if (marketEntries[marketId].active)                   revert MarketAlreadyWhitelisted(marketId);

        marketEntries[marketId] = MarketEntry({
            marketId:      marketId,
            tier:          tier,
            assetClass:    assetClass,
            deployer:      deployer,
            whitelistedAt: uint64(block.timestamp),
            active:        true
        });
        whitelistedMarketIds.push(marketId);

        emit MarketWhitelisted(marketId, tier, assetClass, deployer);
    }

    /// @notice Remove a market from the V2 scout whitelist. The market entry
    ///         is preserved (with active = false) so historical references
    ///         remain valid.
    function unwhitelistMarket(bytes32 marketId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        MarketEntry storage entry = marketEntries[marketId];
        if (!entry.active) revert MarketNotWhitelisted(marketId);

        entry.active = false;

        // Compact whitelistedMarketIds array
        uint256 len = whitelistedMarketIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (whitelistedMarketIds[i] == marketId) {
                if (i != len - 1) {
                    whitelistedMarketIds[i] = whitelistedMarketIds[len - 1];
                }
                whitelistedMarketIds.pop();
                break;
            }
        }

        emit MarketUnwhitelisted(marketId);
    }

    /// @notice Toggle exclusion of a base asset from any perp leg the strategy
    ///         may take. HYPE is excluded by default in the constructor.
    function setExcludedBaseAsset(bytes32 baseAssetHash, bool excluded)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (baseAssetHash == bytes32(0)) revert ZeroBytes32();
        excludedBaseAssets[baseAssetHash] = excluded;
        emit BaseAssetExclusionSet(baseAssetHash, excluded);
    }

    /* ─────────────────────────── Views ─────────────────────────── */

    function getWhitelistLength() external view returns (uint256) {
        return whitelistedMarketIds.length;
    }

    function isMarketWhitelisted(bytes32 marketId) external view returns (bool) {
        return marketEntries[marketId].active;
    }

    function getMarketEntry(bytes32 marketId) external view returns (MarketEntry memory) {
        return marketEntries[marketId];
    }

    /* ─────────────────────────────────────────────────────────────────────
       Function stubs — implementations come in subsequent commits.
       ───────────────────────────────────────────────────────────────────

       Cascade callbacks (called by RiskManager during stress):
         function reducePerpLeg(address user, uint16 percentBps) external onlyRiskManager;
         function closePerpLegFull(address user) external onlyRiskManager;
         function setUserCooldown(address user, uint64 until) external onlyRiskManager;

       V2 scout (called by KeeperBot via VaultCore.rebalance()):
         function evaluatePerpRotation() external returns (bytes32 newMarketId);
         function _rankCandidateMarkets(...) internal returns (...);
         function _respectsHysteresis(bytes32 challenger, uint256 score) internal view returns (bool);
         function _computeNetCarryBps(bytes32 marketId, uint256 positionUsd) internal view returns (int256);

       Helpers:
         function _isCooldownActive(address user) internal view returns (bool);
       ─────────────────────────────────────────────────────────────── */
}