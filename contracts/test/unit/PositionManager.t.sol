// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }            from "forge-std/Test.sol";
import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PositionManager } from "../../src/core/PositionManager.sol";
import { OracleLayer } from "../../src/core/OracleLayer.sol";


contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PositionManagerTest is Test {

    PositionManager internal pm;
    MockToken internal hype;
    MockToken internal usdc;

    address internal vaultCore   = address(0xCA11);
    address internal riskManager = address(0xBA88);
    //address internal oracle      = address(0xA);
    OracleLayer internal oracleLayer;
    address internal user        = address(0xBE);

    bytes32 internal constant WTI = keccak256("WTI-USDC");

    function setUp() public {
        hype = new MockToken("HYPE", "HYPE");
        usdc = new MockToken("USDC", "USDC");

        oracleLayer = new OracleLayer(address(0xA)); 
        pm = new PositionManager(address(oracleLayer), address(hype), address(usdc));
        pm.initialize(vaultCore, riskManager);

        // Fund VaultCore with HYPE and grant unlimited approval to PM,
        // emulating what VaultCore's constructor does.
        hype.mint(vaultCore, 1000 ether);
        vm.prank(vaultCore);
        hype.approve(address(pm), type(uint256).max);
    }

    /* ─────────── Constructor and initialization ─────────── */

    function test_constructorSetsImmutables() public {
        assertEq(pm.oracleLayer(),  address(oracleLayer));
        assertEq(address(pm.hype()), address(hype));
        assertEq(address(pm.usdc()), address(usdc));
    }

    function test_constructorRejectsZeros() public {
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManager(address(0), address(hype), address(usdc));

        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManager(address(oracleLayer), address(0), address(usdc));

        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManager(address(oracleLayer), address(hype), address(0));
    }

    function test_initializeSetsRefs() public {
        PositionManager fresh = new PositionManager(address(oracleLayer), address(hype), address(usdc));
        fresh.initialize(vaultCore, riskManager);
        assertEq(fresh.vaultCore(),   vaultCore);
        assertEq(fresh.riskManager(), riskManager);
        assertTrue(fresh.initialized());
    }

    function test_initializeRejectsDouble() public {
        vm.expectRevert(PositionManager.AlreadyInitialized.selector);
        pm.initialize(vaultCore, riskManager);
    }

    function test_callsRevertBeforeInitialize() public {
        PositionManager fresh = new PositionManager(address(oracleLayer), address(hype), address(usdc));
        vm.expectRevert(PositionManager.NotInitialized.selector);
        fresh.supplyToHyperLendAndBorrow(user, 1 ether, 3000);
    }

    /* ─────────── supplyToHyperLendAndBorrow ─────────── */

    function test_supplyToHyperLendAndBorrowMath() public {
        // 63.75 HYPE × $40 = $2,550 collateral. At 30% LTV → $765 borrowed.
        vm.prank(vaultCore);
        uint256 borrowed = pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);

        assertEq(borrowed, 765e6, "765 USDC borrowed");

        PositionManager.LendingLegState memory leg = pm.getLendingLegState(user);
        assertEq(leg.hypeSupplied, 63.75 ether);
        assertEq(leg.usdcBorrowed, 765e6);

        assertEq(hype.balanceOf(address(pm)), 63.75 ether, "HYPE moved to PM");
        assertEq(pm.totalHypeOnHyperLend(),    63.75 ether);
        assertEq(pm.totalUsdcDebt(),           765e6);
    }

    function test_supplyToHyperLendAndBorrowOnlyVaultCore() public {
        vm.expectRevert(abi.encodeWithSelector(
            PositionManager.UnauthorizedCaller.selector, address(this)
        ));
        pm.supplyToHyperLendAndBorrow(user, 1 ether, 3000);
    }

    function test_supplyToHyperLendAndBorrowRejectsZero() public {
        vm.prank(vaultCore);
        vm.expectRevert(PositionManager.ZeroAmount.selector);
        pm.supplyToHyperLendAndBorrow(user, 0, 3000);
    }

    /* ─────────── openPerpLegAndExtractMargin ─────────── */

    function test_openPerpLegConservativeMath() public {
        // 21.25 HYPE × $40 = $850 margin. Open at 2x → $1,700 notional.
        // Target 5x → reservedMargin = $850 × 2/5 = $340. Withdrawn = $510.
        vm.prank(vaultCore);
        uint256 withdrawn = pm.openPerpLegAndExtractMargin(user, WTI, 21.25 ether, 50000);

        assertEq(withdrawn, 510e6, "510 USDC margin withdrawn");

        PositionManager.PerpLegState memory leg = pm.getPerpLegState(user);
        assertEq(leg.marketId,             WTI);
        assertEq(leg.side,                 2,        "short for funding capture");
        assertEq(leg.marginUsd,            340e6,    "$340 retained as margin");
        assertEq(leg.notionalUsd,          1700e6,   "$1700 notional");
        assertEq(leg.effectiveLeverageBps, 50000,    "5x effective leverage");
        assertTrue(leg.isOpen);

        assertEq(pm.totalPerpNotionalUsd(), 1700e6);
        assertEq(pm.totalPerpMarginUsd(),   340e6);
    }

    function test_openPerpLegRiskyMath() public {
        // 23.75 HYPE × $40 = $950 margin. Open at 2x → $1,900 notional.
        // Target 10x → reservedMargin = $950 × 2/10 = $190. Withdrawn = $760.
        vm.prank(vaultCore);
        uint256 withdrawn = pm.openPerpLegAndExtractMargin(user, WTI, 23.75 ether, 100000);

        assertEq(withdrawn, 760e6);
        PositionManager.PerpLegState memory leg = pm.getPerpLegState(user);
        assertEq(leg.marginUsd,            190e6);
        assertEq(leg.notionalUsd,          1900e6);
        assertEq(leg.effectiveLeverageBps, 100000);
    }

    function test_openPerpLegRejectsLowLeverage() public {
        vm.prank(vaultCore);
        vm.expectRevert(abi.encodeWithSelector(
            PositionManager.InvalidLeverage.selector, uint32(10000)
        ));
        pm.openPerpLegAndExtractMargin(user, WTI, 1 ether, 10000);
    }

    function test_openPerpLegOnlyVaultCore() public {
        vm.expectRevert(abi.encodeWithSelector(
            PositionManager.UnauthorizedCaller.selector, address(this)
        ));
        pm.openPerpLegAndExtractMargin(user, WTI, 1 ether, 50000);
    }

    /* ─────────── Cascade callbacks ─────────── */

    function test_depositToPerpMarginIncreasesEquity() public {
        _openConservativePerp();

        vm.prank(riskManager);
        pm.depositToPerpMargin(user, 100e6);

        PositionManager.PerpLegState memory leg = pm.getPerpLegState(user);
        assertEq(leg.marginUsd, 440e6, "340 + 100");

        // Effective leverage drops: 1700 / 440 ≈ 3.86x (38636 bps)
        assertEq(leg.effectiveLeverageBps, uint32((uint256(1700e6) * 10000) / 440e6));
    }

    function test_depositToPerpMarginOnlyRiskManager() public {
        _openConservativePerp();
        vm.expectRevert(abi.encodeWithSelector(
            PositionManager.UnauthorizedCaller.selector, address(this)
        ));
        pm.depositToPerpMargin(user, 100e6);
    }

    function test_closePerpPositionPartial25Percent() public {
        _openConservativePerp();

        vm.prank(riskManager);
        pm.closePerpPositionPartial(user, 2500);  // 25%

        PositionManager.PerpLegState memory leg = pm.getPerpLegState(user);
        assertEq(leg.notionalUsd, 1275e6, "1700 * 0.75");
        assertTrue(leg.isOpen);
    }

    function test_closePerpLegFull() public {
       _openConservativePerp();
        uint256 vaultBalBefore = hype.balanceOf(vaultCore);

        vm.prank(riskManager);
        uint256 hypeReturned = pm.closePerpLegFull(user);

        assertEq(hypeReturned, 21.25 ether,                                "originalHypeAmount returned");
        assertEq(hype.balanceOf(vaultCore), vaultBalBefore + 21.25 ether,  "HYPE transferred to vault");

        PositionManager.PerpLegState memory leg = pm.getPerpLegState(user);
        assertEq(leg.notionalUsd,          0);
        assertEq(leg.effectiveLeverageBps, 0);
        assertFalse(leg.isOpen);
        assertEq(leg.marginUsd,            340e6,                          "margin retained until withdrawn");
        assertEq(leg.originalHypeAmount,   0,                              "cleared on close");
    }

    //new tests
    function test_repayHyperLendFromCollateralTransfersHype() public {
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);
        uint256 vaultBalBefore = hype.balanceOf(vaultCore);

        vm.prank(riskManager);
        uint256 returned = pm.repayHyperLendFromCollateral(user);

        assertEq(returned, 63.75 ether);
        assertEq(hype.balanceOf(vaultCore), vaultBalBefore + 63.75 ether);
    }

    function test_closePerpLegFullCallableByVault() public {
        _openConservativePerp();
        vm.prank(vaultCore);
        uint256 returned = pm.closePerpLegFull(user);
        assertEq(returned, 21.25 ether);
    }

    function test_repayHyperLendCallableByVault() public {
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);
        vm.prank(vaultCore);
        uint256 returned = pm.repayHyperLendFromCollateral(user);
        assertEq(returned, 63.75 ether);
    }
    //

    function test_withdrawAllPerpMargin() public {
        _openConservativePerp();

        vm.startPrank(riskManager);
        pm.closePerpLegFull(user);
        uint256 amount = pm.withdrawAllPerpMargin(user);
        vm.stopPrank();

        assertEq(amount, 340e6);
        PositionManager.PerpLegState memory leg = pm.getPerpLegState(user);
        assertEq(leg.marginUsd, 0);
    }

    function test_repayHyperLendFromCollateral() public {
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);

        vm.prank(riskManager);
        uint256 returned = pm.repayHyperLendFromCollateral(user);

        assertEq(returned, 63.75 ether);
        PositionManager.LendingLegState memory leg = pm.getLendingLegState(user);
        assertEq(leg.hypeSupplied,  0);
        assertEq(leg.usdcBorrowed,  0);
    }

    /* ─────────── Swap helpers ─────────── */

    function test_swapHypeToUsdc() public {
        vm.prank(vaultCore);
        uint256 out = pm.swapHypeToUsdc(1 ether);
        assertEq(out, 40e6, "1 HYPE = $40 USDC at stub price");
    }

    function test_swapUsdcToHype() public {
        vm.prank(vaultCore);
        uint256 out = pm.swapUsdcToHype(40e6);
        assertEq(out, 1 ether, "$40 = 1 HYPE at stub price");
    }

    function test_swapsRoundTrip() public {
        vm.startPrank(vaultCore);
        uint256 usdcOut = pm.swapHypeToUsdc(2.5 ether);
        uint256 hypeBack = pm.swapUsdcToHype(usdcOut);
        vm.stopPrank();
        assertEq(hypeBack, 2.5 ether);
    }

    function test_swapOnlyAuthorized() public {
        vm.expectRevert(abi.encodeWithSelector(
            PositionManager.UnauthorizedCaller.selector, address(this)
        ));
        pm.swapHypeToUsdc(1 ether);
    }

    /* ─────────── Views ─────────── */

    function test_getHyperLendDebt() public {
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);
        assertEq(pm.getHyperLendDebt(user), 765e6);
    }

    function test_getHyperLendCollateralValue() public {
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);
        assertEq(pm.getHyperLendCollateralValue(user), 2550e6, "63.75 * $40 = $2550");
    }

    function test_getPerpNotionalAndMargin() public {
        _openConservativePerp();
        assertEq(pm.getPerpNotionalUsd(user),     1700e6);
        assertEq(pm.getPerpMarginEquityUsd(user), 340e6);
    }

    /* ─────────── Helpers ─────────── */

    function _openConservativePerp() internal {
        vm.prank(vaultCore);
        pm.openPerpLegAndExtractMargin(user, WTI, 21.25 ether, 50000);
    }
}