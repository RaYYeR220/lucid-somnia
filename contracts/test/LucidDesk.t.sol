// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IBinaryPool} from "../src/interfaces/IDreamDex.sol";
import {LucidDesk} from "../src/LucidDesk.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

import {MockBinaryPool} from "./mocks/MockBinaryPool.sol";
import {MockCollateral} from "./mocks/MockCollateral.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockModule} from "./mocks/MockModule.sol";
import {MockOutcomeToken} from "./mocks/MockOutcomeToken.sol";

/// @notice The desk is the only contract in LUCID that touches money, and it is driven by a
/// reactivity handler that fans out to every other desk in the same block. Two properties
/// therefore matter more than any feature: it refuses out loud when the owner mandate says no,
/// and it never reverts while the router is driving it. Both are asserted directly here.
contract LucidDeskTest is Test {
    // The desk event surface, redeclared so the suite can match on it.
    event Considered(bytes32 indexed marketId, uint32 intervalSec, bytes32 assetKey);
    event VerdictReceived(bytes32 indexed marketId, uint16 probUpBps, uint16 pBookBps, uint8 responded);
    event Executed(bytes32 indexed marketId, uint8 kind, uint256 price, uint256 quantity, uint128 orderId);
    event Refused(bytes32 indexed marketId, LucidTypes.Refusal reason, uint16 probUpBps, uint16 pBookBps);
    event Settled(bytes32 indexed marketId, int256 pnl, uint256 equityAfter);
    event OrdersCancelled(bytes32 indexed marketId, uint256 count);
    event ArmedSet(bool on);
    event PolicySet(LucidTypes.Policy policy);

    /// @notice A settlement that booked no result at all, which no test here expects.
    error NoSettlementLogged();

    LucidDesk internal implementation;
    LucidDesk internal desk;

    MockCollateral internal usdc;
    MockOutcomeToken internal outcome;
    MockModule internal module;
    MockBinaryPool internal pool;
    MockMarket internal market;

    address internal owner = address(0xB0B);
    address internal router = address(0x120041);
    address internal brain = address(0xB3A17);
    address internal stranger = address(0xBAD);
    address internal factory = address(0xFAC7);

    bytes32 internal constant VENUE = 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f;
    bytes32 internal constant MARKET_A = keccak256("market-a");
    bytes32 internal constant MARKET_B = keccak256("market-b");
    uint256 internal constant YES_ID = 111;
    uint256 internal constant NO_ID = 112;

    /// @dev Mid-day, so a one-day warp definitely crosses a UTC boundary.
    uint256 internal constant START_TS = 1_800_000_000;
    uint256 internal constant FUNDING = 100e6;

    function setUp() public {
        vm.warp(START_TS);

        // The collateral, the 6909 and the module live at fixed addresses the desk hardcodes,
        // so the mocks are placed at exactly those addresses rather than injected.
        deployCodeTo("MockCollateral.sol:MockCollateral", LucidTypes.COLLATERAL);
        deployCodeTo("MockOutcomeToken.sol:MockOutcomeToken", LucidTypes.OUTCOME_TOKEN);
        deployCodeTo("MockModule.sol:MockModule", LucidTypes.MODULE);
        usdc = MockCollateral(LucidTypes.COLLATERAL);
        outcome = MockOutcomeToken(LucidTypes.OUTCOME_TOKEN);
        module = MockModule(LucidTypes.MODULE);

        pool = new MockBinaryPool();
        pool.setIds(YES_ID, NO_ID);
        pool.setLevel(false, 520_000, 1_000e6);
        pool.setLevel(true, 480_000, 1_000e6);

        market = new MockMarket();

        // `arm` notifies the router for real, so the stand-in needs code behind it: a typed
        // external call carries an extcodesize check that reverts before the call is even made.
        vm.etch(router, hex"00");

        implementation = new LucidDesk();
        desk = LucidDesk(Clones.clone(address(implementation)));

        vm.prank(factory);
        desk.initialize(owner, router, brain);

        // Funded through `deposit` rather than by minting straight into the desk, so the desk
        // starts with a real high-water mark and the drawdown floor is live from the first window.
        usdc.mint(owner, FUNDING);
        vm.startPrank(owner);
        desk.setPolicy(_basePolicy());
        usdc.approve(address(desk), FUNDING);
        desk.deposit(FUNDING);
        vm.stopPrank();
    }

    // -- fixtures --------------------------------------------------------------

    function _basePolicy() internal pure returns (LucidTypes.Policy memory p) {
        p = LucidTypes.Policy({
            maxStakePerWindow: 50e6,
            dailyBudget: 500e6,
            maxOpenMarkets: 4,
            maxDrawdownBps: 5000,
            maxConsecutiveLosses: 3,
            minEdgeBps: 200,
            allowedAssets: 3,
            allowedCadences: 15,
            strategy: uint8(LucidTypes.Strategy.AiEdge),
            armed: true
        });
    }

    function _makerPolicy() internal pure returns (LucidTypes.Policy memory p) {
        p = _basePolicy();
        p.strategy = uint8(LucidTypes.Strategy.Maker);
    }

    function _info(bytes32 id) internal view returns (LucidTypes.MarketInfo memory m) {
        m = LucidTypes.MarketInfo({
            marketId: id,
            market: address(market),
            pool: address(pool),
            operatorId: 4,
            venueId: VENUE,
            yesId: YES_ID,
            noId: NO_ID,
            tradingStart: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 300),
            nonce: 1,
            strike: 10_000_000,
            assetKey: LucidTypes.ASSET_BTC,
            intervalSec: 300
        });
    }

    function _verdict(uint16 probUpBps, bool ok) internal pure returns (LucidTypes.Verdict memory) {
        return LucidTypes.Verdict({probUpBps: probUpBps, responded: 3, agreed: 3, ok: ok, requestId: 1});
    }

    /// @dev Every fixture that uses this helper quotes a book, so the observation flag is true.
    /// The tests that care about an empty book drive the desk directly and say so.
    function _drive(bytes32 id, uint16 probUpBps, uint256 pBookBps) internal {
        vm.prank(router);
        desk.onVerdict(_info(id), _verdict(probUpBps, true), pBookBps, true);
    }

    /// @dev Drives the desk with the window the venue presents most of the time: a book with no
    /// levels on either side. The value is zero because nothing was read, and the flag is what says
    /// so — the desk must never treat the two as the same thing.
    function _driveNoBook(bytes32 id, uint16 probUpBps) internal {
        vm.prank(router);
        desk.onVerdict(_info(id), _verdict(probUpBps, true), 0, false);
    }

    // -- lifecycle -------------------------------------------------------------

    function test_initialize_is_one_shot() public {
        assertEq(desk.owner(), owner);
        assertEq(desk.router(), router);
        assertEq(desk.brain(), brain);

        vm.expectRevert(LucidDesk.AlreadyInitialized.selector);
        desk.initialize(stranger, stranger, stranger);
    }

    function test_implementation_cannot_be_initialized() public {
        vm.expectRevert(LucidDesk.AlreadyInitialized.selector);
        implementation.initialize(stranger, stranger, stranger);
    }

    function test_only_router_can_drive() public {
        LucidTypes.MarketInfo memory m = _info(MARKET_A);

        vm.startPrank(stranger);
        vm.expectRevert(LucidDesk.NotRouter.selector);
        desk.preCheck(m);
        vm.expectRevert(LucidDesk.NotRouter.selector);
        desk.onVerdict(m, _verdict(8800, true), 5000, true);
        vm.expectRevert(LucidDesk.NotRouter.selector);
        desk.onSettlement(m);
        vm.expectRevert(LucidDesk.NotRouter.selector);
        desk.onLeaderTrade(m, LucidTypes.BUY_YES, 1e6);
        vm.stopPrank();
    }

    function test_only_owner_can_configure() public {
        vm.startPrank(stranger);
        vm.expectRevert(LucidDesk.NotOwner.selector);
        desk.setPolicy(_basePolicy());
        vm.expectRevert(LucidDesk.NotOwner.selector);
        desk.arm(true);
        vm.expectRevert(LucidDesk.NotOwner.selector);
        desk.deposit(1e6);
        vm.expectRevert(LucidDesk.NotOwner.selector);
        desk.withdraw(1e6);
        vm.expectRevert(LucidDesk.NotOwner.selector);
        desk.fundFromFaucet(1e6);
        vm.stopPrank();
    }

    /// @notice A clone is deployed and configured in one transaction, before its owner can send
    /// one, so whoever deployed it gets exactly one shot at the opening mandate and nothing more.
    function test_deployer_may_set_the_initial_policy_once() public {
        LucidDesk fresh = LucidDesk(Clones.clone(address(implementation)));

        vm.startPrank(factory);
        fresh.initialize(owner, router, brain);
        fresh.setPolicy(_basePolicy());

        vm.expectRevert(LucidDesk.NotOwner.selector);
        fresh.setPolicy(_makerPolicy());
        vm.stopPrank();

        assertEq(fresh.policy().maxStakePerWindow, 50e6);

        // The owner keeps control of every later change.
        vm.prank(owner);
        fresh.setPolicy(_makerPolicy());
        assertEq(fresh.policy().strategy, uint8(LucidTypes.Strategy.Maker));
    }

    function test_owner_can_move_collateral() public {
        usdc.mint(owner, 10e6);

        vm.startPrank(owner);
        usdc.approve(address(desk), 10e6);
        desk.deposit(10e6);
        assertEq(desk.equity(), FUNDING + 10e6);

        assertEq(desk.state().highWaterMark, FUNDING + 10e6, "a deposit must carry the mark with it");

        desk.withdraw(4e6);
        assertEq(usdc.balanceOf(owner), 4e6);
        assertEq(desk.state().highWaterMark, FUNDING + 6e6, "a withdrawal is not a drawdown");

        desk.fundFromFaucet(1_000e6);
        assertEq(desk.equity(), FUNDING + 6e6 + 1_000e6);
        vm.stopPrank();
    }

    // -- the cheap pre-filter --------------------------------------------------

    function test_precheck_false_when_disarmed() public {
        vm.prank(router);
        assertTrue(desk.preCheck(_info(MARKET_A)));

        vm.prank(owner);
        desk.arm(false);

        vm.prank(router);
        assertFalse(desk.preCheck(_info(MARKET_A)));
    }

    function test_precheck_false_for_disallowed_asset() public {
        LucidTypes.MarketInfo memory m = _info(MARKET_A);
        m.assetKey = keccak256("SOL");

        vm.prank(router);
        assertFalse(desk.preCheck(m));
    }

    // -- refusals --------------------------------------------------------------

    /// @notice The headline behaviour: a committee that is 88% sure does not get to override the
    /// per-window cap its owner set. The desk says no in public and places nothing.
    function test_refuses_over_cap_even_with_a_confident_verdict() public {
        LucidTypes.Policy memory p = _basePolicy();
        p.maxStakePerWindow = 10e6;
        vm.prank(owner);
        desk.setPolicy(p);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.CapExceeded, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        assertEq(pool.orderCount(), 0, "an order was placed despite the cap");
        assertEq(desk.state().spentToday, 0);
        assertEq(desk.state().openMarkets, 0);
        assertEq(desk.equity(), FUNDING);
    }

    function test_refuses_when_verdict_not_ok() public {
        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.AiUnavailable, 8800, 5000);

        vm.prank(router);
        desk.onVerdict(_info(MARKET_A), _verdict(8800, false), 5000, true);

        assertEq(pool.orderCount(), 0);
    }

    function test_refuses_on_low_edge() public {
        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.LowEdge, 5100, 5000);
        _drive(MARKET_A, 5100, 5000);

        assertEq(pool.orderCount(), 0);
    }

    function test_refuses_when_quantity_below_min() public {
        pool.setBookParams(1000, 1e12, 1000);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.InsufficientFunds, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        assertEq(pool.orderCount(), 0);
    }

    // -- taking liquidity ------------------------------------------------------

    function test_executes_buy_yes_when_verdict_above_book() public {
        // The UI and the demo read this trace in order, so it is asserted in order.
        vm.expectEmit(true, false, false, true, address(desk));
        emit Considered(MARKET_A, 300, LucidTypes.ASSET_BTC);
        vm.expectEmit(true, false, false, true, address(desk));
        emit VerdictReceived(MARKET_A, 8800, 5000, 3);
        _drive(MARKET_A, 8800, 5000);

        assertEq(pool.orderCount(), 1);
        MockBinaryPool.Order memory o = pool.orderAt(0);
        assertEq(o.kind, LucidTypes.BUY_YES);
        assertEq(o.orderType, LucidTypes.ORDER_MARKET, "taker orders must be IOC");
        assertEq(o.price, 521_000, "one tick through the best offer");
        assertEq(o.selfMatchingOption, 0);
        assertEq(o.builder, address(0));
        assertEq(o.builderFeeBpsTimes1k, 0);
        assertEq(o.userData, 0);
        assertEq(o.expireTimestampNs, uint64(block.timestamp + 300 - 5) * 1e9, "expiry must be in ns");

        // A 38-point disagreement over a 100 tUSDC desk stakes 38 tUSDC, and the venue may
        // never escrow more than that.
        assertEq(desk.state().spentToday, 38e6);
        assertEq(desk.state().openMarkets, 1);
        assertLe(FUNDING - usdc.balanceOf(address(desk)), 38e6, "escrow exceeded the mandated stake");
        assertEq(outcome.balanceOf(address(desk), YES_ID), o.quantity);
    }

    function test_executes_buy_no_when_verdict_below_book() public {
        _drive(MARKET_A, 1200, 5000);

        assertEq(pool.orderCount(), 1);
        MockBinaryPool.Order memory o = pool.orderAt(0);
        assertEq(o.kind, LucidTypes.BUY_NO);
        assertEq(o.price, 479_000, "one tick through the best bid, quoted on the YES side");
        assertLe(FUNDING - usdc.balanceOf(address(desk)), 38e6, "escrow exceeded the mandated stake");
        assertEq(outcome.balanceOf(address(desk), NO_ID), o.quantity);
    }

    /// An `AiEdge` desk crosses the book in one direction, so its size IS its conviction and the
    /// two numbers below are the formula, pinned. This is the path a maker must never be
    /// "unified" back into: the same two windows sized on the mandate would stake 50 tUSDC each.
    function test_an_edge_desk_on_an_observed_book_is_sized_by_conviction() public {
        // 88.00% against a book at 50.00% is a 38-point disagreement, and this desk has 100 tUSDC.
        _drive(MARKET_A, 8800, 5000);
        assertEq(desk.state().spentToday, 38e6, "38 points of edge stakes 38% of equity");
        assertLe(FUNDING - usdc.balanceOf(address(desk)), 38e6, "escrow exceeded the mandated stake");

        // Opening a position does not change equity — it moves collateral into `openNotional` at
        // cost — so the second window scales off the same 100 tUSDC.
        assertEq(desk.equity(), FUNDING);

        // 53.00% against the same book is 3 points, and stakes a proportional 3 tUSDC.
        _drive(MARKET_B, 5300, 5000);
        assertEq(desk.state().spentToday, 41e6, "3 points of edge stakes 3% of equity");
        assertEq(pool.orderCount(), 2);

        uint256 second = pool.orderAt(1).quantity * pool.orderAt(1).price / LucidTypes.ONE;
        assertLe(second, 3e6, "the second window escrowed more than its conviction");
        assertGt(second, 3e6 - 1e3, "and it must be sized on the edge, not rounded away");
    }

    function test_price_is_tick_aligned_and_below_one() public {
        pool.setLevel(false, 999_500, 1_000e6);
        _drive(MARKET_A, 8800, 5000);

        MockBinaryPool.Order memory o = pool.orderAt(0);
        assertEq(o.price % pool.tickSize(), 0, "price is off tick");
        assertLt(o.price, LucidTypes.ONE, "price must stay below one contract");
        assertEq(o.price, LucidTypes.ONE - pool.tickSize());
    }

    function test_quantity_is_lot_aligned() public {
        pool.setBookParams(1000, 1000, 1e6);
        _drive(MARKET_A, 8800, 5000);

        MockBinaryPool.Order memory o = pool.orderAt(0);
        assertEq(o.quantity % 1e6, 0, "quantity is off lot");
        assertEq(o.quantity, 72e6, "lot alignment must round DOWN, never up");
    }

    /// `VenueRejected` now claims exactly one thing: the venue was handed a fully priced, fully
    /// sized order and turned it down. The book was readable and the price was sane — the
    /// rejection is the venue's, and nothing upstream of it may borrow this reason.
    function test_venue_returning_false_is_refused_not_executed() public {
        pool.setPlaceSucceeds(false);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.VenueRejected, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        assertEq(pool.orderCount(), 1, "the venue saw a complete order and refused it");
        assertEq(desk.state().spentToday, 0, "a silent rejection was booked as a trade");
        assertEq(desk.state().openMarkets, 0);
        assertEq(desk.equity(), FUNDING);
    }

    // -- naming the component that actually failed ----------------------------
    //
    // A single `VenueRejected` used to cover an unreadable book, an unquotable price range and
    // the venue refusing an order, which made a live refusal impossible to diagnose from its own
    // log line — and produced a confident public claim that the venue was crossing a maker's
    // second leg, which nothing in the trace supported. Each failure now carries its own reason,
    // and each test below pins the exact enum rather than merely "some refusal happened".

    /// The pool would not say what its tick is. No price was ever formed, so no order could have
    /// been rejected: this is the book failing, not the venue.
    function test_a_taker_refuses_BookUnreadable_when_the_parameters_revert() public {
        pool.setRevertOnParams(true);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.BookUnreadable, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        assertEq(pool.orderCount(), 0, "nothing may reach the venue without a tick");
        assertEq(desk.state().spentToday, 0);
        assertEq(desk.equity(), FUNDING);
    }

    /// The parameters read fine and the levels did not. Still the book, still not the venue — the
    /// two reads are one fact from a diagnosis's point of view: the desk never saw a price.
    function test_a_taker_refuses_BookUnreadable_when_the_levels_revert() public {
        pool.setRevertOnBook(true);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.BookUnreadable, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        assertEq(pool.orderCount(), 0);
        assertEq(desk.state().spentToday, 0);
    }

    /// The maker reads the same parameters for its own reasons, and reports the same failure.
    function test_a_maker_refuses_BookUnreadable_when_the_parameters_revert() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());
        pool.setRevertOnParams(true);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.BookUnreadable, 6000, 5000);
        _drive(MARKET_A, 6000, 5000);

        assertEq(pool.mintSetCalls(), 0, "no set may be minted against a book nobody could read");
        assertEq(pool.orderCount(), 0);
        assertEq(desk.equity(), FUNDING);
    }

    /// The book read fine, the quotes were priced, and `mintSet` reverted. The desk holds no set,
    /// so there is nothing to quote and nothing to book — and the venue never saw an order.
    function test_a_maker_refuses_MintFailed_when_the_set_cannot_be_minted() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());
        pool.setRevertOnMintSet(true);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.MintFailed, 6000, 5000);
        _drive(MARKET_A, 6000, 5000);

        assertEq(pool.mintSetCalls(), 0, "the mint reverted, so no set exists");
        assertEq(pool.orderCount(), 0, "and no leg may rest against a set the desk does not hold");
        assertEq(desk.state().spentToday, 0, "nothing was charged for a position never taken");
        assertEq(desk.state().openMarkets, 0);
        assertEq(desk.equity(), FUNDING);
    }

    // -- making a market -------------------------------------------------------

    /// A maker quotes both sides, so it is sized by the mandate rather than by conviction: the
    /// 10-point gap between this verdict and this book is not a statement about how much of the
    /// desk should be standing in the market, and the owner's per-window cap is.
    function test_maker_mints_a_set_and_rests_both_legs() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _drive(MARKET_A, 6000, 5000);

        assertEq(pool.mintSetCalls(), 1, "a maker needs no counterparty, only a complete set");
        assertEq(pool.lastMintSetAmount(), 50e6, "the mandate sizes the quote, not the disagreement");
        assertEq(pool.orderCount(), 2);

        MockBinaryPool.Order memory yes = pool.orderAt(0);
        assertEq(yes.kind, LucidTypes.SELL_YES);
        assertEq(yes.orderType, LucidTypes.ORDER_POST_ONLY);
        assertEq(yes.price, 620_000, "fair plus the spread");
        assertEq(yes.quantity, 50e6);

        MockBinaryPool.Order memory no = pool.orderAt(1);
        assertEq(no.kind, LucidTypes.SELL_NO);
        assertEq(no.orderType, LucidTypes.ORDER_POST_ONLY);
        assertEq(no.price, 580_000, "the NO quote, converted to the YES side the venue wants");
        assertEq(no.quantity, 50e6);

        // Resting is not free: both legs are escrowed by the venue for as long as the quotes are
        // on the book, so the desk holds none of what it just minted. This assertion used to read
        // 50e6 on both lines, because the pool mock left the balance alone — and a desk that
        // redeemed without cancelling looked healthy right up until it did it on chain.
        assertEq(outcome.balanceOf(address(desk), YES_ID), 0, "a resting quote escrows its leg");
        assertEq(outcome.balanceOf(address(desk), NO_ID), 0, "both of them");
        assertEq(outcome.balanceOf(address(pool), YES_ID), 50e6, "the venue is holding the YES leg");
        assertEq(outcome.balanceOf(address(pool), NO_ID), 50e6, "and the NO leg");
        assertEq(desk.state().spentToday, 50e6);
        assertEq(desk.state().openMarkets, 1);

        // And the desk can name both of them again, which is the only way to get them back.
        uint128[2] memory ids = desk.restingOrders(MARKET_A);
        assertEq(ids[0], pool.orderIdAt(0));
        assertEq(ids[1], pool.orderIdAt(1));
    }

    function test_maker_survives_one_leg_being_rejected() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());
        pool.setRevertOnKind(LucidTypes.SELL_NO, true);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.VenueRejected, 6000, 5000);
        _drive(MARKET_A, 6000, 5000);

        assertEq(pool.orderCount(), 1, "the surviving leg must still rest");
        assertEq(pool.orderAt(0).kind, LucidTypes.SELL_YES);
        assertEq(pool.mintSetCalls(), 1);
        assertEq(desk.state().openMarkets, 1, "the minted set is still a position");
    }

    // -- the book that was never there -----------------------------------------
    //
    // The router used to report an empty book as 5000. A desk comparing an 8800 verdict against
    // that fallback measures a 38-point edge against a price nobody quoted and stakes 38% of its
    // equity on it. The book now arrives with an observation flag, and the refusal carries a
    // sentinel rather than a stand-in probability so a reader can tell "there was no book" from
    // "the book was at 0%".

    function test_an_edge_desk_refuses_NoBook_and_places_nothing() public {
        // The same 8800 verdict that trades happily against a quoted 5000 book.
        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.NoBook, 8800, type(uint16).max);
        _driveNoBook(MARKET_A, 8800);

        assertEq(pool.orderCount(), 0, "an edge is not measurable against a price nobody quoted");
        assertEq(desk.state().spentToday, 0, "and nothing was charged against the budget");
        assertEq(desk.state().openMarkets, 0);
        assertEq(desk.equity(), FUNDING, "no collateral moved");
    }

    /// The sentinel is the point of the event: 65535 sits outside the 0..10000 probability range,
    /// so a reader that does not know about it sees an impossible number rather than a plausible
    /// lie, and one that does can separate "no book" from "book at zero".
    function test_the_refusal_carries_the_unobserved_sentinel_not_a_stand_in_price() public {
        vm.expectEmit(true, false, false, true, address(desk));
        emit VerdictReceived(MARKET_A, 8800, type(uint16).max, 3);
        _driveNoBook(MARKET_A, 8800);

        assertEq(uint256(type(uint16).max), 65_535, "the sentinel, spelled out");
        assertEq(LucidTypes.BOOK_UNOBSERVED, type(uint16).max, "and it is the one the types declare");
    }

    /// An observed book at zero is a real quote. It is reported as 0, traded against, and must not
    /// be confused with the window above.
    function test_an_observed_book_of_zero_is_traded_against_and_reported_as_zero() public {
        // An 88-point disagreement sizes 88% of equity, and the subject here is the book rather
        // than the cap, so the cap is lifted out of the way.
        LucidTypes.Policy memory p = _basePolicy();
        p.maxStakePerWindow = 100e6;
        vm.prank(owner);
        desk.setPolicy(p);

        vm.expectEmit(true, false, false, true, address(desk));
        emit VerdictReceived(MARKET_A, 8800, 0, 3);
        _drive(MARKET_A, 8800, 0);

        assertEq(pool.orderCount(), 1, "a quoted book is tradable however low it is");
        assertTrue(uint256(0) != uint256(type(uint16).max), "and 0 is not the sentinel the empty book carries");
    }

    /// The whole reason `Maker` exists. It mints a complete set and rests both legs, which needs no
    /// counterparty at all — an empty book is the state it was built for, and refusing it here
    /// would delete the one strategy that works on this venue's usual book.
    ///
    /// It is sized by the mandate. There is no book to disagree with, so there is no conviction to
    /// size on, and every stand-in for the missing number is arithmetic on a value that means "no
    /// value": the live desk multiplied its equity by `|6000 - 65535|` and refused itself
    /// `CapExceeded` on every window it ever saw.
    function test_a_maker_mints_and_rests_both_legs_on_an_unobserved_book() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _driveNoBook(MARKET_A, 6000);

        assertEq(pool.mintSetCalls(), 1, "a maker needs no counterparty, only a complete set");
        assertEq(pool.lastMintSetAmount(), 50e6, "the whole window mandate, exactly");
        assertEq(pool.orderCount(), 2, "both legs rest");

        MockBinaryPool.Order memory yes = pool.orderAt(0);
        assertEq(yes.kind, LucidTypes.SELL_YES);
        assertEq(yes.orderType, LucidTypes.ORDER_POST_ONLY);
        assertEq(yes.price, 620_000, "quoted around the committee's fair value, not around a book");
        assertEq(yes.quantity, 50e6);

        MockBinaryPool.Order memory no = pool.orderAt(1);
        assertEq(no.kind, LucidTypes.SELL_NO);
        assertEq(no.orderType, LucidTypes.ORDER_POST_ONLY);
        assertEq(no.price, 580_000, "the NO quote, converted to the YES side the venue wants");
        assertEq(no.quantity, 50e6);

        // Escrowed, not held: see `test_maker_mints_a_set_and_rests_both_legs`.
        assertEq(outcome.balanceOf(address(pool), YES_ID), 50e6);
        assertEq(outcome.balanceOf(address(pool), NO_ID), 50e6);
        assertEq(desk.state().spentToday, 50e6, "the mandate is the size");
        assertEq(desk.state().openMarkets, 1);

        // The sentinel spelled out: equity times `|probUp - BOOK_UNOBSERVED|` is six times the
        // whole desk, which is the number that produced every live refusal.
        uint256 sentinelSized = FUNDING * (uint256(type(uint16).max) - 6000) / LucidTypes.BPS;
        assertGt(sentinelSized, FUNDING, "the bug being pinned: a sentinel sizes above equity");
        assertEq(pool.lastMintSetAmount(), desk.policy().maxStakePerWindow, "and it is not what sized this");
    }

    /// The exact window the live desk refused `InsufficientFunds` on: a committee that is on the
    /// fence. Conviction sizing stakes zero there, which is precisely backwards for a strategy
    /// that earns a spread rather than a call — an undecided committee is when standing on both
    /// sides is worth the most.
    function test_a_maker_quotes_an_undecided_committee_instead_of_staking_nothing() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _driveNoBook(MARKET_A, 5000);

        assertEq(pool.mintSetCalls(), 1, "an even verdict is a reason to quote, not a reason to stop");
        assertEq(pool.lastMintSetAmount(), 50e6);
        assertEq(pool.orderCount(), 2);
        assertEq(pool.orderAt(0).price, 520_000, "fair plus the spread");
        assertEq(pool.orderAt(1).price, 480_000, "fair minus the spread, on the YES side");
    }

    /// A maker on an empty book is not exempt from the mandate, only from needing a quote. The cap
    /// is now the size rather than a veto over it, so what has to hold is that the desk never
    /// stands for more than the owner allowed — and that the daily budget still refuses out loud.
    function test_a_maker_on_an_unobserved_book_still_obeys_the_cap_and_the_budget() public {
        LucidTypes.Policy memory p = _makerPolicy();
        p.maxStakePerWindow = 7e6;
        p.dailyBudget = 10e6;
        vm.prank(owner);
        desk.setPolicy(p);

        _driveNoBook(MARKET_A, 6000);

        assertEq(pool.lastMintSetAmount(), 7e6, "the window cap, not a bps slice of a 100 tUSDC desk");
        assertEq(FUNDING - usdc.balanceOf(address(desk)), 7e6, "the venue escrowed more than the cap");
        assertEq(desk.state().spentToday, 7e6);

        // 7 + 7 does not fit in 10, and the budget is a veto rather than a clamp: the second
        // window is refused whole rather than quoted small.
        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_B, LucidTypes.Refusal.DailyBudgetExceeded, 6000, type(uint16).max);
        _driveNoBook(MARKET_B, 6000);

        assertEq(pool.mintSetCalls(), 1, "the budget is a veto, not a clamp");
        assertEq(pool.orderCount(), 2, "and nothing new rested");
        assertEq(desk.state().spentToday, 7e6);
    }

    /// Collateral is a fact about money rather than an edit of the mandate, so a desk with less
    /// than a full window's worth quotes what it actually has instead of refusing itself.
    function test_a_maker_sizes_on_free_collateral_when_it_is_below_the_cap() public {
        vm.startPrank(owner);
        desk.setPolicy(_makerPolicy());
        desk.withdraw(FUNDING - 20e6);
        vm.stopPrank();

        _driveNoBook(MARKET_A, 6000);

        assertEq(pool.mintSetCalls(), 1, "a short desk still trades, it just trades smaller");
        assertEq(pool.lastMintSetAmount(), 20e6, "sized on the collateral actually on hand");
        assertEq(pool.orderCount(), 2);
        assertEq(pool.orderAt(0).quantity, 20e6);
        assertEq(pool.orderAt(1).quantity, 20e6);
        assertEq(desk.state().spentToday, 20e6, "and the budget is charged what was actually staked");
    }

    // -- the committee's answers at the boundary -------------------------------
    //
    // 100% and 0% are both live answers on this venue. Fair value then sits on or past the edge of
    // the venue's `0 < price < ONE` range, which is exactly where a clamp can quietly pin one leg
    // onto the other. A complete set costs `ONE` and pays `ONE`, so the gap between the two quotes
    // IS the profit: an equal or crossed pair sells the set for what it cost or less.

    function test_a_maker_quotes_both_sides_at_a_hundred_percent() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _driveNoBook(MARKET_A, LucidTypes.BPS);

        assertEq(pool.orderCount(), 2, "certainty is still a two-sided quote");
        uint256 ask = pool.orderAt(0).price;
        uint256 bid = pool.orderAt(1).price;

        assertEq(ask, LucidTypes.ONE - pool.tickSize(), "fair is past the ceiling, so the ask sits on it");
        assertEq(bid, 980_000, "and the NO leg keeps its full spread below fair");
        _assertSaneQuotePair(bid, ask);
    }

    function test_a_maker_quotes_both_sides_at_zero_percent() public {
        // The mandate's 200 bps edge floor stands here. A maker on an empty book is handed a
        // placeholder book of zero, so a 0% verdict measures no distance from it — and a desk that
        // quotes both sides was never trading that distance, so the floor has nothing to say about
        // this window. `PolicyLib` scopes the floor to the strategy it belongs to.
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _driveNoBook(MARKET_A, 0);

        assertEq(pool.orderCount(), 2, "so is certainty the other way");
        uint256 ask = pool.orderAt(0).price;
        uint256 bid = pool.orderAt(1).price;

        assertEq(ask, 20_000, "fair is zero, so the YES leg is the spread itself");
        assertEq(bid, pool.tickSize(), "and the NO leg sits on the floor rather than under it");
        _assertSaneQuotePair(bid, ask);
    }

    /// The refusal branch: a tick coarse enough that no ordered pair fits between the venue's own
    /// floor and ceiling. There is no sane price to post, so nothing is posted and nothing is
    /// minted — a set the desk cannot quote is a whole window's mandate spent doing nothing.
    ///
    /// The reason is `Unquotable`, not `VenueRejected`: the pool answered every read it was given
    /// and was never shown an order. The desk's own arithmetic is what has nothing to say here.
    function test_a_maker_refuses_Unquotable_when_no_ordered_pair_fits_inside_the_range() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());
        // Legal prices are `[tick, ONE - tick]`, which this tick empties out entirely.
        pool.setBookParams(600_000, 1000, 1000);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.Unquotable, LucidTypes.BPS, type(uint16).max);
        _driveNoBook(MARKET_A, LucidTypes.BPS);

        assertEq(pool.orderCount(), 0, "no leg may be posted at a nonsense price");
        assertEq(pool.mintSetCalls(), 0, "and no set is minted that could not be quoted");
        assertEq(desk.state().spentToday, 0);
        assertEq(desk.equity(), FUNDING, "no collateral moved");
    }

    /// @dev Both legs strictly inside the venue's price range and strictly ordered. Equality is a
    /// failure, not a rounding detail: it sells a complete set for exactly what minting it cost.
    function _assertSaneQuotePair(uint256 bid, uint256 ask) internal view {
        assertGt(bid, 0, "a quote at zero is not a price the venue accepts");
        assertLt(ask, LucidTypes.ONE, "nor is one at a whole contract");
        assertLt(bid, ask, "the two legs must not meet: the gap between them is the profit");
        assertEq(ask % pool.tickSize(), 0, "ask is off tick");
        assertEq(bid % pool.tickSize(), 0, "bid is off tick");
    }

    // -- settlement ------------------------------------------------------------

    function _settleSetup(uint256 yesNum, uint256 noNum, uint256 yesBps, uint256 noBps) internal {
        module.setMarketIds(MARKET_A, YES_ID, NO_ID);
        module.setPayoutBps(YES_ID, yesBps);
        module.setPayoutBps(NO_ID, noBps);
        usdc.mint(LucidTypes.MODULE, 1_000e6);

        uint256[] memory v = new uint256[](2);
        v[0] = yesNum;
        v[1] = noNum;
        market.setPayoutNumerators(v);
    }

    function test_settlement_redeems_and_raises_high_water_mark() public {
        _drive(MARKET_A, 8800, 5000);
        uint256 shares = pool.orderAt(0).quantity;
        uint256 spent = FUNDING - usdc.balanceOf(address(desk));

        _settleSetup(1, 0, LucidTypes.BPS, 0);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(module.finalizeCalls(), 1);
        assertEq(module.redeemCount(), 1, "only the paying leg is worth the gas");
        MockModule.RedeemCall memory r = module.redeemAt(0);
        assertEq(r.outcomeIdx, 0);
        assertEq(r.amount, shares);
        assertEq(r.operatorId, 4);
        assertEq(r.venueId, VENUE);

        uint256 expected = FUNDING - spent + shares;
        assertEq(desk.equity(), expected);
        assertEq(desk.state().highWaterMark, expected, "a winning window must lift the mark");
        assertEq(desk.state().consecutiveLosses, 0);
        assertEq(desk.state().openMarkets, 0);
    }

    function test_settlement_of_a_loser_bumps_the_loss_streak() public {
        _drive(MARKET_A, 8800, 5000);
        uint256 spent = FUNDING - usdc.balanceOf(address(desk));

        // The window resolved DOWN, so the YES leg the desk holds pays nothing.
        _settleSetup(0, 1, 0, LucidTypes.BPS);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Settled(MARKET_A, -int256(spent), FUNDING - spent);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(desk.state().consecutiveLosses, 1);
        assertEq(desk.state().openMarkets, 0);
        assertEq(desk.state().highWaterMark, FUNDING, "a loss must never lift the mark");
    }

    function test_settlement_survives_finalize_reverting() public {
        _drive(MARKET_A, 8800, 5000);
        uint256 shares = pool.orderAt(0).quantity;

        _settleSetup(1, 0, LucidTypes.BPS, 0);
        module.setRevertOnFinalize(true);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(module.redeemCount(), 1, "an already-finalized window must still redeem");
        assertEq(module.redeemAt(0).amount, shares);
        assertEq(desk.state().openMarkets, 0);
    }

    // -- getting the legs back before measuring what they paid ------------------
    //
    // A resting order ESCROWS. The moment the venue accepts a quote the outcome legs leave the
    // desk, and they stay gone until the order fills, expires or is cancelled. A settlement that
    // went straight to `redeem` therefore found a balance of zero on both legs, redeemed nothing,
    // measured a collateral delta of zero, and booked `pnl = 0 - 0 - cost`: the entire mint,
    // written off on a window the desk had called correctly. It happened four windows running on
    // chain, and the receipts carried two logs from the desk, none from the module, none from the
    // outcome token. The cancel is what puts something back to measure.

    /// The ordering is the property, not the pair of calls. A desk that redeemed first would be
    /// redeeming legs it does not hold, which is precisely the bug — so each cancel is checked
    /// against how far the settlement had already got when it arrived.
    function test_a_settling_maker_cancels_both_legs_before_it_redeems_anything() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _drive(MARKET_A, 6000, 5000);

        uint128[2] memory ids = desk.restingOrders(MARKET_A);
        assertTrue(ids[0] != 0 && ids[1] != 0, "both legs rested, so both ids are on file");
        assertEq(outcome.balanceOf(address(desk), YES_ID), 0, "and the venue is holding both");
        assertEq(outcome.balanceOf(address(desk), NO_ID), 0);

        // Resolved UP, so the YES leg pays in full.
        _settleSetup(1, 0, LucidTypes.BPS, 0);

        vm.expectEmit(true, false, false, true, address(desk));
        emit OrdersCancelled(MARKET_A, 2);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(pool.cancelledCount(), 2, "both legs pulled back off the book");
        assertEq(pool.cancelledAt(0), ids[0]);
        assertEq(pool.cancelledAt(1), ids[1]);
        assertEq(pool.redemptionsBeforeCancelAt(0), 0, "the first cancel ran before any redeem");
        assertEq(pool.redemptionsBeforeCancelAt(1), 0, "and so did the second");

        // The consequence of that ordering, in money: a redemption for the whole leg is only
        // possible because the leg was back in the desk when `redeem` read the balance.
        assertEq(module.redeemCount(), 1, "only the paying leg is worth the gas");
        assertEq(module.redeemAt(0).outcomeIdx, 0);
        assertEq(module.redeemAt(0).amount, 50e6, "the leg it got back, in full");
        assertEq(outcome.balanceOf(address(desk), NO_ID), 50e6, "the worthless leg came back too");
        assertEq(desk.equity(), FUNDING, "a complete set costs ONE and pays ONE");
        assertEq(desk.state().consecutiveLosses, 0, "and a flat window is not a loss");
    }

    /// A cancel is allowed to fail. The venue sweeps its own expired orders, and after a sweep the
    /// escrow is already home while the id is already dead — so the desk's cancel can only revert.
    /// That is an ordinary Tuesday, not a reason to abandon the other leg or the redemption.
    function test_a_cancel_that_reverts_does_not_stop_the_settlement() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _drive(MARKET_A, 6000, 5000);
        uint128[2] memory ids = desk.restingOrders(MARKET_A);

        pool.sweepExpired(ids[0]);
        assertEq(outcome.balanceOf(address(desk), YES_ID), 50e6, "the sweep already sent it home");

        _settleSetup(1, 0, LucidTypes.BPS, 0);

        // Attempted and swallowed: the call is made, it reverts, and the walk carries on.
        vm.expectCall(address(pool), abi.encodeCall(IBinaryPool.cancelOrder, (ids[0])));
        vm.expectEmit(true, false, false, true, address(desk));
        emit OrdersCancelled(MARKET_A, 1);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(pool.cancelledCount(), 1, "only the leg the venue had not already taken");
        assertEq(pool.cancelledAt(0), ids[1], "and it is the other one");
        assertEq(module.redeemCount(), 1, "the redemption happened regardless");
        assertEq(module.redeemAt(0).amount, 50e6);
        assertEq(desk.state().openMarkets, 0, "and the window closed");
        assertEq(desk.equity(), FUNDING);
    }

    /// Half the quote traded. Those legs are somebody else's now and no cancel brings them back,
    /// so the settlement has to redeem what the desk holds rather than what it minted.
    function test_a_filled_leg_settles_on_what_the_desk_actually_holds() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _drive(MARKET_A, 6000, 5000);
        uint128[2] memory ids = desk.restingOrders(MARKET_A);

        // Somebody lifted the YES quote at 0.62.
        pool.fillResting(ids[0]);
        uint256 proceeds = 50e6 * 620_000 / LucidTypes.ONE;
        assertEq(usdc.balanceOf(address(desk)), FUNDING - 50e6 + proceeds, "the fill paid the desk");
        assertEq(outcome.balanceOf(address(desk), YES_ID), 0, "and took the legs it was paid for");

        // Resolved DOWN, so the NO leg — the one still on the book — is the one that pays.
        _settleSetup(0, 1, 0, LucidTypes.BPS);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(pool.cancelledCount(), 1, "a sold leg cannot be cancelled back");
        assertEq(pool.cancelledAt(0), ids[1]);
        assertEq(module.redeemCount(), 1, "so only the leg the desk still holds is redeemed");
        assertEq(module.redeemAt(0).outcomeIdx, 1);
        assertEq(module.redeemAt(0).amount, 50e6);
        assertEq(desk.equity(), FUNDING + proceeds, "the spread it sold is the profit it keeps");
        assertEq(desk.state().openMarkets, 0);
    }

    /// The taker path leaves at most one order behind, and it escrows COLLATERAL rather than legs:
    /// an IOC that found no counterparty is money sitting with the venue under an id only this
    /// desk knows. Uncancelled it is the same total write-off, in the other asset.
    function test_a_taker_order_that_rested_is_cancelled_too() public {
        pool.setTakerOrdersRest(true);

        _drive(MARKET_A, 8800, 5000);

        uint128[2] memory ids = desk.restingOrders(MARKET_A);
        assertTrue(ids[0] != 0, "the taker leg is on file");
        assertEq(ids[1], 0, "and it is the only one a taker can leave");

        uint256 escrowed = FUNDING - usdc.balanceOf(address(desk));
        assertGt(escrowed, 0, "the venue is holding collateral against it");
        assertEq(outcome.balanceOf(address(desk), YES_ID), 0, "and the desk has no contracts at all");

        _settleSetup(1, 0, LucidTypes.BPS, 0);

        vm.expectEmit(true, false, false, true, address(desk));
        emit OrdersCancelled(MARKET_A, 1);
        vm.expectEmit(true, false, false, true, address(desk));
        emit Settled(MARKET_A, 0, FUNDING);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(pool.cancelledCount(), 1);
        assertEq(pool.cancelledAt(0), ids[0]);
        assertEq(module.redeemCount(), 0, "there was nothing to redeem, only escrow to reclaim");
        assertEq(desk.equity(), FUNDING, "an order that never filled costs nothing");
        assertEq(desk.state().consecutiveLosses, 0, "and must not count against the risk halt");
    }

    /// Pools are recycled and a `MarketInfo` can name one that is gone. Solidity emits an
    /// `extcodesize` guard for a typed external call and that guard reverts OUTSIDE the try/catch,
    /// so `try` alone would take down a handler shared with every other armed desk in the block.
    function test_a_pool_with_no_code_does_not_escape_the_catch() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _drive(MARKET_A, 6000, 5000);
        assertTrue(desk.restingOrders(MARKET_A)[0] != 0, "an id is on file, so the loop reaches the call");

        _settleSetup(1, 0, LucidTypes.BPS, 0);

        LucidTypes.MarketInfo memory m = _info(MARKET_A);
        m.pool = address(0xDEAD);
        assertEq(m.pool.code.length, 0, "nothing behind the address the window names");

        vm.prank(router);
        desk.onSettlement(m);

        assertEq(pool.cancelledCount(), 0, "nothing was cancelled, and nothing reverted either");
        assertEq(desk.state().openMarkets, 0, "the settlement still finished");
    }

    /// The live window, reproduced to the unit. A `Maker` under a 5 tUSDC mandate mints a complete
    /// set and rests both legs — `kind=1 price=20000 qty=5000000` and `kind=3 price=1000
    /// qty=5000000`, exactly what the chain recorded — and then the window settles.
    ///
    /// Four consecutive settlements booked `pnl = -5.000000`, the whole mint, and walked desk
    /// equity down 5000 → 4995 → 4990 → 4985 → 4980 while the committee was reading the market
    /// correctly. A complete set costs ONE and pays ONE: a quoted window nobody hit is flat, and
    /// the only thing standing between flat and a burned stake is getting the legs back first.
    function test_a_settled_maker_books_the_outcome_not_the_whole_mint() public {
        LucidTypes.Policy memory p = _makerPolicy();
        p.maxStakePerWindow = 5e6;
        vm.prank(owner);
        desk.setPolicy(p);

        // The committee said 0% UP, which is the verdict behind those two prices.
        _driveNoBook(MARKET_A, 0);

        assertEq(pool.orderAt(0).kind, LucidTypes.SELL_YES);
        assertEq(pool.orderAt(0).price, 20_000);
        assertEq(pool.orderAt(0).quantity, 5e6);
        assertEq(pool.orderAt(1).kind, LucidTypes.SELL_NO);
        assertEq(pool.orderAt(1).price, 1000);
        assertEq(pool.orderAt(1).quantity, 5e6);

        uint256 cost = FUNDING - usdc.balanceOf(address(desk));
        assertEq(cost, 5e6, "the mint, which is the number that used to be written off");

        // The window resolved DOWN. The desk was never wrong about the market.
        _settleSetup(0, 1, 0, LucidTypes.BPS);

        vm.recordLogs();
        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        int256 pnl = _settledPnl(vm.getRecordedLogs());
        // casting to 'int256' is safe because `cost` is a 6-decimal collateral balance.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertNotEq(pnl, -int256(cost), "the live bug: the entire stake booked as a loss");
        assertEq(pnl, 0, "a set costs ONE and pays ONE, so an unhit quote settles flat");
        assertEq(desk.equity(), FUNDING, "and every unit of the desk's money is still there");
        assertEq(desk.state().consecutiveLosses, 0, "so it never walks into its own risk halt");
    }

    /// @dev The pnl the desk actually published, read back out of its own `Settled` log rather
    /// than recomputed here: the number in the log is the number the operator saw go wrong.
    function _settledPnl(Vm.Log[] memory logs) internal pure returns (int256) {
        bytes32 topic = keccak256("Settled(bytes32,int256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                (int256 pnl,) = abi.decode(logs[i].data, (int256, uint256));
                return pnl;
            }
        }
        revert NoSettlementLogged();
    }

    // -- the property that protects every other desk in the fan-out ------------

    function test_never_reverts_when_the_pool_reverts() public {
        pool.setRevertOnEverything(true);

        // A pool that answers nothing fails at the first read, so the refusal names that read
        // rather than an order the venue was never shown.
        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.BookUnreadable, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        vm.prank(owner);
        desk.setPolicy(_makerPolicy());
        _drive(MARKET_B, 6000, 5000);

        vm.prank(router);
        desk.onLeaderTrade(_info(MARKET_A), LucidTypes.BUY_YES, 5e6);

        // A settlement whose market and module are both unreachable must also stay quiet.
        market.setRevertOnRead(true);
        module.setRevertOnRedeem(true);
        module.setRevertOnFinalize(true);
        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(desk.state().spentToday, 0);
        assertEq(desk.equity(), FUNDING);
    }

    // -- budgets and copy trading ----------------------------------------------

    function test_daily_budget_rolls_over_at_the_next_utc_day() public {
        LucidTypes.Policy memory p = _basePolicy();
        p.dailyBudget = 40e6;
        vm.prank(owner);
        desk.setPolicy(p);

        _drive(MARKET_A, 8800, 5000);
        assertEq(desk.state().spentToday, 38e6);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_B, LucidTypes.Refusal.DailyBudgetExceeded, 8800, 5000);
        _drive(MARKET_B, 8800, 5000);
        assertEq(pool.orderCount(), 1);

        vm.warp(START_TS + 1 days);
        _drive(MARKET_B, 8800, 5000);

        assertEq(pool.orderCount(), 2, "a new UTC day must reopen the budget");
        assertEq(desk.state().spentToday, 38e6);
        assertEq(desk.state().openMarkets, 2);
    }

    function test_follower_refuses_a_leader_trade_above_its_own_cap() public {
        vm.expectEmit(true, false, false, false, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.CapExceeded, 0, 0);

        vm.prank(router);
        desk.onLeaderTrade(_info(MARKET_A), LucidTypes.BUY_YES, 60e6);

        assertEq(pool.orderCount(), 0, "a follower must not inherit the size its leader used");
        assertEq(desk.state().openMarkets, 0);

        // The same follower still copies a trade that fits inside its own mandate.
        vm.prank(router);
        desk.onLeaderTrade(_info(MARKET_A), LucidTypes.BUY_YES, 10e6);

        assertEq(pool.orderCount(), 1);
        assertEq(pool.orderAt(0).kind, LucidTypes.BUY_YES);
        assertEq(desk.state().spentToday, 10e6);
    }

    function test_approvals_are_only_set_once_per_pool() public {
        _drive(MARKET_A, 8800, 5000);
        assertEq(usdc.approvalsBy(address(desk)), 1);
        assertEq(outcome.operatorGrantsBy(address(desk)), 2, "one grant for the pool, one for the module");

        _drive(MARKET_B, 8800, 5000);
        assertEq(pool.orderCount(), 2);
        assertEq(usdc.approvalsBy(address(desk)), 1, "the second window re-approved the same pool");
        assertEq(outcome.operatorGrantsBy(address(desk)), 2);
    }

    /// The venue has been seen finalizing markets with no outcome while its oracle was not
    /// publishing. That is an unresolved window, not a loss: the position must stay open and the
    /// loss streak must not move, or an upstream outage walks every desk into its own risk halt.
    function test_settlement_with_no_outcome_leaves_the_position_open() public {
        _drive(MARKET_A, 8800, 5000);

        uint8 lossesBefore = desk.state().consecutiveLosses;
        uint16 openBefore = desk.state().openMarkets;
        uint256 collateralBefore = usdc.balanceOf(address(desk));

        _settleSetup(0, 0, 0, 0);

        vm.prank(router);
        desk.onSettlement(_info(MARKET_A));

        assertEq(desk.state().consecutiveLosses, lossesBefore, "an unresolved window is not a loss");
        assertEq(desk.state().openMarkets, openBefore, "the position must stay open");
        assertEq(module.redeemCount(), 0, "nothing is redeemable yet");
        assertEq(usdc.balanceOf(address(desk)), collateralBefore, "no collateral moved");
    }

    // -- the wire format -------------------------------------------------------

    /// Splitting `VenueRejected` into four reasons is only safe because the split APPENDS. The
    /// deployed contracts, the SDK and the front end all decode this enum as a `uint8` position,
    /// so a value that moved would retitle every refusal in every log line ever emitted — a
    /// corruption that is invisible from the outside, because the numbers still decode to names.
    ///
    /// The numbering is therefore pinned as a list rather than as prose: the index of each name
    /// is the wire value, and any insertion, removal or reordering shifts one of them.
    function test_the_refusal_numbering_is_append_only() public pure {
        string[19] memory expected = [
            "None",
            "NotArmed",
            "AssetNotAllowed",
            "CadenceNotAllowed",
            "WindowTooShort",
            "CapExceeded",
            "DailyBudgetExceeded",
            "MaxOpenReached",
            "RiskHalt",
            "AiUnavailable",
            "AiMalformed",
            "LowEdge",
            "VenueRejected",
            "NoCredit",
            "InsufficientFunds",
            "NoBook",
            "BookUnreadable",
            "Unquotable",
            "MintFailed"
        ];

        assertEq(expected[uint256(LucidTypes.Refusal.None)], "None");
        assertEq(expected[uint256(LucidTypes.Refusal.NotArmed)], "NotArmed");
        assertEq(expected[uint256(LucidTypes.Refusal.AssetNotAllowed)], "AssetNotAllowed");
        assertEq(expected[uint256(LucidTypes.Refusal.CadenceNotAllowed)], "CadenceNotAllowed");
        assertEq(expected[uint256(LucidTypes.Refusal.WindowTooShort)], "WindowTooShort");
        assertEq(expected[uint256(LucidTypes.Refusal.CapExceeded)], "CapExceeded");
        assertEq(expected[uint256(LucidTypes.Refusal.DailyBudgetExceeded)], "DailyBudgetExceeded");
        assertEq(expected[uint256(LucidTypes.Refusal.MaxOpenReached)], "MaxOpenReached");
        assertEq(expected[uint256(LucidTypes.Refusal.RiskHalt)], "RiskHalt");
        assertEq(expected[uint256(LucidTypes.Refusal.AiUnavailable)], "AiUnavailable");
        assertEq(expected[uint256(LucidTypes.Refusal.AiMalformed)], "AiMalformed");
        assertEq(expected[uint256(LucidTypes.Refusal.LowEdge)], "LowEdge");
        assertEq(expected[uint256(LucidTypes.Refusal.VenueRejected)], "VenueRejected");
        assertEq(expected[uint256(LucidTypes.Refusal.NoCredit)], "NoCredit");
        assertEq(expected[uint256(LucidTypes.Refusal.InsufficientFunds)], "InsufficientFunds");
        assertEq(expected[uint256(LucidTypes.Refusal.NoBook)], "NoBook");
        assertEq(expected[uint256(LucidTypes.Refusal.BookUnreadable)], "BookUnreadable");
        assertEq(expected[uint256(LucidTypes.Refusal.Unquotable)], "Unquotable");
        assertEq(expected[uint256(LucidTypes.Refusal.MintFailed)], "MintFailed");
    }

}


