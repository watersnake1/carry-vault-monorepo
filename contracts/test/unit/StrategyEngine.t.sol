// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }           from "forge-std/Test.sol";
import { StrategyEngine } from "../../src/core/StrategyEngine.sol";

contract StrategyEngineTest is Test {

    StrategyEngine internal se;
    address internal admin = address(0xAD);
    address internal user  = address(0xBE);

    address internal vaultCoreAddr       = address(0x1);
    address internal positionManagerAddr = address(0x2);
    address internal oracleLayerAddr     = address(0x3);
    address internal riskManagerAddr     = address(0x4);

    bytes32 internal constant WTI = keccak256("WTI-USDC");
    bytes32 internal constant ETH = keccak256("ETH-USDC");
    bytes32 internal constant BTC = keccak256("BTC-USDC");

    function setUp() public {
        se = new StrategyEngine(
            vaultCoreAddr,
            positionManagerAddr,
            oracleLayerAddr,
            riskManagerAddr,
            admin
        );
    }

    /* ─── Constructor and defaults ─── */

    function test_constructorSetsImmutableRefs() public {
        assertEq(se.vaultCore(),       vaultCoreAddr);
        assertEq(se.positionManager(), positionManagerAddr);
        assertEq(se.oracleLayer(),     oracleLayerAddr);
        assertEq(se.riskManager(),     riskManagerAddr);
    }

    function test_constructorDefaultsToWtiPerp() public {
        assertEq(se.configuredPerpMarket(), WTI);
        assertEq(se.currentPerpMarket(),    WTI);
    }

    function test_constructorExcludesHypeByDefault() public {
        bytes32 hypeHash = keccak256(bytes("HYPE"));
        assertTrue(se.excludedBaseAssets(hypeHash));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(StrategyEngine.ZeroAddress.selector);
        new StrategyEngine(address(0), positionManagerAddr, oracleLayerAddr, riskManagerAddr, admin);

        vm.expectRevert(StrategyEngine.ZeroAddress.selector);
        new StrategyEngine(vaultCoreAddr, address(0), oracleLayerAddr, riskManagerAddr, admin);

        vm.expectRevert(StrategyEngine.ZeroAddress.selector);
        new StrategyEngine(vaultCoreAddr, positionManagerAddr, oracleLayerAddr, riskManagerAddr, address(0));
    }

    /* ─── currentPerpMarket() and admin setter ─── */

    function test_setConfiguredPerpMarket() public {
        vm.prank(admin);
        se.setConfiguredPerpMarket(ETH);

        assertEq(se.configuredPerpMarket(), ETH);
        assertEq(se.currentPerpMarket(),    ETH);
    }

    function test_setConfiguredPerpMarketEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit StrategyEngine.ConfiguredPerpMarketChanged(WTI, ETH);

        vm.prank(admin);
        se.setConfiguredPerpMarket(ETH);
    }

    function test_setConfiguredPerpMarketRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(StrategyEngine.ZeroBytes32.selector);
        se.setConfiguredPerpMarket(bytes32(0));
    }

    function test_setConfiguredPerpMarketOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();    // OZ AccessControl reverts with its own error
        se.setConfiguredPerpMarket(ETH);
    }

    /* ─── Whitelist management ─── */

    function test_whitelistMarket() public {
        vm.prank(admin);
        se.whitelistMarket(
            ETH,
            StrategyEngine.MarketTier.TIER_1,
            StrategyEngine.AssetClass.CRYPTO,
            address(0)
        );

        assertEq(se.getWhitelistLength(), 1);
        assertTrue(se.isMarketWhitelisted(ETH));

        StrategyEngine.MarketEntry memory entry = se.getMarketEntry(ETH);
        assertEq(entry.marketId,             ETH);
        assertEq(uint8(entry.tier),          uint8(StrategyEngine.MarketTier.TIER_1));
        assertEq(uint8(entry.assetClass),    uint8(StrategyEngine.AssetClass.CRYPTO));
        assertEq(entry.deployer,             address(0));
        assertGt(entry.whitelistedAt,        0);
        assertTrue(entry.active);
    }

    function test_whitelistMarketEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit StrategyEngine.MarketWhitelisted(
            ETH,
            StrategyEngine.MarketTier.TIER_1,
            StrategyEngine.AssetClass.CRYPTO,
            address(0)
        );

        vm.prank(admin);
        se.whitelistMarket(
            ETH,
            StrategyEngine.MarketTier.TIER_1,
            StrategyEngine.AssetClass.CRYPTO,
            address(0)
        );
    }

    function test_whitelistMarketRejectsDuplicate() public {
        vm.startPrank(admin);
        se.whitelistMarket(ETH, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));

        vm.expectRevert(abi.encodeWithSelector(
            StrategyEngine.MarketAlreadyWhitelisted.selector, ETH
        ));
        se.whitelistMarket(ETH, StrategyEngine.MarketTier.TIER_2, StrategyEngine.AssetClass.EQUITY, address(0));
        vm.stopPrank();
    }

    function test_whitelistMarketRejectsZeroId() public {
        vm.prank(admin);
        vm.expectRevert(StrategyEngine.ZeroBytes32.selector);
        se.whitelistMarket(
            bytes32(0),
            StrategyEngine.MarketTier.TIER_1,
            StrategyEngine.AssetClass.CRYPTO,
            address(0)
        );
    }

    function test_whitelistMarketOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        se.whitelistMarket(ETH, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));
    }

    function test_whitelistMultipleMarkets() public {
        vm.startPrank(admin);
        se.whitelistMarket(ETH, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));
        se.whitelistMarket(BTC, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));
        vm.stopPrank();

        assertEq(se.getWhitelistLength(), 2);
        assertTrue(se.isMarketWhitelisted(ETH));
        assertTrue(se.isMarketWhitelisted(BTC));
    }

    /* ─── Unwhitelist ─── */

    function test_unwhitelistMarket() public {
        vm.startPrank(admin);
        se.whitelistMarket(ETH, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));
        se.unwhitelistMarket(ETH);
        vm.stopPrank();

        assertEq(se.getWhitelistLength(), 0);
        assertFalse(se.isMarketWhitelisted(ETH));

        // Entry preserved with active = false
        StrategyEngine.MarketEntry memory entry = se.getMarketEntry(ETH);
        assertEq(entry.marketId, ETH);
        assertFalse(entry.active);
    }

    function test_unwhitelistMarketRejectsUnknown() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            StrategyEngine.MarketNotWhitelisted.selector, ETH
        ));
        se.unwhitelistMarket(ETH);
    }

    function test_unwhitelistMarketCompactsArray() public {
        vm.startPrank(admin);
        se.whitelistMarket(ETH, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));
        se.whitelistMarket(BTC, StrategyEngine.MarketTier.TIER_1, StrategyEngine.AssetClass.CRYPTO, address(0));
        // Remove the first one; array should compact (BTC moves into slot 0)
        se.unwhitelistMarket(ETH);
        vm.stopPrank();

        assertEq(se.getWhitelistLength(), 1);
        assertEq(se.whitelistedMarketIds(0), BTC);
    }

    /* ─── Excluded base assets ─── */

    function test_setExcludedBaseAsset() public {
        bytes32 ethHash = keccak256(bytes("ETH"));

        vm.prank(admin);
        se.setExcludedBaseAsset(ethHash, true);

        assertTrue(se.excludedBaseAssets(ethHash));
    }

    function test_unsetExcludedBaseAsset() public {
        bytes32 hypeHash = keccak256(bytes("HYPE"));

        // HYPE is excluded by default; unsetting should work via admin
        vm.prank(admin);
        se.setExcludedBaseAsset(hypeHash, false);

        assertFalse(se.excludedBaseAssets(hypeHash));
    }

    function test_setExcludedBaseAssetEmitsEvent() public {
        bytes32 ethHash = keccak256(bytes("ETH"));

        vm.expectEmit(true, false, false, true);
        emit StrategyEngine.BaseAssetExclusionSet(ethHash, true);

        vm.prank(admin);
        se.setExcludedBaseAsset(ethHash, true);
    }

    function test_setExcludedBaseAssetRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(StrategyEngine.ZeroBytes32.selector);
        se.setExcludedBaseAsset(bytes32(0), true);
    }

    function test_setExcludedBaseAssetOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        se.setExcludedBaseAsset(keccak256(bytes("ETH")), true);
    }
}