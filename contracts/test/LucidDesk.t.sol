// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

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
    event ArmedSet(bool on);
    event PolicySet(LucidTypes.Policy policy);

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

    function _drive(bytes32 id, uint16 probUpBps, uint256 pBookBps) internal {
        vm.prank(router);
        desk.onVerdict(_info(id), _verdict(probUpBps, true), pBookBps);
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
        desk.onVerdict(m, _verdict(8800, true), 5000);
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
        desk.onVerdict(_info(MARKET_A), _verdict(8800, false), 5000);

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

    function test_venue_returning_false_is_refused_not_executed() public {
        pool.setPlaceSucceeds(false);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.VenueRejected, 8800, 5000);
        _drive(MARKET_A, 8800, 5000);

        assertEq(desk.state().spentToday, 0, "a silent rejection was booked as a trade");
        assertEq(desk.state().openMarkets, 0);
        assertEq(desk.equity(), FUNDING);
    }

    // -- making a market -------------------------------------------------------

    function test_maker_mints_a_set_and_rests_both_legs() public {
        vm.prank(owner);
        desk.setPolicy(_makerPolicy());

        _drive(MARKET_A, 6000, 5000);

        assertEq(pool.mintSetCalls(), 1, "a maker needs no counterparty, only a complete set");
        assertEq(pool.lastMintSetAmount(), 10e6);
        assertEq(pool.orderCount(), 2);

        MockBinaryPool.Order memory yes = pool.orderAt(0);
        assertEq(yes.kind, LucidTypes.SELL_YES);
        assertEq(yes.orderType, LucidTypes.ORDER_POST_ONLY);
        assertEq(yes.price, 620_000, "fair plus the spread");
        assertEq(yes.quantity, 10e6);

        MockBinaryPool.Order memory no = pool.orderAt(1);
        assertEq(no.kind, LucidTypes.SELL_NO);
        assertEq(no.orderType, LucidTypes.ORDER_POST_ONLY);
        assertEq(no.price, 580_000, "the NO quote, converted to the YES side the venue wants");
        assertEq(no.quantity, 10e6);

        assertEq(outcome.balanceOf(address(desk), YES_ID), 10e6);
        assertEq(outcome.balanceOf(address(desk), NO_ID), 10e6);
        assertEq(desk.state().spentToday, 10e6);
        assertEq(desk.state().openMarkets, 1);
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

    // -- the property that protects every other desk in the fan-out ------------

    function test_never_reverts_when_the_pool_reverts() public {
        pool.setRevertOnEverything(true);

        vm.expectEmit(true, false, false, true, address(desk));
        emit Refused(MARKET_A, LucidTypes.Refusal.VenueRejected, 8800, 5000);
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
}
