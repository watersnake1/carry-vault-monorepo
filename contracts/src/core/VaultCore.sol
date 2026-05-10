// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { ERC4626 }          from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 }            from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 }           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }        from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl }    from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable }         from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard }  from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { OracleLayer }     from "../../src/core/OracleLayer.sol";



/* ─────────────────────────────────────────────────────────────────────────
   Minimal peer-contract interfaces
   ──────────────────────────────────────────────────────────────────────── */

interface IStrategyEngineMin {
    function currentPerpMarket() external view returns (bytes32 marketId);
}

interface IPositionManagerMin {
    function supplyToHyperLendAndBorrow(
        address user,
        uint256 hypeAmount,
        uint16  targetLtvBps
    ) external returns (uint256 usdcBorrowed);

    function openPerpLegAndExtractMargin(
        address user,
        bytes32 marketId,
        uint256 hypeAmount,
        uint32  leverageBps
    ) external returns (uint256 marginWithdrawnUsd);
    function closePerpLegFull(address user) external returns (uint256 hypeReturned);
    function withdrawAllPerpMargin(address user) external returns (uint256 marginUsd);
    function repayHyperLendFromCollateral(address user) external returns (uint256 hypeReturned);
}

interface IOracleLayerMin {
    function maintenanceMarginBps(bytes32 marketId) external view returns (uint16);
    function hypePriceUsdc() external view returns (uint256);
}

interface IRiskManagerMin {
    function getPerpLeverageForProfile(uint8 profile) external view returns (uint32 leverageBps);
    function getReserveSplitForProfile(uint8 profile) external view returns (uint16 reserveBps);
    function getHyperLendTargetLtv(uint8 profile)    external view returns (uint16 ltvBps);
    function requiresCascade(address user)           external view returns (bool);
    function executeCascade(address user)            external;
}

interface IYieldRouterMin {
    function registerUser(address user, uint8 profile, uint256 hypeDeposit) external;
    function unregisterUser(address user) external;
    function drainUserReserves(address user) external returns (uint256 totalHype);
}

