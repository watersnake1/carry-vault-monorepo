// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  OracleLayer
/// @notice Reads market data (marks, funding, IM/MM, open interest) for
///         HyperCore markets. V1 uses admin-fed values; V2 reads from the
///         HyperCore precompile via hyperCoreAdapter.
/// @dev    Aligned to Technical Spec v0.3.
///
///         Fixed-point conventions:
///           - markPriceE18:     USD × 1e18  (e.g., $40 = 40 * 1e18)
///           - fundingHourlyE18: signed 1e18 fraction (e.g., 0.0024% = 24e12)
///           - margins (BPS):    10000 = 100%
///
///         Annualized funding APR is computed as hourly rate × 8760.
contract OracleLayer is AccessControl {

    /* ─────────────────────────── Roles ─────────────────────────── */

    bytes32 public constant ORACLE_FEEDER_ROLE = keccak256("ORACLE_FEEDER_ROLE");

    /* ─────────────────────────── Constants ─────────────────────────── */

    uint64  public constant STALE_THRESHOLD_SEC = 60;
    uint256 public constant BPS_DENOM            = 10000;

    /// @dev int256 to keep multiplication signed throughout.
    int256  public constant HOURS_PER_YEAR       = 8760;

    /* ─────────────────────────── Structs ─────────────────────────── */

    struct MarketData {
        uint256 markPriceE18;
        int256  fundingHourlyE18;
        uint16  initialMarginBps;
        uint16  maintenanceMarginBps;
        uint256 openInterestUsdE18;
        uint64  lastUpdate;
    }

    /* ─────────────────────────── Immutable ─────────────────────────── */

    address public immutable hyperCoreAdapter;

    /* ─────────────────────────── Storage ─────────────────────────── */

    mapping(bytes32 => MarketData) internal _markets;

    /// @notice HYPE price in USD * 1e18. V1 stub default is $40.
    uint256 public hypePriceUsdE18;

    /* ─────────────────────────── Events ─────────────────────────── */

    event MarketDataUpdated(
        bytes32 indexed marketId,
        uint256 markPriceE18,
        int256  fundingHourlyE18,
        uint16  initialMarginBps,
        uint16  maintenanceMarginBps,
        uint256 openInterestUsdE18
    );
    event MarkUpdated(bytes32 indexed marketId, uint256 markPriceE18, int256 fundingHourlyE18);
    event HypePriceUpdated(uint256 newPriceE18);

    /* ─────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error UnknownMarket(bytes32 marketId);
    error InvalidMarginParams();
    error InvalidPrice();

    /* ─────────────────────────── Constructor ─────────────────────────── */

    constructor(address _hyperCoreAdapter) {
        if (_hyperCoreAdapter == address(0)) revert ZeroAddress();
        hyperCoreAdapter = _hyperCoreAdapter;

        _grantRole(DEFAULT_ADMIN_ROLE,  msg.sender);
        _grantRole(ORACLE_FEEDER_ROLE,  msg.sender);

        // V1 default — matches PositionManager and YieldRouter stubs ($40).
        hypePriceUsdE18 = 40 * 1e18;
    }

    /* ─────────────────────────── Admin / feeder ─────────────────────────── */

    /// @notice Set or replace all data for a market in one call.
    function updateMarketData(
        bytes32 marketId,
        uint256 markPriceE18_,
        int256  fundingHourlyE18_,
        uint16  initialMarginBps_,
        uint16  maintenanceMarginBps_,
        uint256 openInterestUsdE18_
    )
        external
        onlyRole(ORACLE_FEEDER_ROLE)
    {
        if (markPriceE18_ == 0)                                 revert InvalidPrice();
        if (initialMarginBps_ == 0)                             revert InvalidMarginParams();
        if (initialMarginBps_ > BPS_DENOM)                      revert InvalidMarginParams();
        if (initialMarginBps_ <= maintenanceMarginBps_)         revert InvalidMarginParams();

        _markets[marketId] = MarketData({
            markPriceE18:         markPriceE18_,
            fundingHourlyE18:     fundingHourlyE18_,
            initialMarginBps:     initialMarginBps_,
            maintenanceMarginBps: maintenanceMarginBps_,
            openInterestUsdE18:   openInterestUsdE18_,
            lastUpdate:           uint64(block.timestamp)
        });

        emit MarketDataUpdated(
            marketId,
            markPriceE18_,
            fundingHourlyE18_,
            initialMarginBps_,
            maintenanceMarginBps_,
            openInterestUsdE18_
        );
    }

    /// @notice Update only the most-frequently-changing fields (mark + funding).
    function updateMark(bytes32 marketId, uint256 markPriceE18_, int256 fundingHourlyE18_)
        external
        onlyRole(ORACLE_FEEDER_ROLE)
    {
        if (markPriceE18_ == 0) revert InvalidPrice();

        MarketData storage m = _markets[marketId];
        if (m.lastUpdate == 0) revert UnknownMarket(marketId);

        m.markPriceE18     = markPriceE18_;
        m.fundingHourlyE18 = fundingHourlyE18_;
        m.lastUpdate       = uint64(block.timestamp);

        emit MarkUpdated(marketId, markPriceE18_, fundingHourlyE18_);
    }

    /// @notice Update the HYPE price reference.
    function setHypePrice(uint256 priceUsdE18) external onlyRole(ORACLE_FEEDER_ROLE) {
        if (priceUsdE18 == 0) revert InvalidPrice();
        hypePriceUsdE18 = priceUsdE18;
        emit HypePriceUpdated(priceUsdE18);
    }

    /* ─────────────────────────── Views — per-market ─────────────────────────── */

    function markPrice(bytes32 marketId) external view returns (uint256) {
        return _markets[marketId].markPriceE18;
    }

    function fundingHourly(bytes32 marketId) external view returns (int256) {
        return _markets[marketId].fundingHourlyE18;
    }

    /// @notice Annualized funding rate in 1e18 fraction. Positive = longs pay shorts.
    /// @dev    hourly × 8760. For 0.0024%/h (24e12) → 2.1024e17 (= 21.024%).
    function fundingAprE18(bytes32 marketId) external view returns (int256) {
        return _markets[marketId].fundingHourlyE18 * HOURS_PER_YEAR;
    }

    function maintenanceMarginBps(bytes32 marketId) external view returns (uint16) {
        return _markets[marketId].maintenanceMarginBps;
    }

    function initialMarginBps(bytes32 marketId) external view returns (uint16) {
        return _markets[marketId].initialMarginBps;
    }

    function openInterestUsd(bytes32 marketId) external view returns (uint256) {
        return _markets[marketId].openInterestUsdE18;
    }

    function lastUpdate(bytes32 marketId) external view returns (uint64) {
        return _markets[marketId].lastUpdate;
    }

    function isStale(bytes32 marketId) external view returns (bool) {
        uint64 ts = _markets[marketId].lastUpdate;
        if (ts == 0) return true;
        return (uint64(block.timestamp) - ts) > STALE_THRESHOLD_SEC;
    }

    function getMarketData(bytes32 marketId) external view returns (MarketData memory) {
        return _markets[marketId];
    }

    /// @notice TWAP of funding rate over the given window.
    /// @dev    V1 stub: returns the current rate. Production stores per-hour
    ///         samples in a circular buffer and returns the time-weighted
    ///         average over the window.
    function fundingTwap(bytes32 marketId, uint64 /*windowSec*/)
        external
        view
        returns (int256)
    {
        return _markets[marketId].fundingHourlyE18;
    }

    /* ─────────────────────────── Views — HYPE ─────────────────────────── */

    /// @notice HYPE price in USDC native units (6 decimals).
    function hypePriceUsdc() external view returns (uint256) {
        return hypePriceUsdE18 / 1e12;
    }
}