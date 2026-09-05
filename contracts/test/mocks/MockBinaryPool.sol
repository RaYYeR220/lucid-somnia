// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBinaryPool} from "../../src/interfaces/IDreamDex.sol";
import {LucidTypes} from "../../src/types/LucidTypes.sol";
import {MockCollateral} from "./MockCollateral.sol";
import {MockOutcomeToken} from "./MockOutcomeToken.sol";

/// @title MockBinaryPool
/// @notice A binary CLOB that actually moves money, so the desk suite can measure what a window
/// cost instead of trusting what the desk claims it cost.
/// @dev Three live behaviours are reproduced deliberately, because each one has burned an
/// integration before: a buy escrows `quantity * unitCost / oneCollateral` and the unit cost of a
/// NO leg is `oneCollateral - price` (the venue quotes the YES side for every kind);
/// `placeBinaryOrder` can return `success = false` WITHOUT reverting; and POST_ONLY can revert
/// outright when it would cross. Every one of those is switchable from a test.
contract MockBinaryPool is IBinaryPool {
    /// @notice Raised by the revert modes, standing in for any venue-side failure.
    error PoolIsDown();
    /// @notice The venue's own error when a POST_ONLY order would take liquidity.
    error PostOnlyWouldCross();

    /// @notice One recorded order, in the venue's argument order.
    struct Order {
        uint8 kind;
        uint256 price;
        uint256 quantity;
        uint64 expireTimestampNs;
        uint8 orderType;
        uint8 selfMatchingOption;
        address builder;
        uint96 builderFeeBpsTimes1k;
        uint64 userData;
    }

    Order[] internal _orders;
    Level[] internal _bids;
    Level[] internal _asks;

    uint256 public tickSize = 1000;
    uint256 public minQuantity = 1000;
    uint256 public lotSize = 1000;

    uint256 public yesId;
    uint256 public noId;

    /// @notice Collateral the pool has escrowed from buyers, per set minted or bought.
    uint256 public mintSetCalls;
    uint256 public lastMintSetAmount;

    bool public revertOnParams;
    bool public revertOnBook;
    bool public revertOnPlace;
    bool public revertOnMintSet;
    /// @notice When false, `placeBinaryOrder` reports a silent rejection instead of reverting.
    bool public placeSucceeds = true;
    /// @notice Per-kind revert switch, so a maker test can reject one leg and keep the other.
    mapping(uint8 => bool) public revertOnKind;

    uint128 internal _nextOrderId = 1;

    // ── configuration ─────────────────────────────────────────────────────────

    function setIds(uint256 yesId_, uint256 noId_) external {
        yesId = yesId_;
        noId = noId_;
    }

    function setBookParams(uint256 tick, uint256 minQty, uint256 lot) external {
        tickSize = tick;
        minQuantity = minQty;
        lotSize = lot;
    }

    /// @notice Replace one side of the book with a single level.
    function setLevel(bool isBid, uint256 price, uint256 quantity) external {
        Level[] storage side = isBid ? _bids : _asks;
        while (side.length != 0) {
            side.pop();
        }
        side.push(Level({price: price, quantity: quantity}));
    }

    function clearBook() external {
        while (_bids.length != 0) {
            _bids.pop();
        }
        while (_asks.length != 0) {
            _asks.pop();
        }
    }

    function setRevertOnParams(bool on) external {
        revertOnParams = on;
    }

    function setRevertOnBook(bool on) external {
        revertOnBook = on;
    }

    function setRevertOnPlace(bool on) external {
        revertOnPlace = on;
    }

    function setRevertOnMintSet(bool on) external {
        revertOnMintSet = on;
    }

    function setRevertOnKind(uint8 kind, bool on) external {
        revertOnKind[kind] = on;
    }

    function setPlaceSucceeds(bool on) external {
        placeSucceeds = on;
    }

    /// @notice Make every entry point fail, which is the "venue is having a bad day" case.
    function setRevertOnEverything(bool on) external {
        revertOnParams = on;
        revertOnBook = on;
        revertOnPlace = on;
        revertOnMintSet = on;
    }

    // ── recorded orders ───────────────────────────────────────────────────────

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function orderAt(uint256 i) external view returns (Order memory) {
        return _orders[i];
    }

    // ── IBinaryPool ───────────────────────────────────────────────────────────

    function getOrderBookParameters() external view returns (uint256, uint256, uint256) {
        if (revertOnParams) revert PoolIsDown();
        return (tickSize, minQuantity, lotSize);
    }

    function getBookLevels(bool isBid, uint64 numLevels) external view returns (Level[] memory levels) {
        if (revertOnBook) revert PoolIsDown();
        Level[] storage side = isBid ? _bids : _asks;
        uint256 n = side.length < numLevels ? side.length : numLevels;
        levels = new Level[](n);
        for (uint256 i; i < n; ++i) {
            levels[i] = side[i];
        }
    }

    /// @dev Pulls collateral from `msg.sender` and mints `amount` of BOTH legs to the targets.
    function mintSet(address yesTo, address noTo, uint256 amount) external {
        if (revertOnMintSet) revert PoolIsDown();
        mintSetCalls += 1;
        lastMintSetAmount = amount;
        MockCollateral(LucidTypes.COLLATERAL).transferFrom(msg.sender, address(this), amount);
        MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(yesTo, yesId, amount);
        MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(noTo, noId, amount);
    }

    function burnSet(uint256) external {}

    function placeBinaryOrder(
        uint8 kind,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8 orderType,
        uint8 selfMatchingOption,
        address builder,
        uint96 builderFeeBpsTimes1k,
        uint64 userData
    ) external payable returns (bool, uint128) {
        if (revertOnPlace) revert PoolIsDown();
        if (revertOnKind[kind]) revert PostOnlyWouldCross();

        _orders.push(
            Order({
                kind: kind,
                price: price,
                quantity: quantity,
                expireTimestampNs: expireTimestampNs,
                orderType: orderType,
                selfMatchingOption: selfMatchingOption,
                builder: builder,
                builderFeeBpsTimes1k: builderFeeBpsTimes1k,
                userData: userData
            })
        );

        // The silent rejection: recorded, not reverted, and reporting failure.
        if (!placeSucceeds) return (false, 0);

        _fill(msg.sender, kind, price, quantity);

        return (true, _nextOrderId++);
    }

    /// @dev A taker buy fills immediately here. The YES side costs `price` per contract and the
    /// NO side costs the complement, which is why the desk cannot size both with one formula.
    /// Sells are maker legs in these tests, so they rest without moving anything.
    function _fill(address taker, uint8 kind, uint256 price, uint256 quantity) private {
        if (kind != LucidTypes.BUY_YES && kind != LucidTypes.BUY_NO) return;

        bool isYes = kind == LucidTypes.BUY_YES;
        uint256 unitCost = isYes ? price : LucidTypes.ONE - price;
        MockCollateral(LucidTypes.COLLATERAL).transferFrom(taker, address(this), quantity * unitCost / LucidTypes.ONE);
        MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(taker, isYes ? yesId : noId, quantity);
    }

    function cancelOrder(uint128) external {}

    function reduceOrder(uint128, uint256) external {}

    function marketNonce() external pure returns (uint64) {
        return 1;
    }
}