/// @title  VaultCore
/// @notice ERC-4626 share accounting, NAV, deposit/withdraw flows, per-user
///         position state, and the vault-level lifecycle state machine.
/// @dev    Aligned to Strategy Overview v0.3 and Risk Framework v0.3 (Option C).
contract VaultCore is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ─── Roles ─── */
    bytes32 public constant KEEPER_ROLE        = keccak256("KEEPER_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE  = keccak256("RISK_MANAGER_ROLE");
    bytes32 public constant STRATEGY_ROLE      = keccak256("STRATEGY_ROLE");
    bytes32 public constant YIELD_ROUTER_ROLE  = keccak256("YIELD_ROUTER_ROLE");
    bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
    bytes32 public constant TREASURY_ROLE      = keccak256("TREASURY_ROLE");

    /* ─── Enums ─── */
    enum VaultLevelState { NORMAL, STRESS, EMERGENCY, WINDDOWN }
    enum LifecycleState  { NONE, OPEN, REPAYING, CLOSED, FORCE_CLOSED }
    enum RiskProfile     { CONSERVATIVE, RISKY }

    /* ─── Structs ─── */
    struct UserPosition {
        address user;
        uint64  openedAt;

        // user-chosen dials (locked at deposit)
        uint256 hypeDeposit;
        uint16  allocationSplitBps;     // % of deployable HYPE to lending leg
        uint16  reserveSplitBps;        // % of total deposit held as spot reserve (profile-driven)
        RiskProfile riskProfile;
        uint32  termPreferenceMonths;
        bytes32 perpMarketId;           // V1: hardcoded; V2: scout-selected at deposit

        // accounting (mutates over loan life)
        uint256 hyperLendDebtUsd;        // outstanding USDC debt on HyperLend
        uint256 perpMarginWithdrawnUsd;  // USDC pulled from HyperCore perp account
        uint256 spotReserveBalance;      // HYPE held in vault for cascade Stage A (in wei)
        uint256 smoothingReserveBalance; // USDC accrued for borrow-cost coverage
        uint256 creditBalance;           // overage from full paydown

        LifecycleState state;
    }

    struct WithdrawalRequest {
        address user;
        uint256 shares;
        uint64  requestedAt;
        uint64  unlockAt;
        bool    fulfilled;
    }

    struct VaultState {
        VaultLevelState state;
        uint256 totalUsdcDebtOutstanding;
        uint256 navHype;
        uint64  lastRebalance;
        uint64  lastAccrual;
        bool    depositsEnabled;
    }

    struct UserView {
        // Raw position fields
        UserPosition position;

        // ERC-4626 share state
        uint256 shares;

        // Withdrawal queue state (zeros if none queued)
        uint256 pendingWithdrawalShares;
        uint64  withdrawalUnlockAt;
        bool    hasPendingWithdrawal;
    }

    struct VaultView {
        VaultLevelState level;
        uint256 totalAssetsHype;
        uint256 totalSharesIssued;
        uint256 activeUsersCount;
        uint256 accumulatedProtocolFees;
        bool    depositsEnabled;
        bool    isPaused;
        // Component addresses for frontend convenience
        address strategyEngine;
        address positionManager;
        address riskManager;
        address yieldRouter;
    }

    /* ─── Constants ─── */
    uint32 public constant MAX_LEVERAGE_BPS         = 200000;    // 20x absolute ceiling
    uint16 public constant MAX_ALLOCATION_BPS       = 10000;
    uint16 public constant BPS_DENOM                = 10000;
    uint64 public constant STRESS_WITHDRAW_DELAY    = 12 hours;
    uint64 public constant MIN_REBALANCE_INTERVAL   = 60;
    uint16 public constant PERFORMANCE_FEE_BPS      = 1000;
    uint16 public constant MANAGEMENT_FEE_BPS       = 50;
    uint16 public constant HURDLE_RATE_BPS          = 500;
    uint32 public constant MIN_TERM_MONTHS          = 1;
    uint32 public constant MAX_TERM_MONTHS          = 24;
    uint256 public constant MIN_DEPOSIT_HYPE        = 1e17;      // 0.1 HYPE

    /* ─── Immutable peer refs ─── */
    address public immutable strategyEngine;
    address public immutable positionManager;
    address public immutable riskManager;
    address public immutable yieldRouter;
    IERC20  public immutable usdc;
    address public immutable oracle;

    /* ─── Storage ─── */
    VaultState public vaultState;
    mapping(address => UserPosition) public positions;
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    address[] public activeUsers;
    mapping(address => uint256) private _activeUserIndex;

    uint256 public accruedProtocolFeesHype;
    uint64  public lastFeeAccrual;

    bool public depositsEnabled = true;
    uint256 public accumulatedProtocolFees;  // denominated in USDC

    /* ─── Events ─── */
    event PositionOpened(
        address indexed user,
        uint256          hypeDeposit,
        uint256          sharesMinted,
        bytes32 indexed  perpMarketId,
        uint32           perpLeverageBps,
        uint16           allocationSplitBps,
        uint16           reserveSplitBps,
        RiskProfile      profile,
        uint32           termMonths,
        uint256          usdcFromHyperLend,
        uint256          usdcFromPerpMargin
    );
    event PositionClosed(address indexed user, uint256 hypeReturned, uint256 sharesBurned, LifecycleState finalState);
    event WithdrawalQueued(address indexed user, uint256 shares, uint64 unlockAt);
    event WithdrawalFulfilled(address indexed user, uint256 shares, uint256 hypeReturned);
    event RebalanceTick(uint64 timestamp, uint256 navHype);
    event StateTransition(VaultLevelState from, VaultLevelState to);
    event NavRecomputed(uint256 navHype);
    event SmoothingReserveUpdated(address indexed user, uint256 newBalance);
    event SpotReserveUpdated(address indexed user, uint256 newBalance);
    event HyperLendDebtUpdated(address indexed user, uint256 newDebt);
    event PerpMarginWithdrawnUpdated(address indexed user, uint256 newAmount);
    event CreditBalanceUpdated(address indexed user, uint256 newBalance);
    event ProtocolFeesAccrued(uint256 amountHype);
    event ProtocolFeesClaimed(address indexed to, uint256 amountHype);
    event PaydownApplied(address indexed user, uint256 amountPaid, uint256 newDebt, uint256 overageToCredit);
    event VaultStateChanged(VaultLevelState prev, VaultLevelState next);
    event DepositsEnabledChanged(bool enabled);
    event ProtocolFeesCollected(address indexed treasury, uint256 amount);
    //event ProtocolFeesAccrued(uint256 amount);
    /* ─── Errors ─── */
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error BelowMinDeposit(uint256 supplied, uint256 minimum);
    error InvalidAllocationSplit(uint16 supplied);
    error InvalidLeverage(uint32 supplied);
    error InvalidTerm(uint32 supplied);
    error DepositsDisabled();
    error VaultNotInNormalState(VaultLevelState current);
    error PositionAlreadyOpen(address user);
    error PositionNotOpen(address user);
    error WithdrawalNotReady(uint64 unlockAt, uint64 nowTs);
    error WithdrawalNotFound(address user);
    error InvalidStateTransition(VaultLevelState from, VaultLevelState to);
    error RebalanceTooSoon(uint64 lastRebalance, uint64 nowTs);
    error UnauthorizedCaller(address caller);
    error UseDepositWithProfile();
    error InvalidPerpMarket();
    error InvalidVaultState(VaultLevelState current);
    error InsufficientShares(uint256 have, uint256 want);
    error WithdrawalAlreadyQueued(address user);
    error PartialWithdrawalNotSupported(uint256 requested, uint256 available);
    error WithdrawalAlreadyFulfilled(address user);
    //error DepositsDisabled();
    error NoFeesToCollect();
    error TreasuryNotSet();

    event WithdrawalCancelled(address indexed user, uint256 shares);

    /* ─── Constructor ─── */
    constructor(
        IERC20  hype,
        IERC20  _usdc,
        address _strategyEngine,
        address _positionManager,
        address _riskManager,
        address _yieldRouter,
        address _oracle,
        address admin
    )
        ERC4626(hype)
        ERC20("Carry Vault HYPE", "xCarry")
    {
        if (address(hype)        == address(0)) revert ZeroAddress();
        if (address(_usdc)       == address(0)) revert ZeroAddress();
        if (_strategyEngine      == address(0)) revert ZeroAddress();
        if (_positionManager     == address(0)) revert ZeroAddress();
        if (_riskManager         == address(0)) revert ZeroAddress();
        if (_yieldRouter         == address(0)) revert ZeroAddress();
        if (admin                == address(0)) revert ZeroAddress();

        strategyEngine  = _strategyEngine;
        positionManager = _positionManager;
        riskManager     = _riskManager;
        yieldRouter     = _yieldRouter;
        oracle = _oracle;
        usdc            = _usdc;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(TREASURY_ROLE,      admin);
        _grantRole(STRATEGY_ROLE,      _strategyEngine);
        _grantRole(RISK_MANAGER_ROLE,  _riskManager);
        _grantRole(YIELD_ROUTER_ROLE,  _yieldRouter);

        vaultState.state            = VaultLevelState.NORMAL;
        vaultState.depositsEnabled  = true;
        vaultState.lastRebalance    = uint64(block.timestamp);
        vaultState.lastAccrual      = uint64(block.timestamp);
        lastFeeAccrual              = uint64(block.timestamp);

        // PositionManager pulls HYPE from this vault for both legs.
        hype.approve(_positionManager, type(uint256).max);
    }

    /* ─── depositWithProfile (entry point) ─── */

    /// @notice Open a Carry Vault position. Splits HYPE into spot reserve,
    ///         lending-leg supply (HyperLend), and perp-leg margin (HyperCore).
    /// @param  amount             HYPE deposited (1e18 units).
    /// @param  allocationSplitBps Of the deployable HYPE (after reserve), percent
    ///                            allocated to the lending leg.
    /// @param  profile            CONSERVATIVE or RISKY.
    /// @param  termMonths         User's intended borrow horizon, 1–24.
    /// @return shares             xCarry shares minted to the caller.
    function depositWithProfile(
        uint256 amount,
        uint16  allocationSplitBps,
        RiskProfile profile,
        uint32  termMonths
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // ── 1. Vault state ──
        if (vaultState.state != VaultLevelState.NORMAL) revert VaultNotInNormalState(vaultState.state);
        if (!vaultState.depositsEnabled)                 revert DepositsDisabled();
        if (!depositsEnabled) revert DepositsDisabled();

        // ── 2. User state ──
        LifecycleState s = positions[msg.sender].state;
        if (s == LifecycleState.OPEN || s == LifecycleState.REPAYING) {
            revert PositionAlreadyOpen(msg.sender);
        }

        // ── 3. Input validation ──
        if (amount == 0)                              revert ZeroAmount();
        if (amount < MIN_DEPOSIT_HYPE)                revert BelowMinDeposit(amount, MIN_DEPOSIT_HYPE);
        if (allocationSplitBps > MAX_ALLOCATION_BPS)  revert InvalidAllocationSplit(allocationSplitBps);
        if (termMonths < MIN_TERM_MONTHS || termMonths > MAX_TERM_MONTHS) revert InvalidTerm(termMonths);

        // ── 4. Resolve profile-driven parameters from peers ──
        uint32  perpLeverageBps    = IRiskManagerMin(riskManager).getPerpLeverageForProfile(uint8(profile));
        uint16  reserveSplitBps    = IRiskManagerMin(riskManager).getReserveSplitForProfile(uint8(profile));
        uint16  hyperLendTargetLtv = IRiskManagerMin(riskManager).getHyperLendTargetLtv(uint8(profile));
        bytes32 perpMarketId       = IStrategyEngineMin(strategyEngine).currentPerpMarket();
        if (perpLeverageBps == 0 || perpLeverageBps > MAX_LEVERAGE_BPS) revert InvalidLeverage(perpLeverageBps);
        if (perpMarketId == bytes32(0))                                  revert InvalidPerpMarket();

        // ── 5. Compute HYPE allocations ──
        uint256 reserveAmount = (amount * reserveSplitBps) / BPS_DENOM;
        uint256 deployable    = amount - reserveAmount;
        uint256 lendingAmount = (deployable * allocationSplitBps) / BPS_DENOM;
        uint256 perpAmount    = deployable - lendingAmount;

        // ── 6. Share calculation ──
        shares = previewDeposit(amount);
        if (shares == 0) revert ZeroShares();

        // ── 7. Pull HYPE & mint shares (OZ ERC-4626 internal flow) ──
        _deposit(msg.sender, msg.sender, amount, shares);

        // ── 8. Record user position (debts mirrored after peer calls) ──
        positions[msg.sender] = UserPosition({
            user:                    msg.sender,
            openedAt:                uint64(block.timestamp),
            hypeDeposit:             amount,
            allocationSplitBps:      allocationSplitBps,
            reserveSplitBps:         reserveSplitBps,
            riskProfile:             profile,
            termPreferenceMonths:    termMonths,
            perpMarketId:            perpMarketId,
            hyperLendDebtUsd:        0,
            perpMarginWithdrawnUsd:  0,
            spotReserveBalance:      reserveAmount,
            smoothingReserveBalance: 0,
            creditBalance:           0,
            state:                   LifecycleState.OPEN
        });
        _addActiveUser(msg.sender);
        // Register with YieldRouter for funding-income distribution.
        IYieldRouterMin(yieldRouter).registerUser(msg.sender, uint8(profile), amount);

        // ── 9. Open lending leg via PositionManager ──
        uint256 usdcFromHyperLend = 0;
        if (lendingAmount > 0) {
            usdcFromHyperLend = IPositionManagerMin(positionManager).supplyToHyperLendAndBorrow(
                msg.sender, lendingAmount, hyperLendTargetLtv
            );
        }

        // ── 10. Open perp leg via PositionManager (HYPE→USDC, perp open, leverage, margin withdraw) ──
        uint256 usdcFromPerpMargin = 0;
        if (perpAmount > 0) {
            usdcFromPerpMargin = IPositionManagerMin(positionManager).openPerpLegAndExtractMargin(
                msg.sender, perpMarketId, perpAmount, perpLeverageBps
            );
        }

        // ── 11. Mirror debts into per-user state ──
        positions[msg.sender].hyperLendDebtUsd       = usdcFromHyperLend;
        positions[msg.sender].perpMarginWithdrawnUsd = usdcFromPerpMargin;
        vaultState.totalUsdcDebtOutstanding         += usdcFromHyperLend + usdcFromPerpMargin;

        emit PositionOpened(
            msg.sender,
            amount,
            shares,
            perpMarketId,
            perpLeverageBps,
            allocationSplitBps,
            reserveSplitBps,
            profile,
            termMonths,
            usdcFromHyperLend,
            usdcFromPerpMargin
        );
    }

    /// @notice Voluntary unwind. Closes the perp leg, repays HyperLend from
    ///         collateral, returns all HYPE (collateral + perp + spot reserve)
    ///         to the user, burns their xCarry shares, and unregisters them
    ///         from YieldRouter.
    function repay()
        external
        nonReentrant
        whenNotPaused
    {
        UserPosition storage pos = positions[msg.sender];
        if (pos.state != LifecycleState.OPEN) revert PositionNotOpen(msg.sender);

        // 1. Mark transitioning to prevent reentry on the same position.
        pos.state = LifecycleState.REPAYING;

        uint256 totalDebtBefore = pos.hyperLendDebtUsd + pos.perpMarginWithdrawnUsd;
        uint256 spotReserve     = pos.spotReserveBalance;
        uint256 sharesToBurn    = balanceOf(msg.sender);

        // 2. Close perp leg → returns originalHypeAmount, transfers HYPE to vault.
        uint256 hypeFromPerp = IPositionManagerMin(positionManager).closePerpLegFull(msg.sender);

        // 3. Withdraw remaining perp margin (state cleanup; no HYPE in V1 stub).
        IPositionManagerMin(positionManager).withdrawAllPerpMargin(msg.sender);

        // 4. Repay HyperLend → returns hypeSupplied, transfers HYPE to vault.
        uint256 hypeFromLending = IPositionManagerMin(positionManager).repayHyperLendFromCollateral(msg.sender);

        // 5. Total HYPE owed back to user = perp + lending + reserve.
        uint256 totalHype = hypeFromPerp + hypeFromLending + spotReserve;

        // 6. Burn shares. ERC-4626 share burn happens before transferring assets out.
        if (sharesToBurn > 0) {
            _burn(msg.sender, sharesToBurn);
        }

        // 7. Update vault-wide totals and clear per-user accounting.
        vaultState.totalUsdcDebtOutstanding -= totalDebtBefore;

        pos.hyperLendDebtUsd        = 0;
        pos.perpMarginWithdrawnUsd  = 0;
        pos.spotReserveBalance      = 0;
        pos.smoothingReserveBalance = 0;
        pos.creditBalance           = 0;
        pos.state                   = LifecycleState.CLOSED;

        // 8. Remove from active users.
        _removeActiveUser(msg.sender);

        // 9. Unregister from YieldRouter.
        IYieldRouterMin(yieldRouter).unregisterUser(msg.sender);

        // 10. Transfer all HYPE back to user.
        if (totalHype > 0) {
            IERC20(asset()).safeTransfer(msg.sender, totalHype);
        }

        emit PositionClosed(msg.sender, totalHype, sharesToBurn, LifecycleState.CLOSED);
    }

    /* ─── Override standard ERC-4626 entry points ─── */
    function deposit(uint256, address) public pure override returns (uint256) {
        revert UseDepositWithProfile();
    }
    function mint(uint256, address) public pure override returns (uint256) {
        revert UseDepositWithProfile();
    }

    /// @notice Keeper entry point. Permissionless but rate-limited. Iterates
    ///         active users and triggers cascade for any whose health crossed
    ///         the trigger threshold. Silent no-op if called too frequently or
    ///         while the vault is winding down.
    function rebalance() external {
        uint64 nowTs = uint64(block.timestamp);

        // Rate-limit: silent no-op
        if (nowTs < vaultState.lastRebalance + MIN_REBALANCE_INTERVAL) return;

        // No work during winddown
        if (vaultState.state == VaultLevelState.WINDDOWN) return;

        // Update timestamp regardless of whether cascade work happens. This makes
        // the rate limit enforce a wall-clock minimum interval.
        vaultState.lastRebalance = nowTs;

        // Iterate active users. Cascade Stage C may remove a user mid-iteration,
        // so we read activeUsers.length each loop and only advance i when the
        // current user wasn't removed.
        uint256 i = 0;
        while (i < activeUsers.length) {
            address user = activeUsers[i];

            if (positions[user].state == LifecycleState.OPEN) {
                if (IRiskManagerMin(riskManager).requiresCascade(user)) {
                    uint256 lengthBefore = activeUsers.length;
                    IRiskManagerMin(riskManager).executeCascade(user);

                    if (activeUsers.length < lengthBefore) {
                        // Stage C ran — user was removed and the slot now holds
                        // the previous-last user. Re-process index i.
                        continue;
                    }
                }
            }
            i++;
        }

        emit RebalanceTick(nowTs, vaultState.navHype);
    }

    /* Withdrawal */
    // ============================================================
    // WITHDRAWAL QUEUE (STRESS-state exit path)
    // ============================================================

    /// @notice Queue a stress-state withdrawal. Locks shares for STRESS_WITHDRAW_DELAY,
    ///         then settles via fulfillWithdraw() once the delay has elapsed.
    /// @dev    Only callable during STRESS or EMERGENCY. NORMAL-state exit goes through repay().
    function requestWithdraw(uint256 shares) external nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroAmount();

        if (vaultState.state != VaultLevelState.STRESS && vaultState.state != VaultLevelState.EMERGENCY) {
            revert InvalidVaultState(vaultState.state);
        }

        UserPosition storage pos = positions[msg.sender];
        if (pos.state != LifecycleState.OPEN) revert PositionNotOpen(msg.sender);

        WithdrawalRequest storage existing = withdrawalRequests[msg.sender];
        if (existing.requestedAt != 0 && !existing.fulfilled) {
            revert WithdrawalAlreadyQueued(msg.sender);
        }

        uint256 bal = balanceOf(msg.sender);
        if (shares != bal) revert PartialWithdrawalNotSupported(shares, bal);

        

        _transfer(msg.sender, address(this), shares);

        uint64 unlockAt = uint64(block.timestamp) + uint64(STRESS_WITHDRAW_DELAY);
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            user:        msg.sender,
            shares:      shares,
            requestedAt: uint64(block.timestamp),
            unlockAt:    unlockAt,
            fulfilled:   false
        });

        emit WithdrawalQueued(msg.sender, shares, unlockAt);
    }

    function fulfillWithdraw() external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];

        if (req.requestedAt == 0)              revert WithdrawalNotFound(msg.sender);
        if (req.fulfilled)                     revert WithdrawalAlreadyFulfilled(msg.sender);
        if (block.timestamp < req.unlockAt) {
            revert WithdrawalNotReady(req.unlockAt, uint64(block.timestamp));
        }

        UserPosition storage pos = positions[msg.sender];
        if (pos.state != LifecycleState.OPEN) revert PositionNotOpen(msg.sender);

        uint256 shares = req.shares;
        uint256 spotHype = pos.spotReserveBalance;
        pos.spotReserveBalance = 0;

        // Per-user recovery: each PM call returns exactly the HYPE attributable
        // to this user's legs and transfers it here.
        uint256 perpHype    = IPositionManagerMin(positionManager).closePerpLegFull(msg.sender);
        uint256 lendingHype = IPositionManagerMin(positionManager).repayHyperLendFromCollateral(msg.sender);
        uint256 reserves    = IYieldRouterMin(yieldRouter).drainUserReserves(msg.sender);

        uint256 totalReturn = spotHype + perpHype + lendingHype + reserves;

        _burn(address(this), shares);

        req.fulfilled = true;
        pos.state = LifecycleState.CLOSED;
        _removeActiveUser(msg.sender);

        IYieldRouterMin(yieldRouter).unregisterUser(msg.sender);

        if (totalReturn > 0) {
            IERC20(asset()).safeTransfer(msg.sender, totalReturn);
        }

        emit WithdrawalFulfilled(msg.sender, shares, totalReturn);
    }

    function cancelWithdraw() external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.requestedAt == 0) revert WithdrawalNotFound(msg.sender);
        if (req.fulfilled)        revert WithdrawalAlreadyFulfilled(msg.sender);

        uint256 shares = req.shares;
        delete withdrawalRequests[msg.sender];

        _transfer(address(this), msg.sender, shares);

        emit WithdrawalCancelled(msg.sender, shares);
    }

    /* ─── Internal helpers ─── */
    function _addActiveUser(address user) internal {
        if (_activeUserIndex[user] == 0) {
            activeUsers.push(user);
            _activeUserIndex[user] = activeUsers.length;
        }
    }

    function _removeActiveUser(address user) internal {
        uint256 idx = _activeUserIndex[user];
        if (idx == 0) return;
        uint256 lastIdx = activeUsers.length;
        if (idx != lastIdx) {
            address last = activeUsers[lastIdx - 1];
            activeUsers[idx - 1] = last;
            _activeUserIndex[last] = idx;
        }
        activeUsers.pop();
        delete _activeUserIndex[user];
    }

    /* ─────────────────────────── State setters (called by peer contracts) ─────────────────────────── */

    /// @notice Update outstanding HyperLend debt for a user.
    /// @dev Callable by StrategyEngine or YieldRouter.
    function updateHyperLendDebt(address user, uint256 newDebt) external {
        if (!hasRole(STRATEGY_ROLE, msg.sender) && !hasRole(YIELD_ROUTER_ROLE, msg.sender)) {
            revert UnauthorizedCaller(msg.sender);
        }
        UserPosition storage pos = positions[user];
        if (pos.state == LifecycleState.NONE || pos.state == LifecycleState.CLOSED) {
            revert PositionNotOpen(user);
        }

        uint256 oldDebt = pos.hyperLendDebtUsd;
        pos.hyperLendDebtUsd = newDebt;

        if (newDebt >= oldDebt) {
            vaultState.totalUsdcDebtOutstanding += (newDebt - oldDebt);
        } else {
            vaultState.totalUsdcDebtOutstanding -= (oldDebt - newDebt);
        }

        emit HyperLendDebtUpdated(user, newDebt);
    }

    /// @notice Update USDC withdrawn from the perp margin account.
    /// @dev StrategyEngine-only — this is the perp-leg state, not lending-leg.
    function updatePerpMarginWithdrawn(address user, uint256 newAmount)
        external
        onlyRole(STRATEGY_ROLE)
    {
        UserPosition storage pos = positions[user];
        if (pos.state == LifecycleState.NONE || pos.state == LifecycleState.CLOSED) {
            revert PositionNotOpen(user);
        }

        uint256 oldAmount = pos.perpMarginWithdrawnUsd;
        pos.perpMarginWithdrawnUsd = newAmount;

        if (newAmount >= oldAmount) {
            vaultState.totalUsdcDebtOutstanding += (newAmount - oldAmount);
        } else {
            vaultState.totalUsdcDebtOutstanding -= (oldAmount - newAmount);
        }

        emit PerpMarginWithdrawnUpdated(user, newAmount);
    }

    /// @notice Sync user's smoothing reserve mirror from YieldRouter.
    function updateSmoothingReserve(address user, uint256 newBalance)
        external
        onlyRole(YIELD_ROUTER_ROLE)
    {
        UserPosition storage pos = positions[user];
        if (pos.state == LifecycleState.NONE) revert PositionNotOpen(user);
        pos.smoothingReserveBalance = newBalance;
        emit SmoothingReserveUpdated(user, newBalance);
    }

    /// @notice Sync user's credit balance mirror from YieldRouter.
    function updateCreditBalance(address user, uint256 newBalance)
        external
        onlyRole(YIELD_ROUTER_ROLE)
    {
        UserPosition storage pos = positions[user];
        if (pos.state == LifecycleState.NONE) revert PositionNotOpen(user);
        pos.creditBalance = newBalance;
        emit CreditBalanceUpdated(user, newBalance);
    }

    /// @notice Update user's spot HYPE reserve balance.
    /// @dev Callable by YieldRouter (top-up from funding income) or RiskManager
    ///      (drawdown during cascade Stage A).
    function updateSpotReserve(address user, uint256 newBalance) external {
        if (!hasRole(YIELD_ROUTER_ROLE, msg.sender) && !hasRole(RISK_MANAGER_ROLE, msg.sender)) {
            revert UnauthorizedCaller(msg.sender);
        }
        UserPosition storage pos = positions[user];
        if (pos.state == LifecycleState.NONE) revert PositionNotOpen(user);
        pos.spotReserveBalance = newBalance;
        emit SpotReserveUpdated(user, newBalance);
    }

    /// @notice Apply a principal paydown — reduces hyperLendDebtUsd, with
    ///         any overage going to creditBalance. Convenience over raw
    ///         updateHyperLendDebt + updateCreditBalance.
    function applyPaydown(address user, uint256 amount)
        external
        onlyRole(YIELD_ROUTER_ROLE)
        returns (uint256 paid, uint256 overage)
    {
        UserPosition storage pos = positions[user];
        if (pos.state == LifecycleState.NONE || pos.state == LifecycleState.CLOSED) {
            revert PositionNotOpen(user);
        }

        uint256 currentDebt = pos.hyperLendDebtUsd;
        if (amount >= currentDebt) {
            paid                 = currentDebt;
            overage              = amount - currentDebt;
            pos.hyperLendDebtUsd = 0;
            pos.creditBalance   += overage;
            emit CreditBalanceUpdated(user, pos.creditBalance);
        } else {
            paid                 = amount;
            pos.hyperLendDebtUsd = currentDebt - amount;
        }

        vaultState.totalUsdcDebtOutstanding -= paid;

        emit HyperLendDebtUpdated(user, pos.hyperLendDebtUsd);
        emit PaydownApplied(user, paid, pos.hyperLendDebtUsd, overage);
    }

    function getUserSpotReserveBalance(address user) external view returns (uint256) {
        return positions[user].spotReserveBalance;
    }

    function getUserRiskProfile(address user) external view returns (uint8) {
        return uint8(positions[user].riskProfile);
    }

    function setVaultLevelState(VaultLevelState newState) external onlyRole(RISK_MANAGER_ROLE) {
        VaultLevelState prev = vaultState.state;
        vaultState.state = newState;
        emit VaultStateChanged(prev, newState);
    }

    /// @notice Pause user-facing entry points. Existing positions remain operable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Toggle new deposits without pausing repay/withdraw paths.
    function setDepositsEnabled(bool enabled) external onlyRole(PAUSER_ROLE) {
        depositsEnabled = enabled;
        emit DepositsEnabledChanged(enabled);
    }

    /// @notice YieldRouter calls this when funneling protocol's cut of funding income.
    /// @dev    Stored in USDC. Caller should have already transferred USDC to the vault.
    function accrueProtocolFees(uint256 amount) external onlyRole(YIELD_ROUTER_ROLE) {
        accumulatedProtocolFees += amount;
        emit ProtocolFeesAccrued(amount);
    }

    /// @notice Sweep accumulated USDC fees to the treasury holder.
    function collectProtocolFees(address treasury) external onlyRole(TREASURY_ROLE) {
        if (treasury == address(0)) revert TreasuryNotSet();
        uint256 amount = accumulatedProtocolFees;
        if (amount == 0) revert NoFeesToCollect();

        accumulatedProtocolFees = 0;
        usdc.safeTransfer(treasury, amount);
        //IERC20(usdc()).safeTransfer(treasury, amount);

        emit ProtocolFeesCollected(treasury, amount);
    }

    /// @notice RiskManager-only forced unwind. Mirrors repay() but unilateral
    ///         and sets state to FORCE_CLOSED.
    function forceClose(address user)
        external
        onlyRole(RISK_MANAGER_ROLE)
        nonReentrant
        {
            UserPosition storage pos = positions[user];
            if (pos.state != LifecycleState.OPEN && pos.state != LifecycleState.REPAYING) {
                revert PositionNotOpen(user);
            }

            pos.state = LifecycleState.REPAYING;     // intermediate

            uint256 totalDebtBefore = pos.hyperLendDebtUsd + pos.perpMarginWithdrawnUsd;
            uint256 spotReserve     = pos.spotReserveBalance;
            uint256 sharesToBurn    = balanceOf(user);

            // Close perp + repay HyperLend; PM transfers HYPE back to vault
            uint256 hypeFromPerp    = IPositionManagerMin(positionManager).closePerpLegFull(user);
            IPositionManagerMin(positionManager).withdrawAllPerpMargin(user);
            uint256 hypeFromLending = IPositionManagerMin(positionManager).repayHyperLendFromCollateral(user);

            uint256 totalHype = hypeFromPerp + hypeFromLending + spotReserve;

            if (sharesToBurn > 0) {
                _burn(user, sharesToBurn);
            }

            vaultState.totalUsdcDebtOutstanding -= totalDebtBefore;

            pos.hyperLendDebtUsd        = 0;
            pos.perpMarginWithdrawnUsd  = 0;
            pos.spotReserveBalance      = 0;
            pos.smoothingReserveBalance = 0;
            pos.creditBalance           = 0;
            pos.state                   = LifecycleState.FORCE_CLOSED;

            _removeActiveUser(user);

            IYieldRouterMin(yieldRouter).unregisterUser(user);

            if (totalHype > 0) {
                IERC20(asset()).safeTransfer(user, totalHype);
            }

            emit PositionClosed(user, totalHype, sharesToBurn, LifecycleState.FORCE_CLOSED);
        }

    /// @notice Real NAV in HYPE. Sums each active user's position components.
    /// @dev    Approximation: uses recorded position state + reserves. Doesn't include
    ///         unrealized perp PnL beyond what's reflected in margin-withdrawn USD.
    /* OLD VER
    function totalAssets() public view override returns (uint256 totalHype) {
        uint256 hypeUsd = IOracleLayerMin(oracle).hypePriceUsdc(); // USDC per HYPE, 1e6 scale

        uint256 n = activeUsers.length;
        for (uint256 i = 0; i < n; i++) {
            address user = activeUsers[i];
            UserPosition storage pos = positions[user];
            if (pos.state != LifecycleState.OPEN) continue;

            // Lending-leg HYPE collateral: original HYPE less anything already paid down
            // For V1 we treat the deposited HYPE minus the spot reserve as on-protocol collateral.
            uint256 collateralHype = pos.hypeDeposit - pos.spotReserveBalance;

            // Subtract HYPE-equivalent of HyperLend debt (debt is USDC-denominated)
            uint256 debtHype = (pos.hyperLendDebtUsd * 1e18) / hypeUsd;

            // Add back perp margin (still vault's economic value, just routed through HC)
            uint256 perpMarginHype = (pos.perpMarginWithdrawnUsd * 1e18) / hypeUsd;

            // Spot reserve is held in HYPE
            uint256 spotHype = pos.spotReserveBalance;

            // Smoothing + credit are USDC; convert
            uint256 smoothingCreditHype =
                ((pos.smoothingReserveBalance + pos.creditBalance) * 1e18) / hypeUsd;

            // Net contribution
            if (collateralHype + perpMarginHype + spotHype + smoothingCreditHype > debtHype) {
                totalHype += (collateralHype + perpMarginHype + spotHype + smoothingCreditHype) - debtHype;
            }
            // If underwater, contributes 0 (don't go negative)
        }

        // Add idle HYPE in vault not attributed to any active user (e.g. recovered but not paid out)
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        totalHype += idle;
    }
    */
    /// @notice Real NAV in HYPE. Sums all HYPE physically held by protocol contracts.
    /// @dev    V1: doesn't include unrealized perp PnL (USDC-denominated on HC) or
    ///         accumulated USDC protocol fees. Sufficient for share pricing while
    ///         all HYPE flows route through vault/PM/YR.
    function totalAssets() public view override returns (uint256) {
        IERC20 hypeToken = IERC20(asset());
        return hypeToken.balanceOf(address(this))
            + hypeToken.balanceOf(positionManager)
            + hypeToken.balanceOf(yieldRouter);
    }

    /// @notice Full position record for a user. Returns a zeroed struct if no position.
    function getUserPosition(address user) external view returns (UserPosition memory) {
        return positions[user];
    }

    /// @notice Composite view: position + shares + withdrawal queue state.
    function getUserView(address user) external view returns (UserView memory v) {
        v.position = positions[user];
        v.shares   = balanceOf(user);

        WithdrawalRequest storage req = withdrawalRequests[user];
        if (req.requestedAt != 0 && !req.fulfilled) {
            v.pendingWithdrawalShares = req.shares;
            v.withdrawalUnlockAt      = req.unlockAt;
            v.hasPendingWithdrawal    = true;
        }
    }

    /// @notice Number of users with currently active positions.
    function getActiveUsersCount() external view returns (uint256) {
        return activeUsers.length;
    }

    /// @notice Full active-user roster. Use sparingly — O(n) memory copy.
    function getActiveUsers() external view returns (address[] memory) {
        return activeUsers;
    }

    /// @notice Vault-level metrics for dashboards.
    function getVaultView() external view returns (VaultView memory v) {
        v.level                   = vaultState.state;
        v.totalAssetsHype         = totalAssets();
        v.totalSharesIssued       = totalSupply();
        v.activeUsersCount        = activeUsers.length;
        v.accumulatedProtocolFees = accumulatedProtocolFees;
        v.depositsEnabled         = depositsEnabled;
        v.isPaused                = paused();
        v.strategyEngine          = strategyEngine;
        v.positionManager         = positionManager;
        v.riskManager             = riskManager;
        v.yieldRouter             = yieldRouter;
    }
}