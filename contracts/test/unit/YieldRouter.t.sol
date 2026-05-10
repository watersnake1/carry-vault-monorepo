// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }            from "forge-std/Test.sol";
import { YieldRouter }     from "../../src/core/YieldRouter.sol";
import { PositionManager } from "../../src/core/PositionManager.sol";
import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { OracleLayer } from "../../src/core/OracleLayer.sol";


contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract YieldRouterTest is Test {

    YieldRouter     internal yr;
    PositionManager internal pm;
    MockToken       internal hype;
    MockToken       internal usdc;

    address internal vaultCore   = address(0xCA11);
    address internal riskManager = address(0xBA88);
    address internal keeper      = address(0xCAFE);
    address internal user        = address(0xBE);
    OracleLayer internal oracleLayer;

    uint8 internal constant CONSERVATIVE = 0;
    uint8 internal constant RISKY        = 1;

    function setUp() public {
        hype = new MockToken("HYPE", "HYPE");
        usdc = new MockToken("USDC", "USDC");

        oracleLayer = new OracleLayer(address(0xA));
        pm = new PositionManager(address(oracleLayer), address(hype), address(usdc));
        pm.initialize(vaultCore, riskManager);
        hype.mint(vaultCore, 1000 ether);
        vm.prank(vaultCore);
        hype.approve(address(pm), type(uint256).max);
        yr = new YieldRouter(address(pm));
        yr.initialize(vaultCore);                  // ← new line
        yr.grantRole(yr.KEEPER_ROLE(), keeper);

        // calls to sync with other contracts
        vm.mockCall(vaultCore, abi.encodeWithSignature("updateSpotReserve(address,uint256)"),       "");
        vm.mockCall(vaultCore, abi.encodeWithSignature("updateSmoothingReserve(address,uint256)"),  "");
        vm.mockCall(vaultCore, abi.encodeWithSignature("updateCreditBalance(address,uint256)"),     "");
        vm.mockCall(vaultCore, abi.encodeWithSignature("updateHyperLendDebt(address,uint256)"),     "");
    }

    /* ─────────── Constructor ─────────── */

    function test_constructorSetsImmutables() public {
        assertEq(yr.vaultCore(),       vaultCore);
        assertEq(yr.positionManager(), address(pm));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(YieldRouter.ZeroAddress.selector);
        new YieldRouter(address(0));
    }

    function test_initializeRejectsZero() public {
        YieldRouter fresh = new YieldRouter(address(pm));
        vm.expectRevert(YieldRouter.ZeroAddress.selector);
        fresh.initialize(address(0));
    }

    function test_initializeRejectsDouble() public {
        // yr is already initialized in setUp
        vm.expectRevert(YieldRouter.AlreadyInitialized.selector);
        yr.initialize(vaultCore);
    }

    function test_callsRevertBeforeInitialize() public {
        YieldRouter fresh = new YieldRouter(address(pm));
        vm.prank(vaultCore);
        vm.expectRevert(YieldRouter.NotInitialized.selector);
        fresh.registerUser(user, 0, 100 ether);
    }

    /* ─────────── Registration ─────────── */

    function test_registerUserHappyPath() public {
        vm.prank(vaultCore);
        yr.registerUser(user, CONSERVATIVE, 100 ether);

        assertTrue(yr.registered(user));
        assertEq(yr.userProfile(user), CONSERVATIVE);
        assertEq(yr.userDeposit(user), 100 ether);
    }

    function test_registerOnlyVaultCore() public {
        vm.expectRevert(abi.encodeWithSelector(
            YieldRouter.UnauthorizedCaller.selector, address(this)
        ));
        yr.registerUser(user, CONSERVATIVE, 100 ether);
    }

    function test_registerRejectsDouble() public {
        vm.startPrank(vaultCore);
        yr.registerUser(user, CONSERVATIVE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(
            YieldRouter.UserAlreadyRegistered.selector, user
        ));
        yr.registerUser(user, CONSERVATIVE, 100 ether);
        vm.stopPrank();
    }

    function test_registerRejectsUnknownProfile() public {
        vm.prank(vaultCore);
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.UnknownProfile.selector, uint8(2)));
        yr.registerUser(user, 2, 100 ether);
    }

    function test_unregisterClearsState() public {
        vm.startPrank(vaultCore);
        yr.registerUser(user, CONSERVATIVE, 100 ether);
        yr.unregisterUser(user);
        vm.stopPrank();

        assertFalse(yr.registered(user));
        assertEq(yr.userDeposit(user),  0);
        assertEq(yr.userProfile(user),  0);
    }

    /* ─────────── Targets ─────────── */

    function test_spotReserveTargetConservative() public {
        vm.prank(vaultCore);
        yr.registerUser(user, CONSERVATIVE, 100 ether);
        // Conservative reserve = 15% of 100 HYPE = 15 HYPE
        assertEq(yr.getSpotReserveTarget(user), 15 ether);
    }

    function test_spotReserveTargetRisky() public {
        vm.prank(vaultCore);
        yr.registerUser(user, RISKY, 100 ether);
        // Risky reserve = 5% of 100 HYPE = 5 HYPE
        assertEq(yr.getSpotReserveTarget(user), 5 ether);
    }

    function test_smoothingTargetConservative() public {
        vm.prank(vaultCore);
        yr.registerUser(user, CONSERVATIVE, 100 ether);
        // Conservative = 6 months × debt × 6% APR / 12 = debt × 0.03
        // For debt = $765 → $22.95 = 22.95e6
        assertEq(yr.getSmoothingTarget(user, 765e6), 22_950_000);
    }

    function test_smoothingTargetRisky() public {
        vm.prank(vaultCore);
        yr.registerUser(user, RISKY, 100 ether);
        // Risky = 3 months × debt × 6% APR / 12 = debt × 0.015
        // For debt = $1425 → $21.375 = 21.375e6
        assertEq(yr.getSmoothingTarget(user, 1425e6), 21_375_000);
    }

    /* ─────────── accrueAndDistribute ─────────── */

    function test_accrueRequiresRegistration() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.UserNotRegistered.selector, user));
        yr.accrueAndDistribute(user, 100e6);
    }

    function test_accrueZeroIncomeIsNoop() public {
        _registerConservative();
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 0);

        assertEq(yr.insurancePoolBalance(),     0);
        assertEq(yr.spotReserves(user),         0);
        assertEq(yr.smoothingReserves(user),    0);
        assertEq(yr.accumulatedPaydown(user),   0);
    }

    function test_accrueOnlyKeeperOrVault() public {
        _registerConservative();
        vm.expectRevert(abi.encodeWithSelector(
            YieldRouter.UnauthorizedCaller.selector, address(this)
        ));
        yr.accrueAndDistribute(user, 100e6);
    }

    function test_accrueAllToInsuranceAndSpotReserve() public {
        _registerConservativeWithDebt();

        // Conservative: 15 HYPE target = $600 USDC equivalent at $40/HYPE.
        // With $100 income: 10% to insurance ($10), $90 remaining all to spot reserve.
        // Spot deficit USDC = $600, remaining $90 < deficit, so all $90 used.
        // Smoothing target with debt=$765 is $22.95; nothing left after spot fill.
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 100e6);

        assertEq(yr.insurancePoolBalance(),     10e6,          "10% insurance");
        // $90 USDC → 2.25 HYPE (90/40)
        assertEq(yr.spotReserves(user),         2.25 ether,    "$90 worth of HYPE");
        assertEq(yr.smoothingReserves(user),    0,             "nothing left for smoothing");
        assertEq(yr.accumulatedPaydown(user),   0);
    }

    function test_accrueFullSplitWithLargeIncome() public {
        _registerConservativeWithDebt();

        // Income $1,000 → insurance $100, remaining $900.
        // Spot reserve target = 15 HYPE = $600. Topup all $600.
        // Remaining $300. Smoothing target = $22.95. Topup $22.95.
        // Remaining $277.05 → all to paydown (debt is $765 which exceeds remaining).
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 1000e6);

        assertEq(yr.insurancePoolBalance(),     100e6);
        assertEq(yr.spotReserves(user),         15 ether,       "spot reserve filled");
        assertEq(yr.smoothingReserves(user),    22_950_000);
        assertEq(yr.accumulatedPaydown(user),   277_050_000,    "$277.05 paydown");
        assertEq(yr.creditBalances(user),       0,              "debt > paydown, no overage");
    }

    function test_accrueOverageGoesToCredit() public {
        _registerConservativeWithDebt();

        // Set debt to $50 (small) so income exceeds debt and triggers overage.
        // Income $5000 → $500 insurance, remaining $4500.
        // Spot target $600 (filled), smoothing $1.50 (= $50 × 6% × 6 / 12 = $1.50), remaining $4498.50.
        // Wait that's wrong — let me recompute. Smoothing target with debt=$50: $50 × 600/10000 × 6/12 = $50 × 0.06 × 0.5 = $1.5.
        // Remaining after smoothing = $4500 - $600 - $1.50 = $3898.50.
        // Paydown: only $50 of debt, so $50 paid, $3848.50 to credit.

        vm.mockCall(
            address(pm),
            abi.encodeWithSignature("getHyperLendDebt(address)", user),
            abi.encode(uint256(50e6))
        );

        vm.prank(keeper);
        yr.accrueAndDistribute(user, 5000e6);

        assertEq(yr.insurancePoolBalance(),     500e6);
        assertEq(yr.spotReserves(user),         15 ether);
        assertEq(yr.smoothingReserves(user),    1_500_000,        "$1.50 smoothing");
        assertEq(yr.accumulatedPaydown(user),   50e6,             "full debt paid");
        assertEq(yr.creditBalances(user),       3_848_500_000,    "rest to credit");
    }

    function test_accrueRespectsExistingReserves() public {
        _registerConservativeWithDebt();

        // First accrual: $1000 → fully fills spot + smoothing + some paydown.
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 1000e6);

        // Second accrual: $200 → insurance $20, remaining $180.
        // Spot reserve already full (15 HYPE), so 0 spot top-up.
        // Smoothing already full ($22.95), so 0 smoothing top-up.
        // All $180 to paydown.
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 200e6);

        assertEq(yr.insurancePoolBalance(),    120e6,                     "100 + 20");
        assertEq(yr.spotReserves(user),        15 ether,                  "still full");
        assertEq(yr.smoothingReserves(user),   22_950_000,                "still full");
        assertEq(yr.accumulatedPaydown(user),  277_050_000 + 180_000_000, "first + second");
    }

    /* ─────────── coverBorrowExpense ─────────── */

    function test_coverBorrowExpenseFullyCovered() public {
        _registerConservativeWithDebt();
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 1000e6);  // Build up smoothing reserve

        uint256 reserveBefore = yr.smoothingReserves(user);

        vm.prank(keeper);
        (uint256 covered, uint256 uncovered) = yr.coverBorrowExpense(user, 10e6);

        assertEq(covered,                       10e6);
        assertEq(uncovered,                     0);
        assertEq(yr.smoothingReserves(user),    reserveBefore - 10e6);
    }

    function test_coverBorrowExpensePartiallyCovered() public {
        _registerConservativeWithDebt();
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 1000e6);  // builds reserve to $22.95

        vm.prank(keeper);
        (uint256 covered, uint256 uncovered) = yr.coverBorrowExpense(user, 100e6);

        assertEq(covered,                       22_950_000);
        assertEq(uncovered,                     77_050_000);
        assertEq(yr.smoothingReserves(user),    0);
    }

    function test_coverBorrowExpenseRequiresRegistration() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.UserNotRegistered.selector, user));
        yr.coverBorrowExpense(user, 10e6);
    }

    function test_coverBorrowExpenseZeroIsNoop() public {
        _registerConservative();
        vm.prank(keeper);
        (uint256 covered, uint256 uncovered) = yr.coverBorrowExpense(user, 0);
        assertEq(covered, 0);
        assertEq(uncovered, 0);
    }

    /* ─────────── Snapshot view ─────────── */

    function test_getUserSnapshot() public {
        _registerConservativeWithDebt();
        vm.prank(keeper);
        yr.accrueAndDistribute(user, 1000e6);

        (
            bool    isReg,
            uint8   profile,
            uint256 deposit,
            uint256 spotHype,
            uint256 spotTarget,
            uint256 smoothing,
            uint256 credit,
            uint256 paydown
        ) = yr.getUserSnapshot(user);

        assertTrue(isReg);
        assertEq(profile,     CONSERVATIVE);
        assertEq(deposit,     100 ether);
        assertEq(spotHype,    15 ether);
        assertEq(spotTarget,  15 ether);
        assertEq(smoothing,   22_950_000);
        assertEq(credit,      0);
        assertEq(paydown,     277_050_000);
    }

    /* ─────────── Helpers ─────────── */

    function _registerConservative() internal {
        vm.prank(vaultCore);
        yr.registerUser(user, CONSERVATIVE, 100 ether);
    }

    function _registerConservativeWithDebt() internal {
        _registerConservative();
        // Open a HyperLend leg via PM so getHyperLendDebt returns 765e6
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);
    }
}