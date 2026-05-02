// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title YieldRouter
/// @notice Splits funding-rate income each accrual period across the vault-wide
///         insurance pool, the per-user smoothing reserve, and per-user principal
///         paydown. See Technical Spec §3.4.
contract YieldRouter {
    address public immutable vaultCore;
    address public immutable positionManager;

    uint16 public constant INSURANCE_RATE_BPS = 1000;   // 10% (Risk Framework §7.1)

    uint256 public insurancePoolBalance;

    struct UserRouterState {
        uint256 smoothingReserveBalance;
        uint256 smoothingTargetUsd;     // computed at deposit from term × profile
        uint256 creditBalance;          // overage from full paydown
    }
    mapping(address => UserRouterState) public state;

    event IncomeDistributed(
        address indexed user,
        uint256 totalIncome,
        uint256 insuranceCut,
        uint256 smoothingTopUp,
        uint256 principalPaydown
    );

    constructor(address _vaultCore, address _positionManager) {
        vaultCore = _vaultCore;
        positionManager = _positionManager;
    }

    // Called by KeeperBot; iterates over users and distributes accrued funding.
    function accrueAndDistribute(address user, uint256 fundingIncomeUsd) external {
        // TODO: insuranceCut = income * INSURANCE_RATE_BPS / 10000
        // TODO: smoothingTopUp = min(remaining, smoothingTarget - currentBalance)
        // TODO: principalPaydown = residual; reduce user.usdcDebt
        // TODO: handle overage path (creditBalance accumulates if debt hits zero)
        // TODO: emit IncomeDistributed
    }

    // Inverse path — drain smoothing reserve to cover borrow APR during dry stretches.
    function coverBorrowExpense(address user, uint256 expenseUsd) external returns (uint256 covered) {
        // TODO: drain smoothingReserveBalance first
        // TODO: if empty, accrue debit on creditBalance (will be repaid by next positive accrual)
    }
}