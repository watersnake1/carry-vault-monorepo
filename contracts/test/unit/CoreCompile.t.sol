// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }            from "forge-std/Test.sol";
import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { VaultCore }       from "../../src/core/VaultCore.sol";
import { StrategyEngine }  from "../../src/core/StrategyEngine.sol";
import { PositionManager } from "../../src/core/PositionManager.sol";
import { RiskManager }     from "../../src/core/RiskManager.sol";
import { YieldRouter }     from "../../src/core/YieldRouter.sol";
import { OracleLayer }     from "../../src/core/OracleLayer.sol";

contract MockHype is ERC20 {
    constructor() ERC20("Mock HYPE", "HYPE") {}
}

contract CoreCompileTest is Test {

    /* ─── Per-contract deploy tests ─── */

    function test_vaultCoreDeploys() public {
        MockHype hype = new MockHype();
        MockHype usdc = new MockHype();
        VaultCore vault = new VaultCore(
            hype, usdc,
            address(0x1), address(0x2), address(0x3), address(0x4),
            address(0x5), address(0x6)
        );
        assertEq(address(vault.asset()), address(hype));
        assertEq(address(vault.usdc()),  address(usdc));
        assertEq(vault.name(),   "Carry Vault HYPE");
        assertEq(vault.symbol(), "xCarry");
    }

    function test_strategyEngineDeploys() public {
        StrategyEngine se = new StrategyEngine(
            address(0x1), address(0x2), address(0x3), address(0x4), address(0x5)
        );
        assertTrue(address(se) != address(0));
        assertEq(se.currentPerpMarket(), keccak256("WTI-USDC"));
    }

    function test_positionManagerDeploys() public {
        MockHype hypeT = new MockHype();
        MockHype usdcT = new MockHype();
        PositionManager pm = new PositionManager(address(0xA), address(hypeT), address(usdcT));
        assertTrue(address(pm) != address(0));
        assertEq(address(pm.hype()), address(hypeT));
        assertEq(address(pm.usdc()), address(usdcT));
        assertFalse(pm.initialized());
    }

    function test_riskManagerDeploys() public {
        RiskManager rm = new RiskManager(address(0x2), address(0x3));
        assertTrue(address(rm) != address(0));
        assertEq(rm.getPerpLeverageForProfile(0),    50000);
        assertEq(rm.getReserveSplitForProfile(0),    1500);
        assertEq(rm.getHyperLendTargetLtv(0),        3000);
    }

    function test_yieldRouterDeploys() public {
        YieldRouter yr = new YieldRouter(address(0x1));
        assertTrue(address(yr) != address(0));
        assertEq(yr.positionManager(), address(0x1));
        assertFalse(yr.initialized());
    }

    function test_oracleLayerDeploys() public {
        OracleLayer ol = new OracleLayer(address(0x1));
        assertTrue(address(ol) != address(0));
    }

    /* ─── Deposit happy path ─── */

    function test_depositOpensPosition() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));

        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);

        uint256 shares = vault.depositWithProfile(
            100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12
        );

        assertEq(shares,                            100 ether);
        assertEq(vault.balanceOf(address(this)),    100 ether);
        assertEq(hype.balanceOf(address(vault)),    15 ether,  "spot reserve only");
        assertEq(hype.balanceOf(address(vault.positionManager())), 85 ether, "85 HYPE on PM");
    }

    function test_depositRecordsCorrectStruct() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);

        (
            address user,
            uint64  openedAt,
            uint256 hypeDeposit,
            uint16  allocationSplitBps,
            uint16  reserveSplitBps,
            ,
            uint32  termMonths,
            bytes32 perpMarketId,
            uint256 hyperLendDebtUsd,
            uint256 perpMarginWithdrawnUsd,
            uint256 spotReserveBalance,
            ,
            ,
        ) = vault.positions(address(this));

        assertEq(user,                   address(this));
        assertGt(openedAt,               0);
        assertEq(hypeDeposit,            100 ether);
        assertEq(allocationSplitBps,     7500);
        assertEq(reserveSplitBps,        1500);
        assertEq(termMonths,             12);
        assertEq(perpMarketId,           keccak256("WTI-USDC"));

        // Conservative + 75/25 + $40 HYPE: lending leg = 63.75 HYPE × $40 × 30% = $765
        assertEq(hyperLendDebtUsd,       765e6);

        // Conservative + 75/25 + $40 HYPE: perp leg = 21.25 HYPE × $40 × (1 - 2/5) = $510
        assertEq(perpMarginWithdrawnUsd, 510e6);

        assertEq(spotReserveBalance,     15 ether);
    }

    function test_depositRiskyProfileSetsCorrectReserveSplit() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.RISKY, 12);

        ( , , , , uint16 reserveSplitBps, , , , uint256 hyperLendDebtUsd, uint256 perpMarginWithdrawnUsd, uint256 spotReserveBalance, , ,) =
            vault.positions(address(this));

        assertEq(reserveSplitBps,    500);
        assertEq(spotReserveBalance, 5 ether);

        // Risky + 75/25 + $40 HYPE: lending leg = 71.25 × $40 × 50% = $1425
        assertEq(hyperLendDebtUsd,       1425e6);
        // Risky perp = 23.75 × $40 × (1 - 2/10) = $760
        assertEq(perpMarginWithdrawnUsd, 760e6);
    }

    function test_depositTracksDebtsSeparately() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);

        ( , , , , , , , , uint256 hyperLendDebtUsd, uint256 perpMarginWithdrawnUsd, , , ,) =
            vault.positions(address(this));

        assertEq(hyperLendDebtUsd,       765e6);
        assertEq(perpMarginWithdrawnUsd, 510e6);
        assertTrue(hyperLendDebtUsd != perpMarginWithdrawnUsd);
    }

    /* ─── Deposit guard rails ─── */

    function test_depositRejectsZeroAmount() public {
        VaultCore vault = _deployFullStack();
        vm.expectRevert(VaultCore.ZeroAmount.selector);
        vault.depositWithProfile(0, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);
    }

    function test_depositRejectsBelowMinDeposit() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 1 ether);
        hype.approve(address(vault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(
            VaultCore.BelowMinDeposit.selector, uint256(1e16), uint256(1e17)
        ));
        vault.depositWithProfile(1e16, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);
    }

    function test_depositRejectsBadAllocation() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 1 ether);
        hype.approve(address(vault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(
            VaultCore.InvalidAllocationSplit.selector, uint16(10001)
        ));
        vault.depositWithProfile(1 ether, 10001, VaultCore.RiskProfile.CONSERVATIVE, 12);
    }

    function test_depositRejectsBadTerm() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 1 ether);
        hype.approve(address(vault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(VaultCore.InvalidTerm.selector, uint32(0)));
        vault.depositWithProfile(1 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 0);
    }

    function test_depositRejectsTooLongTerm() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 1 ether);
        hype.approve(address(vault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(VaultCore.InvalidTerm.selector, uint32(25)));
        vault.depositWithProfile(1 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 25);
    }

    function test_depositRejectsDoubleOpen() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 200 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);

        vm.expectRevert(abi.encodeWithSelector(VaultCore.PositionAlreadyOpen.selector, address(this)));
        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);
    }

    function test_vanillaDepositReverts() public {
        VaultCore vault = _deployFullStack();
        vm.expectRevert(VaultCore.UseDepositWithProfile.selector);
        vault.deposit(1 ether, address(this));
    }

    function test_vanillaMintReverts() public {
        VaultCore vault = _deployFullStack();
        vm.expectRevert(VaultCore.UseDepositWithProfile.selector);
        vault.mint(1 ether, address(this));
    }


    /* -- extra tests -- */
    /* ─── Deposit registration with YieldRouter ─── */

    function test_depositRegistersUserInYieldRouter() public {
        VaultCore vault = _deployFullStack();
        YieldRouter yr  = YieldRouter(payable(vault.yieldRouter()));

        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);

        assertTrue(yr.registered(address(this)),                        "user registered");
        assertEq(yr.userProfile(address(this)),  uint8(VaultCore.RiskProfile.CONSERVATIVE));
        assertEq(yr.userDeposit(address(this)),  100 ether);
    }

    function test_depositRegistersRiskyProfileCorrectly() public {
        VaultCore vault = _deployFullStack();
        YieldRouter yr  = YieldRouter(payable(vault.yieldRouter()));

        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 50 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(50 ether, 6000, VaultCore.RiskProfile.RISKY, 6);

        assertEq(yr.userProfile(address(this)), uint8(VaultCore.RiskProfile.RISKY));
        assertEq(yr.userDeposit(address(this)), 50 ether);
    }

    /* ─── Group 3 setters ─── */

    function test_updateHyperLendDebt() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        address strategy = vault.strategyEngine();

        vm.prank(strategy);
        vault.updateHyperLendDebt(address(this), 500e6);

        ( , , , , , , , , uint256 debt, , , , ,) = vault.positions(address(this));
        assertEq(debt, 500e6);
    }

    function test_updateHyperLendDebtAdjustsTotal() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        (,uint256 totalBefore,,,,) = vault.vaultState();
        address strategy = vault.strategyEngine();

        // Reduce debt by 100e6
        vm.prank(strategy);
        vault.updateHyperLendDebt(address(this), 665e6);  // was 765e6

        (,uint256 totalAfter,,,,) = vault.vaultState();
        assertEq(totalBefore - totalAfter, 100e6, "total drops by 100");
    }

    function test_updateHyperLendDebtAcceptsYieldRouter() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        address yr = vault.yieldRouter();
        vm.prank(yr);
        vault.updateHyperLendDebt(address(this), 100e6);

        ( , , , , , , , , uint256 debt, , , , ,) = vault.positions(address(this));
        assertEq(debt, 100e6);
    }

    function test_updateHyperLendDebtRejectsUnauthorized() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(VaultCore.UnauthorizedCaller.selector, address(this)));
        vault.updateHyperLendDebt(address(this), 100e6);
    }

    function test_updatePerpMarginWithdrawn() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.strategyEngine());
        vault.updatePerpMarginWithdrawn(address(this), 100e6);

        ( , , , , , , , , , uint256 perp, , , ,) = vault.positions(address(this));
        assertEq(perp, 100e6);
    }

    function test_updateSmoothingReserve() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.yieldRouter());
        vault.updateSmoothingReserve(address(this), 50e6);

        ( , , , , , , , , , , , uint256 smoothing, ,) = vault.positions(address(this));
        assertEq(smoothing, 50e6);
    }

    function test_updateCreditBalance() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.yieldRouter());
        vault.updateCreditBalance(address(this), 25e6);

        ( , , , , , , , , , , , , uint256 credit,) = vault.positions(address(this));
        assertEq(credit, 25e6);
    }

    function test_updateSpotReserve() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        // YieldRouter can update
        vm.prank(vault.yieldRouter());
        vault.updateSpotReserve(address(this), 20 ether);

        ( , , , , , , , , , , uint256 spot, , ,) = vault.positions(address(this));
        assertEq(spot, 20 ether);

        // RiskManager can also update
        vm.prank(vault.riskManager());
        vault.updateSpotReserve(address(this), 10 ether);

        ( , , , , , , , , , , uint256 spot2, , ,) = vault.positions(address(this));
        assertEq(spot2, 10 ether);
    }

    /* ─── applyPaydown ─── */

    function test_applyPaydownPartial() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        // Initial debt = 765e6
        vm.prank(vault.yieldRouter());
        (uint256 paid, uint256 overage) = vault.applyPaydown(address(this), 200e6);

        assertEq(paid,    200e6);
        assertEq(overage, 0);

        ( , , , , , , , , uint256 debt, , , , ,) = vault.positions(address(this));
        assertEq(debt, 565e6, "765 - 200");
    }

    function test_applyPaydownFullWithOverage() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        // Pay down more than the debt
        vm.prank(vault.yieldRouter());
        (uint256 paid, uint256 overage) = vault.applyPaydown(address(this), 1000e6);

        assertEq(paid,    765e6);
        assertEq(overage, 235e6);

        (,,,,,,,, uint256 debt,,,, uint256 credit,) = vault.positions(address(this));
        assertEq(debt,    0);
        assertEq(credit,  235e6);
    }

    function test_applyPaydownExactDebt() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.yieldRouter());
        (uint256 paid, uint256 overage) = vault.applyPaydown(address(this), 765e6);

        assertEq(paid,    765e6);
        assertEq(overage, 0);

        (,,,,,,,, uint256 debt,,,, uint256 credit,) = vault.positions(address(this));
        assertEq(debt,    0);
        assertEq(credit,  0);
    }

    function test_applyPaydownRejectsUnauthorized() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);
        vm.expectRevert();   // OZ AccessControl reverts
        vault.applyPaydown(address(this), 100e6);
    }

    /* ─── helper ─── */

    function _depositConservative(VaultCore vault, uint256 amount) internal {
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), amount);
        hype.approve(address(vault), type(uint256).max);
        vault.depositWithProfile(amount, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);
    }
    /* ─── Helper ─── */

    /* ─── repay() ─── */

    function test_repayClosesPositionFully() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        ERC20 hype = ERC20(address(vault.asset()));

        vault.repay();

        // Position state cleared and marked CLOSED
        (
            ,,,,,,,,
            uint256 debt,
            uint256 perpMargin,
            uint256 spot,
            uint256 smoothing,
            uint256 credit,
            VaultCore.LifecycleState state
        ) = vault.positions(address(this));

        assertEq(debt,       0);
        assertEq(perpMargin, 0);
        assertEq(spot,       0);
        assertEq(smoothing,  0);
        assertEq(credit,     0);
        assertEq(uint8(state), uint8(VaultCore.LifecycleState.CLOSED));

        // Shares burned
        assertEq(vault.balanceOf(address(this)), 0);

        // HYPE returned in full
        assertEq(hype.balanceOf(address(this)), 100 ether);

        // Vault and PM both empty
        assertEq(hype.balanceOf(address(vault)), 0);
        assertEq(hype.balanceOf(address(vault.positionManager())), 0);
    }

    function test_repayClearsVaultDebtTotal() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        (, uint256 debtBefore, , , ,) = vault.vaultState();
        assertGt(debtBefore, 0,           "non-zero debt after deposit");

        vault.repay();

        (, uint256 debtAfter,  , , ,) = vault.vaultState();
        assertEq(debtAfter, 0,            "vault total debt cleared");
    }

    function test_repayUnregistersFromYieldRouter() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        YieldRouter yr = YieldRouter(payable(vault.yieldRouter()));
        assertTrue(yr.registered(address(this)));

        vault.repay();

        assertFalse(yr.registered(address(this)));
        assertEq(yr.userDeposit(address(this)), 0);
    }

    function test_repayRemovesFromActiveUsers() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);
        assertEq(vault.activeUsers(0), address(this));

        vault.repay();

        // Active users array should be empty
        vm.expectRevert();
        vault.activeUsers(0);
    }

    function test_repayRiskyProfileFullCycle() public {
        VaultCore vault = _deployFullStack();
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);

        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.RISKY, 12);
        vault.repay();

        assertEq(hype.balanceOf(address(this)), 100 ether);
        assertEq(vault.balanceOf(address(this)), 0);
    }

    function test_repayRejectsWhenNoPosition() public {
        VaultCore vault = _deployFullStack();
        vm.expectRevert(abi.encodeWithSelector(VaultCore.PositionNotOpen.selector, address(this)));
        vault.repay();
    }

    function test_repayRejectsAfterClose() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);
        vault.repay();

        vm.expectRevert(abi.encodeWithSelector(VaultCore.PositionNotOpen.selector, address(this)));
        vault.repay();
    }

    function test_depositAfterRepayWorks() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);
        vault.repay();

        // Should be able to deposit again with a fresh position
        ERC20 hype = ERC20(address(vault.asset()));
        deal(address(hype), address(this), 50 ether);
        hype.approve(address(vault), type(uint256).max);

        uint256 shares = vault.depositWithProfile(50 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 6);
        assertGt(shares, 0,                              "new deposit succeeds");
    }

    // ============================================================
    // WITHDRAWAL QUEUE TESTS
    // ============================================================

    function test_requestWithdrawRejectsWhenNormal() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        // Vault is NORMAL by default — request should revert
        vm.expectRevert();
        vault.requestWithdraw(50 ether);
    }

    function test_requestWithdrawQueuesUnderStress() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.riskManager());
        vault.setVaultLevelState(VaultCore.VaultLevelState.STRESS);

        uint256 sharesToWithdraw = vault.balanceOf(address(this));

        vault.requestWithdraw(sharesToWithdraw);

        assertEq(vault.balanceOf(address(vault)), sharesToWithdraw, "shares not locked");

        (address user, uint256 sh, uint64 reqAt, uint64 unlockAt, bool fulfilled) =
            vault.withdrawalRequests(address(this));
        assertEq(user,    address(this));
        assertEq(sh,      sharesToWithdraw);
        assertEq(unlockAt, reqAt + 12 hours);
        assertFalse(fulfilled);
    }

    function test_requestWithdrawRejectsDoubleQueue() public {
       VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.riskManager());
        vault.setVaultLevelState(VaultCore.VaultLevelState.STRESS);

        uint256 shares = vault.balanceOf(address(this));
        vault.requestWithdraw(shares);  // first queue: full balance, succeeds

        // Second call — any non-zero amount triggers the queue guard
        vm.expectRevert();
        vault.requestWithdraw(shares);
    }

    function test_fulfillWithdrawRejectsBeforeUnlock() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.riskManager());
        vault.setVaultLevelState(VaultCore.VaultLevelState.STRESS);

        uint256 sharesToWithdraw = vault.balanceOf(address(this));

        vault.requestWithdraw(sharesToWithdraw);

        vm.warp(block.timestamp + 6 hours);
        vm.expectRevert();
        vault.fulfillWithdraw();
    }

    function test_fulfillWithdrawRejectsWhenNoRequest() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.expectRevert();
        vault.fulfillWithdraw();
    }

    function test_cancelWithdrawReturnsLockedShares() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.riskManager());
        vault.setVaultLevelState(VaultCore.VaultLevelState.STRESS);

        uint256 shares = vault.balanceOf(address(this));
        vault.requestWithdraw(shares);

        assertEq(vault.balanceOf(address(this)), 0);

        vault.cancelWithdraw();

        assertEq(vault.balanceOf(address(this)), shares,    "shares not returned");
        (address user, , , , ) = vault.withdrawalRequests(address(this));
        assertEq(user, address(0), "request not deleted");
    }

    function test_cancelWithdrawRejectsWhenNoRequest() public {
        VaultCore vault = _deployFullStack();
        vm.expectRevert();
        vault.cancelWithdraw();
    }

    function _deployFullStack() internal returns (VaultCore) {
        MockHype hype = new MockHype();
        MockHype usdc = new MockHype();
        OracleLayer oracle = new OracleLayer(address(0xA));

        PositionManager pm = new PositionManager(address(oracle), address(hype), address(usdc));

        RiskManager     rm = new RiskManager(address(pm), address(oracle));
        YieldRouter     yr = new YieldRouter(address(pm));                                  // ← only PM
        StrategyEngine  se = new StrategyEngine(address(0x1), address(pm), address(oracle), address(rm), address(this));
        VaultCore       vault = new VaultCore(hype, usdc, address(se), address(pm), address(rm), address(yr), address(oracle), address(this));

        pm.initialize(address(vault), address(rm));
        yr.initialize(address(vault));  
        rm.initialize(address(vault));                                                     // ← initialize YR

        return vault;
    }

    /* ─── Views ─── */

    function test_getUserPositionEmpty() public {
        VaultCore vault = _deployFullStack();
        VaultCore.UserPosition memory p = vault.getUserPosition(address(this));
        assertEq(p.user,        address(0));
        assertEq(p.hypeDeposit, 0);
        assertEq(uint8(p.state), uint8(VaultCore.LifecycleState.NONE));
    }

    function test_getUserPositionAfterDeposit() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        VaultCore.UserPosition memory p = vault.getUserPosition(address(this));
        assertEq(p.user,                   address(this));
        assertEq(p.hypeDeposit,            100 ether);
        assertEq(p.allocationSplitBps,     7500);
        assertEq(p.hyperLendDebtUsd,       765e6);
        assertEq(uint8(p.state), uint8(VaultCore.LifecycleState.OPEN));
    }

    function test_getUserViewBundlesShares() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        VaultCore.UserView memory v = vault.getUserView(address(this));
        assertEq(v.shares,                       100 ether);
        assertEq(v.position.hypeDeposit,         100 ether);
        assertFalse(v.hasPendingWithdrawal);
        assertEq(v.pendingWithdrawalShares,      0);
    }

    function test_getUserViewIncludesQueuedWithdrawal() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        vm.prank(vault.riskManager());
        vault.setVaultLevelState(VaultCore.VaultLevelState.STRESS);

        uint256 shares = vault.balanceOf(address(this));
        vault.requestWithdraw(shares);

        VaultCore.UserView memory v = vault.getUserView(address(this));
        assertTrue(v.hasPendingWithdrawal);
        assertEq(v.pendingWithdrawalShares, shares);
        assertGt(v.withdrawalUnlockAt,      uint64(block.timestamp));
    }

    function test_getActiveUsersCountTracksLifecycle() public {
        VaultCore vault = _deployFullStack();
        assertEq(vault.getActiveUsersCount(), 0);

        _depositConservative(vault, 100 ether);
        assertEq(vault.getActiveUsersCount(), 1);

        vault.repay();
        assertEq(vault.getActiveUsersCount(), 0);
    }

    function test_getActiveUsersReturnsRoster() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        address[] memory users = vault.getActiveUsers();
        assertEq(users.length, 1);
        assertEq(users[0],     address(this));
    }

    function test_getVaultViewReflectsState() public {
        VaultCore vault = _deployFullStack();
        _depositConservative(vault, 100 ether);

        VaultCore.VaultView memory v = vault.getVaultView();
        assertEq(uint8(v.level), uint8(VaultCore.VaultLevelState.NORMAL));
        assertGt(v.totalAssetsHype,    0);
        assertEq(v.totalSharesIssued,  100 ether);
        assertEq(v.activeUsersCount,   1);
        assertTrue(v.depositsEnabled);
        assertFalse(v.isPaused);
        assertEq(v.strategyEngine,     vault.strategyEngine());
        assertEq(v.positionManager,    vault.positionManager());
        assertEq(v.riskManager,        vault.riskManager());
        assertEq(v.yieldRouter,        vault.yieldRouter());
    }

    function test_getVaultViewAfterPause() public {
        VaultCore vault = _deployFullStack();

        // Find PAUSER_ROLE holder — likely address(this) from _deployFullStack admin grant.
        // If your constructor grants PAUSER_ROLE to a different address, prank as that.
        vault.pause();

        VaultCore.VaultView memory v = vault.getVaultView();
        assertTrue(v.isPaused);
    }

}