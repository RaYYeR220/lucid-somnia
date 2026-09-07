// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBinaryPool} from "../../src/interfaces/IDreamDex.sol";
import {LucidTypes} from "../../src/types/LucidTypes.sol";
import {MockCollateral} from "./MockCollateral.sol";
import {MockModule} from "./MockModule.sol";
import {MockOutcomeToken} from "./MockOutcomeToken.sol";

/// @title MockBinaryPool
/// @notice A binary CLOB that actually moves money, so the desk suite can measure what a window
/// cost instead of trusting what the desk claims it cost.
/// @dev Four live behaviours are reproduced deliberately, because each one has burned an
/// integration before: a buy escrows `quantity * unitCost / oneCollateral` and the unit cost of a
/// NO leg is `oneCollateral - price` (the venue quotes the YES side for every kind);
/// `placeBinaryOrder` can return `success = false` WITHOUT reverting; POST_ONLY can revert
/// outright when it would cross; and — the one that reached production — A RESTING ORDER ESCROWS
/// ITS LEG. The 6909 balance leaves the maker the instant the venue accepts the order and stays
/// with the pool until the order fills, expires or is cancelled.
///
/// That last one is not decoration. A mock that left the maker's balance alone made a desk which
/// never cancelled its own quotes look perfectly healthy: it redeemed legs it did not hold, and
/// the suite agreed. On chain the same code redeemed nothing and booked the whole mint as a loss,
/// four windows running. Every one of these behaviours is switchable from a test.
contract MockBinaryPool is IBinaryPool {
    /// @notice Raised by the revert modes, standing in for any venue-side failure.
    error PoolIsDown();
    /// @notice The venue's own error when a POST_ONLY order would take liquidity.
    error PostOnlyWouldCross();
    /// @notice Cancelling an order the book no longer has: already filled, already expired, or
    /// already swept. The live venue reverts here, and a desk must treat that as normal.
    error OrderNotLive();

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

    /// @notice A live resting order, and the escrow the venue is sitting on for it.
    /// @dev The two sides escrow different things, and the desk's settlement has to survive both:
    /// a resting SELL holds outcome legs, a resting BUY holds collateral.
    struct Resting {
        address maker;
        uint256 outcomeId;
        uint256 escrowed;
        uint256 proceeds;
        bool collateralEscrow;
        bool live;
    }

    Order[] internal _orders;
    uint128[] internal _orderIds;
    Level[] internal _bids;
    Level[] internal _asks;

    /// @dev Keyed by the id the pool handed back from `placeBinaryOrder`.
    mapping(uint128 => Resting) internal _resting;

    /// @dev Ids passed to `cancelOrder` that the book actually had, in call order.
    uint128[] internal _cancelled;
    /// @dev How many redemptions the module had already booked when each of those cancels
    /// arrived. Two mocks cannot see each other's call order, and the order is the property under
    /// test — a desk that redeems before it cancels redeems legs it does not hold — so the pool
    /// records the settlement progress it observed. All zeroes means every cancel came first.
    uint256[] internal _redemptionsBeforeCancel;

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
    /// @notice Makes even a live order refuse to cancel, standing in for a venue-side outage.
    bool public revertOnCancel;
    /// @notice When false, `placeBinaryOrder` reports a silent rejection instead of reverting.
    bool public placeSucceeds = true;
    /// @notice When true a buy rests on the book instead of filling, escrowing collateral rather
    /// than paying it away. An IOC that finds no counterparty leaves exactly this behind.
    bool public takerOrdersRest;
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

    function setRevertOnCancel(bool on) external {
        revertOnCancel = on;
    }

    function setRevertOnKind(uint8 kind, bool on) external {
        revertOnKind[kind] = on;
    }

    function setPlaceSucceeds(bool on) external {
        placeSucceeds = on;
    }

    function setTakerOrdersRest(bool on) external {
        takerOrdersRest = on;
    }

    /// @notice Make every entry point fail, which is the "venue is having a bad day" case.
    function setRevertOnEverything(bool on) external {
        revertOnParams = on;
        revertOnBook = on;
        revertOnPlace = on;
        revertOnMintSet = on;
        revertOnCancel = on;
    }

    // ── recorded orders ───────────────────────────────────────────────────────

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function orderAt(uint256 i) external view returns (Order memory) {
        return _orders[i];
    }

    /// @notice The id the pool handed back for the order at `i`, or zero for a silent rejection.
    function orderIdAt(uint256 i) external view returns (uint128) {
        return _orderIds[i];
    }

    /// @notice Whether the book still has this order, so a test can prove a leg came back.
    function isLive(uint128 id) external view returns (bool) {
        return _resting[id].live;
    }

    /// @notice Outcome legs the pool is holding as escrow for a live order.
    function escrowOf(uint128 id) external view returns (uint256) {
        return _resting[id].escrowed;
    }

    // ── recorded cancels ──────────────────────────────────────────────────────

    function cancelledCount() external view returns (uint256) {
        return _cancelled.length;
    }

    function cancelledAt(uint256 i) external view returns (uint128) {
        return _cancelled[i];
    }

    /// @notice Redemptions the module had already booked when cancel `i` arrived. Zero means that
    /// cancel ran before any leg was redeemed, which is the ordering the desk depends on.
    function redemptionsBeforeCancelAt(uint256 i) external view returns (uint256) {
        return _redemptionsBeforeCancel[i];
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

        // The silent rejection: recorded, not reverted, and reporting failure. Nothing is escrowed
        // because nothing reached the book.
        if (!placeSucceeds) {
            _orderIds.push(0);
            return (false, 0);
        }

        uint128 id = _nextOrderId++;
        _orderIds.push(id);

        bool isBuy = kind == LucidTypes.BUY_YES || kind == LucidTypes.BUY_NO;
        if (isBuy && !takerOrdersRest) {
            _fill(msg.sender, kind, price, quantity);
        } else {
            _escrow(id, msg.sender, kind, price, quantity);
        }

        return (true, id);
    }

    /// @dev A taker buy fills immediately here. The YES side costs `price` per contract and the
    /// NO side costs the complement, which is why the desk cannot size both with one formula.
    function _fill(address taker, uint8 kind, uint256 price, uint256 quantity) private {
        bool isYes = kind == LucidTypes.BUY_YES;
        uint256 unitCost = isYes ? price : LucidTypes.ONE - price;
        MockCollateral(LucidTypes.COLLATERAL).transferFrom(taker, address(this), quantity * unitCost / LucidTypes.ONE);
        MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(taker, isYes ? yesId : noId, quantity);
    }

    /// @dev An order that reaches the book ESCROWS. A sell hands its outcome legs to the pool for
    /// as long as the quote is up — which is exactly why a maker that settles without cancelling
    /// holds nothing to redeem — and a buy hands over the collateral it would pay. Both stay with
    /// the pool until the order fills, expires or is cancelled.
    function _escrow(uint128 id, address maker, uint8 kind, uint256 price, uint256 quantity) private {
        bool isYesSide = kind == LucidTypes.BUY_YES || kind == LucidTypes.SELL_YES;
        uint256 outcomeId = isYesSide ? yesId : noId;
        // The venue quotes the YES side for every kind, so a NO contract is worth the complement.
        uint256 unitValue = isYesSide ? price : LucidTypes.ONE - price;
        uint256 notional = quantity * unitValue / LucidTypes.ONE;

        bool isBuy = kind == LucidTypes.BUY_YES || kind == LucidTypes.BUY_NO;
        if (isBuy) {
            MockCollateral(LucidTypes.COLLATERAL).transferFrom(maker, address(this), notional);
        } else {
            MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).burn(maker, outcomeId, quantity);
            MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(address(this), outcomeId, quantity);
        }

        _resting[id] = Resting({
            maker: maker,
            outcomeId: outcomeId,
            escrowed: isBuy ? notional : quantity,
            proceeds: isBuy ? quantity : notional,
            collateralEscrow: isBuy,
            live: true
        });
    }

    /// @notice Match a resting order the way a counterparty would: the escrow goes to the taker
    /// and the maker gets the other side of the trade. The order is no longer live afterwards, so
    /// cancelling it reverts — the case a settling desk has to survive.
    function fillResting(uint128 id) external {
        Resting storage r = _resting[id];
        if (!r.live) revert OrderNotLive();

        r.live = false;
        if (r.collateralEscrow) {
            // The buyer paid its escrow away and receives the contracts.
            MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(r.maker, r.outcomeId, r.proceeds);
        } else {
            MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).burn(address(this), r.outcomeId, r.escrowed);
            MockCollateral(LucidTypes.COLLATERAL).transfer(r.maker, r.proceeds);
        }
    }

    /// @notice The venue's own `cancelExpiredOrders` sweep: the order leaves the book and its
    /// escrow goes home, without anybody asking the maker. A later `cancelOrder` for that id then
    /// reverts even though the legs are already back — a failure that is not a failure, and the
    /// reason a settling desk must swallow it and carry on.
    function sweepExpired(uint128 id) external {
        Resting storage r = _resting[id];
        if (!r.live) revert OrderNotLive();

        r.live = false;
        _returnEscrow(r);
    }

    /// @notice Take a live order off the book and hand its escrow back to the maker.
    /// @dev Reverts when the book no longer has the order, which on the live venue covers a fill,
    /// an expiry and the venue's own `cancelExpiredOrders` sweep. All three are ordinary, and a
    /// desk that stops settling because one of them happened is broken.
    function cancelOrder(uint128 id) external {
        if (revertOnCancel) revert PoolIsDown();

        Resting storage r = _resting[id];
        if (!r.live) revert OrderNotLive();

        r.live = false;
        _cancelled.push(id);
        _redemptionsBeforeCancel.push(_redemptionsSoFar());

        _returnEscrow(r);
    }

    /// @dev Hand a dead order's escrow back to whoever placed it, in whichever asset it was taken.
    function _returnEscrow(Resting storage r) private {
        if (r.collateralEscrow) {
            MockCollateral(LucidTypes.COLLATERAL).transfer(r.maker, r.escrowed);
        } else {
            MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).burn(address(this), r.outcomeId, r.escrowed);
            MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).mint(r.maker, r.outcomeId, r.escrowed);
        }
    }

    function reduceOrder(uint128, uint256) external {}

    function marketNonce() external pure returns (uint64) {
        return 1;
    }

    /// @dev The module lives at a fixed address the desk hardcodes; a suite that has not placed it
    /// there simply has no redemptions to count, so the witness reads zero rather than reverting
    /// on an `extcodesize` guard the caller cannot catch.
    function _redemptionsSoFar() private view returns (uint256) {
        if (LucidTypes.MODULE.code.length == 0) return 0;
        return MockModule(LucidTypes.MODULE).redeemCount();
    }
}
