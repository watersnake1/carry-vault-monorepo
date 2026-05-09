// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

interface IPositionManagerMin {
    function getHyperLendDebt(address user) external view returns (uint256);
}

/// @title  YieldRouter
/// @notice Splits funding-rate income each accrual period across four destinations:
///         vault-wide insurance pool, per-user spot HYPE reserve, per-user
///         smoothing reserve, and per-user principal paydown.
/// @dev    See Technical Spec v0.3 §3.4. State is canonical here for V1; future
///         versions sync to VaultCore via setter callbacks.
contract YieldRouter is AccessControl {

    /* ─────────────────────────── Roles ─────────────────────────── */

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /* ─────────────────────────── Constants ─────────────────────────── */

    uint256 public constant BPS_DENOM                 = 10000;
    uint16  public constant INSURANCE_RATE_BPS        = 1000;   // 10% (Risk Framework §7.1)
    uint16  public constant HYPERLEND_BORROW_APR_BPS  = 600;    // 6% V1 stub; production reads HyperLend
    uint16  public constant CONSERVATIVE_SMOOTHING_MONTHS = 6;
    uint16  public constant RISKY_SMOOTHING_MONTHS        = 3;
    uint16  public constant CONSERVATIVE_RESERVE_BPS      = 1500;
    uint16  public constant RISKY_RESERVE_BPS             = 500;

    /// @dev V1 stub price; production reads from OracleLayer.
    uint256 public constant STUB_HYPE_PRICE_USD = 40;

    /* ─────────────────────────── Immutable refs ─────────────────────────── */

    address public vaultCore;
    address public immutable positionManager;

    /* ─────────────────────────── Storage ─────────────────────────── */

    /// @notice Vault-wide insurance pool (USDC, 6 decimals).
    uint256 public insurancePoolBalance;

    /// @notice Per-user smoothing reserve (USDC).
    mapping(address => uint256) public smoothingReserves;

    /// @notice Per-user spot HYPE reserve (1e18 wei).
    mapping(address => uint256) public spotReserves;

    /// @notice Per-user credit balance from full-paydown overages (USDC).
    mapping(address => uint256) public creditBalances;

    /// @notice Per-user cumulative principal paydown applied (USDC).
    mapping(address => uint256) public accumulatedPaydown;

    /// @notice Per-user cached registration data, set by VaultCore at deposit.
    mapping(address => uint8)   public userProfile;
    mapping(address => uint256) public userDeposit;       // HYPE wei
    mapping(address => bool)    public registered;

    /* ─────────────────────────── Events ─────────────────────────── */

    event UserRegistered(address indexed user, uint8 profile, uint256 hypeDeposit);
    event UserUnregistered(address indexed user);

    event IncomeDistributed(
        address indexed user,
        uint256 totalIncome,
        uint256 insuranceCut,
        uint256 spotTopUpUsdc,
        uint256 spotTopUpHype,
        uint256 smoothingTopUp,
        uint256 principalPaydown,
        uint256 overageToCredit
    );

    event BorrowExpenseCovered(
        address indexed user,
        uint256 expenseRequested,
        uint256 covered,
        uint256 uncovered
    );

    event InsurancePoolDeposit(uint256 amount, uint256 newBalance);

    event Initialized(address vaultCore);

    error AlreadyInitialized();
    error NotInitialized();
    /* ─────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error UnauthorizedCaller(address caller);
    error UserNotRegistered(address user);
    error UserAlreadyRegistered(address user);
    error UnknownProfile(uint8 profile);

    /* ─────────────────────────── Constructor ─────────────────────────── */

    /* ─── Replace the existing constructor ─── */

    //address public immutable positionManager;
    //address public vaultCore;
    bool    public initialized;

    constructor(address _positionManager) {
        if (_positionManager == address(0)) revert ZeroAddress();
        positionManager = _positionManager;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(address _vaultCore) external {
        if (initialized)              revert AlreadyInitialized();
        if (_vaultCore == address(0)) revert ZeroAddress();
        vaultCore   = _vaultCore;
        initialized = true;
        emit Initialized(_vaultCore);
    }

    /* ─────────────────────────── Modifiers ─────────────────────────── */

    modifier onlyVaultCore() {
        if (!initialized)            revert NotInitialized();
        if (msg.sender != vaultCore) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyKeeperOrAuthorized() {
        if (!initialized) revert NotInitialized();
        if (!hasRole(KEEPER_ROLE, msg.sender) && msg.sender != vaultCore) {
            revert UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /* ─────────────────────────── Registration ─────────────────────────── */

    /// @notice Cache a user's profile and deposit for target computation.
    ///         Called by VaultCore at depositWithProfile.
    function registerUser(address user, uint8 profile, uint256 hypeDeposit)
        external
        onlyVaultCore
    {
        if (registered[user])     revert UserAlreadyRegistered(user);
        if (profile > 1)          revert UnknownProfile(profile);

        userProfile[user] = profile;
        userDeposit[user] = hypeDeposit;
        registered[user]  = true;

        emit UserRegistered(user, profile, hypeDeposit);
    }

    /// @notice Clear a user's registration on full repay/close. Releases reserve
    ///         and credit balances back to the user (caller forwards them).
    function unregisterUser(address user) external onlyVaultCore {
        if (!registered[user]) revert UserNotRegistered(user);

        delete userProfile[user];
        delete userDeposit[user];
        delete registered[user];
        delete smoothingReserves[user];
        delete spotReserves[user];
        delete creditBalances[user];
        // accumulatedPaydown is preserved as historical record.

        emit UserUnregistered(user);
    }

    /* ─────────────────────────── Accrual & distribution ─────────────────────────── */

    /// @notice Distribute funding income for one user across all four
    ///         destinations per Tech Spec §3.4. Idempotent on zero income.
    function accrueAndDistribute(address user, uint256 fundingIncomeUsd)
        external
        onlyKeeperOrAuthorized
    {
        if (!registered[user])    revert UserNotRegistered(user);
        if (fundingIncomeUsd == 0) return;

        uint256 currentDebt = IPositionManagerMin(positionManager).getHyperLendDebt(user);
        uint256 remaining   = fundingIncomeUsd;

        // 1. Insurance pool — fixed cut
        uint256 insuranceCut = (fundingIncomeUsd * INSURANCE_RATE_BPS) / BPS_DENOM;
        insurancePoolBalance += insuranceCut;
        remaining            -= insuranceCut;

        // 2. Spot HYPE reserve — top up to profile target
        (uint256 spotTopUpUsdc, uint256 spotTopUpHype) = _topUpSpotReserve(user, remaining);
        remaining -= spotTopUpUsdc;

        // 3. Smoothing reserve — top up to target
        uint256 smoothingTopUp = _topUpSmoothingReserve(user, currentDebt, remaining);
        remaining -= smoothingTopUp;

        // 4. Principal paydown — residual
        (uint256 paydown, uint256 overage) = _applyPaydown(user, currentDebt, remaining);

        emit IncomeDistributed(
            user,
            fundingIncomeUsd,
            insuranceCut,
            spotTopUpUsdc,
            spotTopUpHype,
            smoothingTopUp,
            paydown,
            overage
        );
    }

    /// @notice Inverse path — drain smoothing reserve to cover borrow expense
    ///         during dry funding stretches. Returns covered/uncovered split.
    /// @dev    Uncovered portion is reported back; caller (keeper or VaultCore)
    ///         is responsible for handling it (typically by allowing borrow
    ///         APR to accrue against the loan).
    function coverBorrowExpense(address user, uint256 expenseUsd)
        external
        onlyKeeperOrAuthorized
        returns (uint256 covered, uint256 uncovered)
    {
        if (!registered[user]) revert UserNotRegistered(user);
        if (expenseUsd == 0)   return (0, 0);

        uint256 reserve = smoothingReserves[user];
        if (reserve >= expenseUsd) {
            covered                  = expenseUsd;
            smoothingReserves[user]  = reserve - expenseUsd;
            uncovered                = 0;
        } else {
            covered                  = reserve;
            smoothingReserves[user]  = 0;
            uncovered                = expenseUsd - covered;
        }

        emit BorrowExpenseCovered(user, expenseUsd, covered, uncovered);
    }

    /* ─────────────────────────── Internal split helpers ─────────────────────────── */

    function _topUpSpotReserve(address user, uint256 remainingUsd)
        internal
        returns (uint256 spotTopUpUsdc, uint256 spotTopUpHype)
    {
        if (remainingUsd == 0) return (0, 0);

        uint256 targetHype  = getSpotReserveTarget(user);
        uint256 currentHype = spotReserves[user];
        if (targetHype <= currentHype) return (0, 0);

        uint256 deficitHype = targetHype - currentHype;
        uint256 deficitUsdc = _hypeToUsdc(deficitHype);
        spotTopUpUsdc       = remainingUsd < deficitUsdc ? remainingUsd : deficitUsdc;
        spotTopUpHype       = _usdcToHype(spotTopUpUsdc);

        spotReserves[user] += spotTopUpHype;

        // (Real impl: positionManager.swapUsdcToHype(spotTopUpUsdc) and verify amounts.)
    }

    function _topUpSmoothingReserve(address user, uint256 currentDebt, uint256 remainingUsd)
        internal
        returns (uint256 smoothingTopUp)
    {
        if (remainingUsd == 0) return 0;

        uint256 target  = getSmoothingTarget(user, currentDebt);
        uint256 current = smoothingReserves[user];
        if (target <= current) return 0;

        uint256 deficit = target - current;
        smoothingTopUp  = remainingUsd < deficit ? remainingUsd : deficit;

        smoothingReserves[user] += smoothingTopUp;
    }

    function _applyPaydown(address user, uint256 currentDebt, uint256 remainingUsd)
        internal
        returns (uint256 paydown, uint256 overage)
    {
        if (remainingUsd == 0) return (0, 0);

        if (remainingUsd > currentDebt) {
            paydown = currentDebt;
            overage = remainingUsd - currentDebt;
            creditBalances[user]    += overage;
        } else {
            paydown = remainingUsd;
            overage = 0;
        }
        accumulatedPaydown[user] += paydown;

        // (Real impl: callback to VaultCore.applyPaydown(user, paydown) so the
        //  hyperLendDebtUsd field shrinks. For V1 we accumulate locally and
        //  VaultCore syncs on a later step.)
    }

    /* ─────────────────────────── Targets (views) ─────────────────────────── */

    /// @notice Profile-driven spot HYPE reserve target in HYPE wei.
    function getSpotReserveTarget(address user) public view returns (uint256) {
        if (!registered[user]) return 0;
        uint16 splitBps = userProfile[user] == 0 ? CONSERVATIVE_RESERVE_BPS : RISKY_RESERVE_BPS;
        return (userDeposit[user] * uint256(splitBps)) / BPS_DENOM;
    }

    /// @notice Smoothing reserve target in USDC: months × debt × APR / 12.
    function getSmoothingTarget(address user, uint256 currentDebtUsd) public view returns (uint256) {
        if (!registered[user]) return 0;
        uint16 months = userProfile[user] == 0 ? CONSERVATIVE_SMOOTHING_MONTHS : RISKY_SMOOTHING_MONTHS;
        return (currentDebtUsd * uint256(HYPERLEND_BORROW_APR_BPS) * uint256(months)) / (BPS_DENOM * 12);
    }

    /// @notice Convenience snapshot for the dashboard.
    function getUserSnapshot(address user) external view returns (
        bool    isRegistered,
        uint8   profile,
        uint256 hypeDeposit,
        uint256 spotReserveHype,
        uint256 spotReserveTargetHype,
        uint256 smoothingReserveUsd,
        uint256 creditBalanceUsd,
        uint256 paydownAccumulatedUsd
    ) {
        isRegistered           = registered[user];
        profile                = userProfile[user];
        hypeDeposit            = userDeposit[user];
        spotReserveHype        = spotReserves[user];
        spotReserveTargetHype  = getSpotReserveTarget(user);
        smoothingReserveUsd    = smoothingReserves[user];
        creditBalanceUsd       = creditBalances[user];
        paydownAccumulatedUsd  = accumulatedPaydown[user];
    }

    /* ─────────────────────────── Internal price math ─────────────────────────── */

    function _hypeToUsdc(uint256 hypeWei) internal pure returns (uint256) {
        return (hypeWei * STUB_HYPE_PRICE_USD) / 1e12;
    }

    function _usdcToHype(uint256 usdcAmount) internal pure returns (uint256) {
        return (usdcAmount * 1e12) / STUB_HYPE_PRICE_USD;
    }
}