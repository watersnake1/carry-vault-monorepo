// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }        from "forge-std/Test.sol";
import { OracleLayer } from "../../src/core/OracleLayer.sol";

contract OracleLayerTest is Test {

    OracleLayer internal ol;
    address internal admin  = address(this);
    address internal feeder = address(0xFEED);
    address internal user   = address(0xBE);

    bytes32 internal constant WTI = keccak256("WTI-USDC");
    bytes32 internal constant ETH = keccak256("ETH-USDC");

    function setUp() public {
        ol = new OracleLayer(address(0xCAFE));
        ol.grantRole(ol.ORACLE_FEEDER_ROLE(), feeder);
    }

    /* ─────────── Constructor ─────────── */

    function test_constructorSetsAdapter() public {
        assertEq(ol.hyperCoreAdapter(), address(0xCAFE));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(OracleLayer.ZeroAddress.selector);
        new OracleLayer(address(0));
    }

    function test_constructorInitializesHypePrice() public {
        // 40 * 1e18 = 40e18
        assertEq(ol.hypePriceUsdE18(), 40 * 1e18);
    }

    function test_constructorGrantsAdminAndFeeder() public {
        assertTrue(ol.hasRole(ol.DEFAULT_ADMIN_ROLE(),  admin));
        assertTrue(ol.hasRole(ol.ORACLE_FEEDER_ROLE(),  admin));
    }

    /* ─────────── updateMarketData ─────────── */

    function test_updateMarketDataHappyPath() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, int256(24e12), 2000, 500, 1_000_000 * 1e18);

        OracleLayer.MarketData memory m = ol.getMarketData(WTI);
        assertEq(m.markPriceE18,         70 * 1e18);
        assertEq(m.fundingHourlyE18,     int256(24e12));
        assertEq(m.initialMarginBps,     2000);
        assertEq(m.maintenanceMarginBps, 500);
        assertEq(m.openInterestUsdE18,   1_000_000 * 1e18);
        assertGt(m.lastUpdate,           0);
    }

    function test_updateMarketDataRejectsZeroPrice() public {
        vm.prank(feeder);
        vm.expectRevert(OracleLayer.InvalidPrice.selector);
        ol.updateMarketData(WTI, 0, 0, 2000, 500, 0);
    }

    function test_updateMarketDataRejectsZeroIM() public {
        vm.prank(feeder);
        vm.expectRevert(OracleLayer.InvalidMarginParams.selector);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 0, 0, 0);
    }

    function test_updateMarketDataRejectsImEqualsMm() public {
        vm.prank(feeder);
        vm.expectRevert(OracleLayer.InvalidMarginParams.selector);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 500, 500, 0);
    }

    function test_updateMarketDataRejectsImAboveBpsDenom() public {
        vm.prank(feeder);
        vm.expectRevert(OracleLayer.InvalidMarginParams.selector);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 10001, 500, 0);
    }

    function test_updateMarketDataOnlyFeeder() public {
        vm.prank(user);
        vm.expectRevert();   // OZ AccessControl reverts
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
    }

    /* ─────────── updateMark ─────────── */

    function test_updateMarkExistingMarket() public {
        vm.startPrank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, int256(24e12), 2000, 500, 0);
        skip(5);
        ol.updateMark(WTI, 75 * 1e18, int256(30e12));
        vm.stopPrank();

        OracleLayer.MarketData memory m = ol.getMarketData(WTI);
        assertEq(m.markPriceE18,         75 * 1e18);
        assertEq(m.fundingHourlyE18,     int256(30e12));
        // IM/MM unchanged
        assertEq(m.initialMarginBps,     2000);
        assertEq(m.maintenanceMarginBps, 500);
    }

    function test_updateMarkRejectsUnknownMarket() public {
        vm.prank(feeder);
        vm.expectRevert(abi.encodeWithSelector(OracleLayer.UnknownMarket.selector, ETH));
        ol.updateMark(ETH, 1 * 1e18, 0);
    }

    function test_updateMarkRejectsZeroPrice() public {
        vm.startPrank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        vm.expectRevert(OracleLayer.InvalidPrice.selector);
        ol.updateMark(WTI, 0, 0);
        vm.stopPrank();
    }

    /* ─────────── HYPE price ─────────── */

    function test_setHypePrice() public {
        vm.prank(feeder);
        ol.setHypePrice(50 * 1e18);
        assertEq(ol.hypePriceUsdE18(), 50 * 1e18);
        // 50 * 1e18 / 1e12 = 50 * 1e6
        assertEq(ol.hypePriceUsdc(),   50 * 1e6);
    }

    function test_setHypePriceRejectsZero() public {
        vm.prank(feeder);
        vm.expectRevert(OracleLayer.InvalidPrice.selector);
        ol.setHypePrice(0);
    }

    function test_setHypePriceOnlyFeeder() public {
        vm.prank(user);
        vm.expectRevert();
        ol.setHypePrice(50 * 1e18);
    }

    function test_hypePriceUsdcDefault() public {
        // Default $40 → 40 * 1e6 USDC units
        assertEq(ol.hypePriceUsdc(), 40 * 1e6);
    }

    /* ─────────── Per-market views ─────────── */

    function test_markPriceView() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        assertEq(ol.markPrice(WTI), 70 * 1e18);
    }

    function test_fundingHourlyView() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, int256(24e12), 2000, 500, 0);
        assertEq(ol.fundingHourly(WTI), int256(24e12));
    }

    function test_fundingAprE18Math() public {
        // 0.0024% per hour = 24e12 in 1e18 fraction
        // Annual = 24e12 * 8760 = 2.1024e17 (= 21.024%)
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, int256(24e12), 2000, 500, 0);

        int256 apr = ol.fundingAprE18(WTI);
        assertEq(apr, int256(210_240_000_000_000_000));
    }

    function test_fundingAprNegative() public {
        // -0.001%/hour = -10e12. Annual = -8.76e16 (= -8.76%)
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, int256(-10e12), 2000, 500, 0);

        int256 apr = ol.fundingAprE18(WTI);
        assertEq(apr, int256(-87_600_000_000_000_000));
    }

    function test_maintenanceMarginBpsView() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        assertEq(ol.maintenanceMarginBps(WTI), 500);
    }

    function test_initialMarginBpsView() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        assertEq(ol.initialMarginBps(WTI), 2000);
    }

    function test_openInterestView() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 5_000_000 * 1e18);
        assertEq(ol.openInterestUsd(WTI), 5_000_000 * 1e18);
    }

    function test_unknownMarketReturnsZero() public {
        // Mapping default = zeroed struct
        assertEq(ol.markPrice(ETH),                 0);
        assertEq(ol.fundingHourly(ETH),             int256(0));
        assertEq(ol.maintenanceMarginBps(ETH),      uint16(0));
        assertEq(ol.openInterestUsd(ETH),           0);
    }

    /* ─────────── Staleness ─────────── */

    function test_isStaleNeverUpdatedReturnsTrue() public {
        assertTrue(ol.isStale(ETH));
    }

    function test_isStaleFreshReturnsFalse() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        assertFalse(ol.isStale(WTI));
    }

    function test_isStaleAtThresholdReturnsFalse() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        skip(60);   // exactly at threshold; > 60 is stale, == 60 is not
        assertFalse(ol.isStale(WTI));
    }

    function test_isStalePastThresholdReturnsTrue() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, 0, 2000, 500, 0);
        skip(61);
        assertTrue(ol.isStale(WTI));
    }

    /* ─────────── TWAP stub ─────────── */

    function test_fundingTwapStubReturnsCurrent() public {
        vm.prank(feeder);
        ol.updateMarketData(WTI, 70 * 1e18, int256(24e12), 2000, 500, 0);
        assertEq(ol.fundingTwap(WTI, 8 hours), int256(24e12));
    }
}