// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title PositionManager
/// @notice Executes leg-level actions; treats HYPE spot, both perp legs, and
///         the Sentiment borrow as a unified cross-margin account per user.
/// @dev See Technical Spec §2.2 and §3.3.
contract PositionManager {
    address public immutable strategyEngine;
    address public immutable hyperLendAdapter;
    address public immutable sentimentAdapter;
    address public immutable hyperCoreAdapter;
    address public immutable hyperSwapAdapter;

    struct LegPosition {
        bytes32 marketId;
        uint8   side;           // 1 = long, 2 = short
        uint256 marginUsd;
        uint256 notionalUsd;
        uint256 entryPx;
        int256  cumulativeFundingUsd;
        uint64  openedAt;
    }

    mapping(address => LegPosition) public hypeLeg;          // user => HYPE leg
    mapping(address => LegPosition[]) public fundingLeg;     // user => funding positions

    constructor(
        address _strategyEngine,
        address _hyperLend,
        address _sentiment,
        address _hyperCore,
        address _hyperSwap
    ) {
        strategyEngine = _strategyEngine;
        hyperLendAdapter = _hyperLend;
        sentimentAdapter = _sentiment;
        hyperCoreAdapter = _hyperCore;
        hyperSwapAdapter = _hyperSwap;
    }

    // TODO: openPerpPosition(user, marketId, side, marginUsd, leverage)
    // TODO: closePerpPosition(user, idx) — by index in fundingLeg array
    // TODO: supplyToHyperLend(user, amount), borrowFromHyperLend(user, amount)
    // TODO: openSentimentAccount(user), borrowFromSentiment(user, amount)
    // TODO: swapUsdcToHype(amount, minOut), swapHypeToUsdc(amount, minOut)
    // TODO: rotation primitive: closeFundingPosition + openFundingPosition atomically
}