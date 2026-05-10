// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { IERC20 }     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOracleLayerMin {
    function hypePriceUsdc() external view returns (uint256);
}

/// @title  PositionManager
/// @notice Executes leg actions for Carry Vault: HyperLend supply/borrow,
///         HYPE↔USDC swaps, and HyperCore perp account flows. Tracks per-user
///         leg state and is the canonical source for RiskManager's reads.
/// @dev    Aligned to Technical Spec v0.3 (Option C). External protocol
///         integrations are stubbed inline; state tracking is real.
contract PositionManager {
    using SafeERC20 for IERC20;

    /* ─────────────────────────── Structs ─────────────────────────── */

    struct LendingLegState {
        uint256 hypeSupplied;     // HYPE supplied to HyperLend (1e18)
        uint256 usdcBorrowed;     // outstanding USDC debt (1e6)
        uint64  lastUpdate;
    }

    struct PerpLegState {
        bytes32 marketId;
        uint8   side;                  // 0=none, 1=long, 2=short
        uint256 marginUsd;             // current equity in perp account (1e6)
        uint256 notionalUsd;           // position notional (1e6)
        uint32  effectiveLeverageBps;  // notional/equity, in BPS
        uint64  openedAt;
        bool    isOpen;
        uint256 originalHypeAmount;
    }

    /* ─────────────────────────── Constants ─────────────────────────── */

    uint256 public constant BPS_DENOM                  = 10000;
    uint32  public constant INITIAL_PERP_LEVERAGE_BPS  = 20000;  // 2x at open
    uint8   public constant PERP_SIDE_NONE             = 0;
    uint8   public constant PERP_SIDE_LONG             = 1;
    uint8   public constant PERP_SIDE_SHORT            = 2;

    /// @dev V1 stub price. Production reads from OracleLayer.
    //uint256 public constant STUB_HYPE_PRICE_USD = 40;

    /* ─────────────────────────── Immutable refs ─────────────────────────── */

    address public immutable oracleLayer;
    IERC20  public immutable hype;
    IERC20  public immutable usdc;

    /* ─────────────────────────── Mutable refs (one-time init) ─────────────────────────── */

    address public vaultCore;
    address public riskManager;
    bool    public initialized;

    /* ─────────────────────────── Storage ─────────────────────────── */

    mapping(address => LendingLegState) public lendingLegs;
    mapping(address => PerpLegState)    public perpLegs;

    uint256 public totalHypeOnHyperLend;
    uint256 public totalUsdcDebt;
    uint256 public totalPerpNotionalUsd;
    uint256 public totalPerpMarginUsd;

    /* ─────────────────────────── Events ─────────────────────────── */

    event Initialized(address vaultCore, address riskManager);

    event HyperLendSupplied(address indexed user, uint256 hypeAmount);
    event HyperLendBorrowed(address indexed user, uint256 usdcAmount, uint16 ltvBps);
    event HyperLendRepaid(address indexed user, uint256 usdcAmount, uint256 hypeReturned);

    event PerpLegOpened(
        address indexed user,
        bytes32 indexed marketId,
        uint8   side,
        uint256 marginUsd,
        uint256 notionalUsd,
        uint32  effectiveLeverageBps
    );
    event PerpLegReduced(address indexed user, uint16 percentBps, uint256 newNotionalUsd);
    event PerpLegClosed(address indexed user, uint256 finalMarginUsd);
    event PerpMarginDeposited(address indexed user, uint256 usdcAmount, uint32 newEffectiveLeverageBps);
    event PerpMarginWithdrawn(address indexed user, uint256 usdcAmount, uint32 newEffectiveLeverageBps);

    event Swapped(address indexed initiator, bytes32 indexed direction, uint256 amountIn, uint256 amountOut);

    /* ─────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();
    error UnauthorizedCaller(address caller);
    error InvalidLeverage(uint32 supplied);
    error InvalidPercent(uint16 supplied);
    error PerpLegNotOpen(address user);
    error LendingLegNotOpen(address user);
    error InsufficientPerpMargin(uint256 requested, uint256 available);
    error ZeroAmount();

    /* ─────────────────────────── Constructor ─────────────────────────── */

    constructor(address _oracleLayer, address _hype, address _usdc) {
        if (_oracleLayer == address(0)) revert ZeroAddress();
        if (_hype        == address(0)) revert ZeroAddress();
        if (_usdc        == address(0)) revert ZeroAddress();

        oracleLayer = _oracleLayer;
        hype        = IERC20(_hype);
        usdc        = IERC20(_usdc);
    }

    /// @notice One-time initialization for VaultCore and RiskManager addresses.
    ///         Required because of the circular dependency: VaultCore takes
    ///         PositionManager in its constructor, so PM can't have VaultCore
    ///         as an immutable. Same for RiskManager.
    function initialize(address _vaultCore, address _riskManager) external {
        if (initialized)                revert AlreadyInitialized();
        if (_vaultCore   == address(0)) revert ZeroAddress();
        if (_riskManager == address(0)) revert ZeroAddress();

        vaultCore   = _vaultCore;
        riskManager = _riskManager;
        initialized = true;

        emit Initialized(_vaultCore, _riskManager);
    }

    /* ─────────────────────────── Modifiers ─────────────────────────── */

    modifier onlyVaultCore() {
        if (!initialized)              revert NotInitialized();
        if (msg.sender != vaultCore)   revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyRiskManager() {
        if (!initialized)              revert NotInitialized();
        if (msg.sender != riskManager) revert UnauthorizedCaller(msg.sender);
        _;
    }

    modifier onlyVaultOrRisk() {
        if (!initialized)              revert NotInitialized();
        if (msg.sender != vaultCore && msg.sender != riskManager) {
            revert UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /* ─────────────────────────── Lending leg (called by VaultCore at deposit) ─────────────────────────── */

    /// @notice Pull HYPE from VaultCore, "supply" to HyperLend, borrow USDC at
    ///         target LTV. Tracks state; real HyperLend integration deferred.
    function supplyToHyperLendAndBorrow(
        address user,
        uint256 hypeAmount,
        uint16  targetLtvBps
    )
        external
        onlyVaultCore
        returns (uint256 usdcBorrowed)
    {
        if (hypeAmount == 0) revert ZeroAmount();
        if (targetLtvBps == 0 || targetLtvBps > BPS_DENOM) revert InvalidLeverage(uint32(targetLtvBps));

        // 1. Pull HYPE from VaultCore (vault has approved this contract in its ctor)
        hype.safeTransferFrom(vaultCore, address(this), hypeAmount);

        // 2. (Real impl: hyperLendPool.supply(hype, hypeAmount, address(this), 0))
        //    For V1, HYPE remains on this contract as a placeholder for HyperLend custody.

        // 3. Compute borrow at target LTV using stub HYPE price
        uint256 collateralUsd = _hypeToUsdc(hypeAmount);
        usdcBorrowed = (collateralUsd * uint256(targetLtvBps)) / BPS_DENOM;

        // 4. Update state
        LendingLegState storage leg = lendingLegs[user];
        leg.hypeSupplied += hypeAmount;
        leg.usdcBorrowed += usdcBorrowed;
        leg.lastUpdate    = uint64(block.timestamp);

        totalHypeOnHyperLend += hypeAmount;
        totalUsdcDebt        += usdcBorrowed;

        // 5. (Real impl: hyperLendPool.borrow(usdc, usdcBorrowed, 2, 0, address(this));
        //                usdc.safeTransfer(user, usdcBorrowed);)
        //    For V1 we track the debt; actual USDC delivery is a no-op.

        emit HyperLendSupplied(user, hypeAmount);
        emit HyperLendBorrowed(user, usdcBorrowed, targetLtvBps);
    }

    /* ─────────────────────────── Perp leg (called by VaultCore at deposit) ─────────────────────────── */

    /// @notice Pull HYPE from VaultCore, swap to USDC, deposit as perp margin,
    ///         open the perp at INITIAL_PERP_LEVERAGE_BPS, raise leverage to
    ///         target, and withdraw freed margin. Tracks state; real HyperCore
    ///         integration deferred.
    function openPerpLegAndExtractMargin(
        address user,
        bytes32 marketId,
        uint256 hypeAmount,
        uint32  leverageBps
    )
        external
        onlyVaultCore
        returns (uint256 marginWithdrawnUsd)
    {
        if (hypeAmount == 0)                              revert ZeroAmount();
        if (leverageBps < INITIAL_PERP_LEVERAGE_BPS)      revert InvalidLeverage(leverageBps);

        // 1. Pull HYPE from VaultCore
        hype.safeTransferFrom(vaultCore, address(this), hypeAmount);

        // 2. (Real impl: HyperSwap.swapExactTokensForTokens(hypeAmount, ..., [hype, usdc], ...))
        //    For V1, compute USDC equivalent via stub price.
        uint256 marginUsd = _hypeToUsdc(hypeAmount);

        // 3. (Real impl: usdClassTransfer to HyperCore perp account; updateLeverage; placeOrder)
        //    Open notional = marginUsd * INITIAL_PERP_LEVERAGE_BPS / BPS_DENOM
        uint256 notionalUsd = (marginUsd * uint256(INITIAL_PERP_LEVERAGE_BPS)) / BPS_DENOM;

        // 4. Compute freed margin after raising to target leverage:
        //    reservedMargin = marginUsd * (INITIAL / target)
        //    withdrawn      = marginUsd - reservedMargin
        uint256 reservedMargin = (marginUsd * uint256(INITIAL_PERP_LEVERAGE_BPS)) / uint256(leverageBps);
        marginWithdrawnUsd     = marginUsd - reservedMargin;

        // 5. Record perp leg state at post-withdrawal equity
        PerpLegState storage leg = perpLegs[user];
        leg.marketId             = marketId;
        leg.side                 = PERP_SIDE_SHORT;          // V1: WTI short for funding capture
        leg.marginUsd            = reservedMargin;
        leg.notionalUsd          = notionalUsd;
        leg.effectiveLeverageBps = leverageBps;              // by construction post-withdrawal
        leg.openedAt             = uint64(block.timestamp);
        leg.isOpen               = true;
        leg.originalHypeAmount = hypeAmount;

        totalPerpNotionalUsd += notionalUsd;
        totalPerpMarginUsd   += reservedMargin;

        // 6. (Real impl: usdClassTransfer back to EVM spot, then usdc.safeTransfer(user, marginWithdrawnUsd))
        //    For V1 we track the withdrawn amount; actual delivery is a no-op.

        emit PerpLegOpened(user, marketId, leg.side, reservedMargin, notionalUsd, leverageBps);
        emit PerpMarginWithdrawn(user, marginWithdrawnUsd, leverageBps);
    }

    /* ─────────────────────────── Cascade callbacks (called by RiskManager) ─────────────────────────── */

    /// @notice Stage A — top up perp margin from a USDC injection.
    ///         Caller (RiskManager) is responsible for sourcing the USDC
    ///         (typically from Stage A swap of spot HYPE reserve).
    function depositToPerpMargin(address user, uint256 usdcAmount)
        external
        onlyRiskManager
    {
        if (usdcAmount == 0) revert ZeroAmount();
        PerpLegState storage leg = perpLegs[user];
        if (!leg.isOpen)     revert PerpLegNotOpen(user);

        leg.marginUsd            += usdcAmount;
        leg.effectiveLeverageBps  = _computeEffectiveLeverageBps(leg.notionalUsd, leg.marginUsd);

        totalPerpMarginUsd += usdcAmount;

        emit PerpMarginDeposited(user, usdcAmount, leg.effectiveLeverageBps);
    }

    /// @notice Stage B — partial close of perp position, in % of current notional.
    function closePerpPositionPartial(address user, uint16 percentBps)
        external
        onlyRiskManager
    {
        if (percentBps == 0 || percentBps > BPS_DENOM) revert InvalidPercent(percentBps);
        PerpLegState storage leg = perpLegs[user];
        if (!leg.isOpen)                                revert PerpLegNotOpen(user);

        uint256 notionalReduced = (leg.notionalUsd * uint256(percentBps)) / BPS_DENOM;
        leg.notionalUsd         -= notionalReduced;

        // Released margin = (released_notional / original_notional) * marginUsd
        //                 = marginUsd * percentBps / BPS_DENOM
        uint256 marginReleased = (leg.marginUsd * uint256(percentBps)) / BPS_DENOM;
        // Released margin stays in the perp account (deepens buffer); equity unchanged.
        // In real impl this would be a reduce-only order on HyperCore.

        leg.effectiveLeverageBps = _computeEffectiveLeverageBps(leg.notionalUsd, leg.marginUsd);

        totalPerpNotionalUsd -= notionalReduced;

        emit PerpLegReduced(user, percentBps, leg.notionalUsd);

        // Suppress unused-var warning while keeping the variable for documentation
        marginReleased; // explicit: stays in perp account; not transferred out
    }

    /// @notice Stage C — close the perp position entirely. Released margin
    ///         remains in the account for the subsequent withdraw step.
    function closePerpLegFull(address user) external onlyVaultOrRisk returns (uint256 hypeReturned) {
        PerpLegState storage leg = perpLegs[user];
        if (!leg.isOpen) revert PerpLegNotOpen(user);

        totalPerpNotionalUsd -= leg.notionalUsd;
        // marginUsd stays — caller withdraws separately.

        leg.notionalUsd          = 0;
        leg.side                 = PERP_SIDE_NONE;
        leg.effectiveLeverageBps = 0;
        leg.isOpen               = false;
        hypeReturned = leg.originalHypeAmount;
        leg.originalHypeAmount = 0;

        if (hypeReturned > 0) {
            hype.safeTransfer(vaultCore, hypeReturned);
        }

        emit PerpLegClosed(user, leg.marginUsd);
    }

    /// @notice Stage C — withdraw remaining margin from the perp account.
    ///         Returns the amount withdrawn (caller decides destination).
    function withdrawAllPerpMargin(address user)
        external
        onlyVaultOrRisk
        returns (uint256 amount)
    {
        PerpLegState storage leg = perpLegs[user];
        amount = leg.marginUsd;
        if (amount == 0) return 0;

        leg.marginUsd       = 0;
        totalPerpMarginUsd -= amount;

        emit PerpMarginWithdrawn(user, amount, 0);
    }

    /// @notice Stage C — repay HyperLend debt from the user's collateral.
    ///         Closes the lending leg fully. Returns the amount of HYPE
    ///         leftover after repayment (returned to user by caller).
    function repayHyperLendFromCollateral(address user)
        external
        onlyVaultOrRisk
        returns (uint256 hypeReturned)
    {
        LendingLegState storage leg = lendingLegs[user];
        if (leg.hypeSupplied == 0) revert LendingLegNotOpen(user);

        // (Real impl: pool.repay using collateral, withdraw the leftover HYPE)
        // V1 stub: zero out debt and return all supplied HYPE.
        hypeReturned = leg.hypeSupplied;

        totalHypeOnHyperLend -= leg.hypeSupplied;
        totalUsdcDebt        -= leg.usdcBorrowed;

        leg.hypeSupplied = 0;
        uint256 repaid   = leg.usdcBorrowed;
        leg.usdcBorrowed = 0;
        leg.lastUpdate   = uint64(block.timestamp);

        if (hypeReturned > 0) {
            hype.safeTransfer(vaultCore, hypeReturned);
        }

        emit HyperLendRepaid(user, repaid, hypeReturned);
    }

    /* ─────────────────────────── Swap helpers (callable by VaultCore or RiskManager) ─────────────────────────── */

    /// @notice Swap HYPE for USDC at the V1 stub price.
    /// @dev    Real impl routes through HyperSwap with slippage tolerance.
    function swapHypeToUsdc(uint256 hypeAmount)
        external
        onlyVaultOrRisk
        returns (uint256 usdcOut)
    {
        if (hypeAmount == 0) revert ZeroAmount();
        usdcOut = _hypeToUsdc(hypeAmount);
        emit Swapped(msg.sender, "HYPE_TO_USDC", hypeAmount, usdcOut);
    }

    /// @notice Swap USDC for HYPE at the V1 stub price.
    function swapUsdcToHype(uint256 usdcAmount)
        external
        onlyVaultOrRisk
        returns (uint256 hypeOut)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        hypeOut = _usdcToHype(usdcAmount);
        emit Swapped(msg.sender, "USDC_TO_HYPE", usdcAmount, hypeOut);
    }

    /* ─────────────────────────── Views (called by RiskManager) ─────────────────────────── */

    function getPerpNotionalUsd(address user)        external view returns (uint256) {
        return perpLegs[user].notionalUsd;
    }

    function getPerpMarketId(address user) external view returns (bytes32) {
        return perpLegs[user].marketId;
    }

    function getPerpMarginEquityUsd(address user)    external view returns (uint256) {
        return perpLegs[user].marginUsd;
    }

    function getHyperLendCollateralValue(address user) external view returns (uint256) {
        return _hypeToUsdc(lendingLegs[user].hypeSupplied);
    }

    function getHyperLendDebt(address user) external view returns (uint256) {
        return lendingLegs[user].usdcBorrowed;
    }

    function getLendingLegState(address user) external view returns (LendingLegState memory) {
        return lendingLegs[user];
    }

    function getPerpLegState(address user) external view returns (PerpLegState memory) {
        return perpLegs[user];
    }

    function hypeToUsdc(uint256 hypeWei) external view returns (uint256) {
        return _hypeToUsdc(hypeWei);
    }

    function usdcToHype(uint256 usdcAmount) external view returns (uint256) {
        return _usdcToHype(usdcAmount);
    }

    /* ─────────────────────────── Internal helpers ─────────────────────────── */

    /// @dev Convert HYPE wei → USDC units using stub price. Production reads OracleLayer.
    function _hypeToUsdc(uint256 hypeWei) internal view returns (uint256) {
        uint256 priceUsdc = IOracleLayerMin(oracleLayer).hypePriceUsdc();
        return (hypeWei * priceUsdc) / 1e18;
    }

    /// @dev Convert USDC units → HYPE wei using stub price.
    function _usdcToHype(uint256 usdcAmount) internal view returns (uint256) {
        uint256 priceUsdc = IOracleLayerMin(oracleLayer).hypePriceUsdc();
        return (usdcAmount * 1e18) / priceUsdc;
    }

    function _computeEffectiveLeverageBps(uint256 notionalUsd, uint256 marginUsd)
        internal
        pure
        returns (uint32)
    {
        if (marginUsd == 0) return 0;
        uint256 lev = (notionalUsd * BPS_DENOM) / marginUsd;
        return uint32(lev);
    }
}