/// @dev A desk that only flips its own flag is invisible to the router's fan-out, which walks the
/// router's list rather than asking each desk. That is not observable in a unit test that talks to
/// the desk directly, so it is pinned here explicitly.
contract ArmRecordingRouter {
    mapping(address => bool) public deskArmed;
    uint256 public calls;
    bool public shouldRevert;

    function setDeskArmed(address desk, bool on) external {
        if (shouldRevert) revert("router refused");
        deskArmed[desk] = on;
        calls++;
    }

    function setShouldRevert(bool on) external {
        shouldRevert = on;
    }
}

contract LucidDeskArmSyncTest is Test {
    LucidDesk internal desk;
    ArmRecordingRouter internal router;
    address internal owner = address(0xA11CE);
    address internal brain = address(0xB4A11);

    function setUp() public {
        router = new ArmRecordingRouter();
        desk = LucidDesk(payable(Clones.clone(address(new LucidDesk()))));
        desk.initialize(owner, address(router), brain);
    }

    function test_arming_tells_the_router() public {
        vm.prank(owner);
        desk.arm(true);
        assertTrue(router.deskArmed(address(desk)));
    }

    function test_disarming_tells_the_router() public {
        vm.startPrank(owner);
        desk.arm(true);
        desk.arm(false);
        vm.stopPrank();
        assertFalse(router.deskArmed(address(desk)));
    }

    function test_setting_a_policy_syncs_the_armed_flag() public {
        LucidTypes.Policy memory p;
        p.armed = true;
        p.maxStakePerWindow = 1e6;
        p.dailyBudget = 10e6;
        p.maxOpenMarkets = 1;
        vm.prank(owner);
        desk.setPolicy(p);
        assertTrue(router.deskArmed(address(desk)));
    }

    /// Arming is an explicit instruction, so a router that will not record it must fail the
    /// transaction rather than leave the owner believing a silent desk is live.
    function test_arming_fails_loudly_when_the_router_refuses() public {
        router.setShouldRevert(true);
        vm.prank(owner);
        vm.expectRevert();
        desk.arm(true);
    }

    /// The opening policy is set by the factory before the desk is registered, so that path stays
    /// best-effort or every desk creation would revert.
    function test_setting_a_policy_survives_a_router_that_refuses() public {
        router.setShouldRevert(true);
        LucidTypes.Policy memory p;
        p.armed = true;
        p.maxStakePerWindow = 1e6;
        vm.prank(owner);
        desk.setPolicy(p);
        assertTrue(desk.policy().armed);
    }
}
