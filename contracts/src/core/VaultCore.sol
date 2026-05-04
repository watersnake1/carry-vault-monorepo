// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { ERC4626 }          from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 }            from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 }           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }        from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl }    from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable }         from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard }  from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* ─────────────────────────────────────────────────────────────────────────
   Minimal peer-contract interfaces
   Using uint8 for enum boundaries to keep these decoupled from VaultCore's
   own enum definitions and avoid circular imports.
   ──────────────────────────────────────────────────────────────────────── */

interface IStrategyEngineMin {
    function openHypeLeg(address user, uint8 direction, uint256 marginHype, uint16 leverageBps) external;
    function activateUserFundingLeg(address user, uint256 marginHype) external;
}

interface IPositionManagerMin {
    function openSentimentAndBorrow(address user) external returns (uint256 usdcBorrowed);
}

interface IRiskManagerMin {
    function getHypeLegLeverageForProfile(uint8 profile) external view returns (uint16 leverageBps);
}

/// @title  VaultCore
/// @notice ERC-4626 share accounting, NAV, deposit/withdraw flows, per-user
///         position state, and the vault-level lifecycle state machine.
contract VaultCore is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ─────────────────────────── Roles ─────────────────────────── */

    bytes32 public constant KEEPER_ROLE        = keccak256("KEEPER_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE  = keccak256("RISK_MANAGER_ROLE");
    bytes32 public constant STRATEGY_ROLE      = keccak256("STRATEGY_ROLE");
    bytes32 public constant YIELD_ROUTER_ROLE  = keccak256("YIELD_ROUTER_ROLE");
    bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
    bytes32 public constant TREASURY_ROLE      = keccak256("TREASURY_ROLE");

    /* ─────────────────────────── Enums ─────────────────────────── */

    enum VaultLevelState  { NORMAL, STRESS, EMERGENCY, WINDDOWN }
    enum LifecycleState   { NONE, OPEN, REPAYING, CLOSED, FORCE_CLOSED }
    enum HypeLegDirection { NONE, LONG, SHORT }
    enum RiskProfile      { CONSERVATIVE, RISKY }

    /* ─────────────────────────── Structs ─────────────────────────── */

    struct UserPosition {
        address user;
        uint64  openedAt;
        uint256 hypeDeposit;
        HypeLegDirection hypeLegDirection;
        uint16  hypeLegLeverageBps;
        uint16  allocationSplitBps;
        RiskProfile riskProfile;
        uint32  termPreferenceMonths;
        uint256 usdcDebt;
        uint256 smoothingReserveBalance;
        uint256 creditBalance;
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

    /* ─────────────────────────── Constants ─────────────────────────── */

    uint16 public constant MAX_LEVERAGE_BPS         = 30000;
    uint16 public constant MAX_ALLOCATION_BPS       = 10000;
    uint16 public constant BPS_DENOM                = 10000;
    uint64 public constant STRESS_WITHDRAW_DELAY    = 12 hours;
    uint64 public constant MIN_REBALANCE_INTERVAL   = 60;
    uint16 public constant PERFORMANCE_FEE_BPS      = 1000;
    uint16 public constant MANAGEMENT_FEE_BPS       = 50;
    uint16 public constant HURDLE_RATE_BPS          = 500;

    // New: term bounds and minimum deposit
    uint32 public constant MIN_TERM_MONTHS          = 1;
    uint32 public constant MAX_TERM_MONTHS          = 24;
    uint256 public constant MIN_DEPOSIT_HYPE        = 1e17;   // 0.1 HYPE

    /* ────────────────────── Immutable peer refs ────────────────────── */

    address public immutable strategyEngine;
    address public immutable positionManager;
    address public immutable riskManager;
    address public immutable yieldRouter;
    IERC20  public immutable usdc;

    /* ─────────────────────────── Storage ─────────────────────────── */

    VaultState public vaultState;
    mapping(address => UserPosition) public positions;
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    address[] public activeUsers;
    mapping(address => uint256) private _activeUserIndex;

    uint256 public accruedProtocolFeesHype;
    uint64  public lastFeeAccrual;

    /* ─────────────────────────── Events ─────────────────────────── */

    event PositionOpened(
        address indexed user,
        uint256          hypeDeposit,
        uint256          sharesMinted,
        HypeLegDirection direction,
        uint16           leverageBps,
        uint16           allocationSplitBps,
        RiskProfile      profile,
        uint32           termMonths,
        uint256          usdcDelivered
    );
    event PositionClosed(address indexed user, uint256 hypeReturned, uint256 sharesBurned, LifecycleState finalState);
    event WithdrawalQueued(address indexed user, uint256 shares, uint64 unlockAt);
    event WithdrawalFulfilled(address indexed user, uint256 shares, uint256 hypeReturned);
    event RebalanceTick(uint64 timestamp, uint256 navHype);
    event StateTransition(VaultLevelState from, VaultLevelState to);
    event NavRecomputed(uint256 navHype);
    event SmoothingReserveUpdated(address indexed user, uint256 newBalance);
    event UsdcDebtUpdated(address indexed user, uint256 newDebt);
    event CreditBalanceUpdated(address indexed user, uint256 newBalance);
    event ProtocolFeesAccrued(uint256 amountHype);
    event ProtocolFeesClaimed(address indexed to, uint256 amountHype);

    /* ─────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error BelowMinDeposit(uint256 supplied, uint256 minimum);
    error InvalidAllocationSplit(uint16 supplied);
    error InvalidLeverage(uint16 supplied);
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

    /* ─────────────────────────── Constructor ─────────────────────────── */

    constructor(
        IERC20  hype,
        IERC20  _usdc,
        address _strategyEngine,
        address _positionManager,
        address _riskManager,
        address _yieldRouter,
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

        // Allow PositionManager to pull HYPE from this vault for leg margin.
        // Trust is implicit via the immutable reference.
        hype.approve(_positionManager, type(uint256).max);
    }

    /* ──────────────────────── Deposit (entry point) ──────────────────────── */

    /// @notice Open a Carry Vault position with all four user dials. Pulls HYPE
    ///         from the caller, mints xCarry shares, opens HYPE and funding
    ///         legs via StrategyEngine, and delivers borrowed USDC to the user.
    /// @param  amount             HYPE deposited (in 1e18 units).
    /// @param  direction          NONE / LONG / SHORT — direction of the HYPE leg.
    /// @param  allocationSplitBps % of margin to the HYPE leg (0 to 10000).
    /// @param  profile            CONSERVATIVE or RISKY. Determines leverage and caps.
    /// @param  termMonths         User's intended borrow horizon.
    /// @return shares             xCarry shares minted to the caller.
    function depositWithProfile(
        uint256 amount,
        HypeLegDirection direction,
        uint16 allocationSplitBps,
        RiskProfile profile,
        uint32 termMonths
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // ── 1. Vault state checks ──
        if (vaultState.state != VaultLevelState.NORMAL) revert VaultNotInNormalState(vaultState.state);
        if (!vaultState.depositsEnabled)                 revert DepositsDisabled();
        if (positions[msg.sender].state != LifecycleState.NONE && positions[msg.sender].state != LifecycleState.CLOSED) {
            revert PositionAlreadyOpen(msg.sender);
        }

        // ── 2. User state check ──
        if (positions[msg.sender].state == LifecycleState.OPEN) {
            revert PositionAlreadyOpen(msg.sender);
        }

        // ── 3. Input validation ──
        if (amount == 0)                                  revert ZeroAmount();
        if (amount < MIN_DEPOSIT_HYPE)                    revert BelowMinDeposit(amount, MIN_DEPOSIT_HYPE);
        if (allocationSplitBps > MAX_ALLOCATION_BPS)      revert InvalidAllocationSplit(allocationSplitBps);
        if (termMonths < MIN_TERM_MONTHS || termMonths > MAX_TERM_MONTHS) revert InvalidTerm(termMonths);

        // ── 4. Resolve leverage from the chosen profile (canonical source: RiskManager) ──
        uint16 leverageBps = IRiskManagerMin(riskManager).getHypeLegLeverageForProfile(uint8(profile));
        if (leverageBps == 0 || leverageBps > MAX_LEVERAGE_BPS) revert InvalidLeverage(leverageBps);

        // ── 5. Share calculation ──
        shares = previewDeposit(amount);
        if (shares == 0) revert ZeroShares();

        // ── 6. Pull HYPE & mint shares (OZ ERC-4626 internal flow) ──
        _deposit(msg.sender, msg.sender, amount, shares);

        // ── 7. Record user position ──
        positions[msg.sender] = UserPosition({
            user:                    msg.sender,
            openedAt:                uint64(block.timestamp),
            hypeDeposit:             amount,
            hypeLegDirection:        direction,
            hypeLegLeverageBps:      leverageBps,
            allocationSplitBps:      allocationSplitBps,
            riskProfile:             profile,
            termPreferenceMonths:    termMonths,
            usdcDebt:                0,
            smoothingReserveBalance: 0,
            creditBalance:           0,
            state:                   LifecycleState.OPEN
        });
        _addActiveUser(msg.sender);

        // ── 8. Compute leg margins (in HYPE units; downstream converts to USD) ──
        uint256 hypeLegMargin    = (amount * allocationSplitBps) / BPS_DENOM;
        uint256 fundingLegMargin = amount - hypeLegMargin;

        // ── 9. Open HYPE leg if the user chose a direction ──
        if (direction != HypeLegDirection.NONE && hypeLegMargin > 0) {
            IStrategyEngineMin(strategyEngine).openHypeLeg(
                msg.sender,
                uint8(direction),
                hypeLegMargin,
                leverageBps
            );
        }

        // ── 10. Activate funding leg (allocates user's funding margin across global portfolio) ──
        if (fundingLegMargin > 0) {
            IStrategyEngineMin(strategyEngine).activateUserFundingLeg(msg.sender, fundingLegMargin);
        }

        // ── 11. Open Sentiment account, post collateral, borrow USDC, deliver to user ──
        uint256 usdcDelivered = IPositionManagerMin(positionManager).openSentimentAndBorrow(msg.sender);

        // ── 12. Mirror the new debt into per-user state ──
        positions[msg.sender].usdcDebt = usdcDelivered;
        vaultState.totalUsdcDebtOutstanding += usdcDelivered;

        emit PositionOpened(
            msg.sender,
            amount,
            shares,
            direction,
            leverageBps,
            allocationSplitBps,
            profile,
            termMonths,
            usdcDelivered
        );
    }

    /* ────────────── Override standard ERC-4626 entry points ────────────── */

    /// @dev Disable the vanilla ERC-4626 deposit() — users must use depositWithProfile.
    function deposit(uint256, address) public pure override returns (uint256) {
        revert UseDepositWithProfile();
    }

    /// @dev Disable the vanilla ERC-4626 mint() for the same reason.
    function mint(uint256, address) public pure override returns (uint256) {
        revert UseDepositWithProfile();
    }

    /* ────────────────────── Internal helpers ────────────────────── */

    function _addActiveUser(address user) internal {
        if (_activeUserIndex[user] == 0) {
            activeUsers.push(user);
            _activeUserIndex[user] = activeUsers.length;  // 1-based
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

    /* ─────────────────────────── Future stubs ───────────────────────────

       function requestWithdraw(uint256 shares) external;
       function fulfillWithdraw() external;
       function repay() external;
       function rebalance() external;                                // keeper
       function forceClose(address user) external;                   // RiskManager
       function setVaultState(VaultLevelState newState) external;    // RiskManager
       function updateUsdcDebt(address user, uint256 newDebt) external;        // STRATEGY_ROLE / YIELD_ROUTER_ROLE
       function updateSmoothingReserve(address user, uint256 newBal) external; // YIELD_ROUTER_ROLE
       function updateCreditBalance(address user, uint256 newBal) external;    // YIELD_ROUTER_ROLE
       function pause() / unpause();
       function setDepositsEnabled(bool);
       function collectProtocolFees(address to);
       function totalAssets() override returns (uint256);            // §6 NAV — must include perp legs + PnL
       function getActiveUsersCount() returns (uint256);
       ─────────────────────────────────────────────────────────────── */
}