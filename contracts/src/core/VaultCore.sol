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
        uint16  leverageBps
    ) external returns (uint256 marginWithdrawnUsd);
}

interface IRiskManagerMin {
    function getPerpLeverageForProfile(uint8 profile) external view returns (uint16 leverageBps);
    function getReserveSplitForProfile(uint8 profile) external view returns (uint16 reserveBps);
    function getHyperLendTargetLtv(uint8 profile)    external view returns (uint16 ltvBps);
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

    /* ─── Constants ─── */
    uint16 public constant MAX_LEVERAGE_BPS         = 200000;    // 20x absolute ceiling
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

    /* ─── Storage ─── */
    VaultState public vaultState;
    mapping(address => UserPosition) public positions;
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    address[] public activeUsers;
    mapping(address => uint256) private _activeUserIndex;

    uint256 public accruedProtocolFeesHype;
    uint64  public lastFeeAccrual;

    /* ─── Events ─── */
    event PositionOpened(
        address indexed user,
        uint256          hypeDeposit,
        uint256          sharesMinted,
        bytes32 indexed  perpMarketId,
        uint16           perpLeverageBps,
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

    /* ─── Errors ─── */
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
    error InvalidPerpMarket();

    /* ─── Constructor ─── */
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
        uint16  perpLeverageBps    = IRiskManagerMin(riskManager).getPerpLeverageForProfile(uint8(profile));
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

    /* ─── Override standard ERC-4626 entry points ─── */
    function deposit(uint256, address) public pure override returns (uint256) {
        revert UseDepositWithProfile();
    }
    function mint(uint256, address) public pure override returns (uint256) {
        revert UseDepositWithProfile();
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
}