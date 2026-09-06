// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LucidSeries} from "../src/LucidSeries.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

import {MockMarketCreator} from "./mocks/MockMarketCreator.sol";

/// @notice A recipient that will not take native balance.
/// @dev Kept here rather than in `test/mocks/` because it exists for exactly one property: a
/// withdrawal that silently did nothing would leave the operator believing a locked float had been
/// recovered when it had not.
contract RejectsNative {
    error NotAcceptingFunds();

    receive() external payable {
        revert NotAcceptingFunds();
    }
}

/// @title LucidSeriesTest
/// @notice Exercises the contract that keeps a short-cadence window open when the venue's own
/// scheduler stops opening them.
///
/// Four properties are worth more than the rest of this file, because each of them is either money
/// or an outage:
///
///   1. Neither hook reverts past its access check. Both are reached from inside a reactivity
///      handler, where a revert discards the whole firing rather than one roll.
///   2. Every refusal names itself. A roll costs the creator about 2.8 SOMI, and an operator who
///      cannot tell `LOW_FLOAT` from `VENUE_HEALTHY` from `NO_GAS` cannot run this.
///   3. The budget guards are guards, not intentions. The daily cap and the float floor hold
///      against repeated driving, including re-entrant driving, because `rollNow` is
///      permissionless.
///   4. A roll is only ever reported when `triggerRoll` returned. A creator with no code accepts a
///      call that returns nothing and executes nothing, which is the easiest way to fabricate a
///      window that does not exist.
contract LucidSeriesTest is Test {
    /// @dev 01:00 UTC on the day of the observed Shannon run. Chosen on a day boundary rather than
    /// at an arbitrary instant so a test can warp forward for hours without silently crossing the
    /// boundary `rollsToday` resets on and passing for the wrong reason.
    uint256 internal constant BASE = 1_788_566_400 + 3_600;

    uint32 internal constant SERIES_ID = 1;
    /// @dev The cadence of the series proved on Shannon: a 300-second window, 300-second
    /// settlement.
    uint32 internal constant INTERVAL = 300;
    /// @dev Three cadences, which is what the contract derives when the owner sets no override.
    uint256 internal constant STALENESS = 900;

    address internal owner = makeAddr("owner");
    address internal router = makeAddr("router");
    address internal stranger = makeAddr("stranger");

    LucidSeries internal series;
    MockMarketCreator internal creator;

    function setUp() public {
        vm.warp(BASE);

        creator = new MockMarketCreator();
        // Comfortably above the 35 SOMI floor: enough float that the money guards only fire when a
        // test asks them to.
        vm.deal(address(creator), 100 ether);

        series = new LucidSeries(owner, router);
        vm.prank(owner);
        series.setSeries(address(creator), SERIES_ID, INTERVAL);
    }

    // ── defaults ──────────────────────────────────────────────────────────────

    /// @dev `Failover` rather than `Off`, because a contract deployed to cover an outage that has
    /// to be switched on by hand is a contract that will be off during the outage.
    function test_default_mode_is_failover() public view {
        assertEq(uint8(series.mode()), uint8(LucidSeries.Mode.Failover), "Failover out of the box");
        assertEq(series.maxRollsPerDay(), 12, "twelve rolls, about an hour of a 300s cadence");
        assertEq(series.minCreatorFloat(), 35 ether, "the level armFirstRoll was seen to fail below");
    }

    /// @dev A watcher that has never seen a market knows nothing about the venue. Seeding the
    /// heartbeat at deployment is what stops ignorance from reading as an outage and rolling on the
    /// first tick after every deploy.
    function test_deployment_seeds_the_venue_heartbeat() public view {
        (, bool healthy, uint64 lastSeen,,,) = series.status();
        assertTrue(healthy, "one staleness window of grace");
        assertEq(lastSeen, uint64(BASE), "seeded at deployment");
    }

    function test_staleness_defaults_to_three_cadences_with_a_floor() public {
        assertEq(series.stalenessSeconds(), 900, "3 x 300");

        // A 60-second cadence would otherwise declare an outage after three minutes of jitter.
        vm.prank(owner);
        series.setSeries(address(creator), SERIES_ID, 60);
        assertEq(series.stalenessSeconds(), series.MIN_STALENESS(), "floored at 180");

        vm.prank(owner);
        series.setStaleness(600);
        assertEq(series.stalenessSeconds(), 600, "the override wins");

        vm.prank(owner);
        series.setStaleness(0);
        assertEq(series.stalenessSeconds(), series.MIN_STALENESS(), "and zero restores the default");
    }

    // ── Failover: the operating mode ──────────────────────────────────────────

    /// @dev The whole economic argument for `Failover`. While DreamDEX's own scheduler is rolling,
    /// this contract spends nothing at all.
    function test_a_healthy_venue_is_never_rolled_for() public {
        _tick();
        assertEq(creator.rollCalls(), 0, "the venue is doing its job");

        // Still healthy one second before the threshold, and still not our problem.
        vm.warp(BASE + STALENESS);
        _expectSkip(series.REASON_VENUE_HEALTHY());
        _tick();
        assertEq(creator.rollCalls(), 0, "nothing spent");
    }

    /// @dev The 4 September signature: the venue stops producing windows of the cadence this
    /// protocol trades, and after three of them are missed we take over.
    function test_staleness_crossing_triggers_exactly_one_roll() public {
        vm.warp(BASE + STALENESS + 1);

        vm.expectEmit(true, false, false, false, address(series));
        emit LucidSeries.Rolled(SERIES_ID, 0);
        _tick();

        assertEq(creator.rollCalls(), 1, "we took over");
        assertEq(creator.lastSeriesId(), SERIES_ID, "our own series");

        // A settlement firing carries several markets, and each one ticks. One window at a time.
        _expectSkip(series.REASON_TOO_SOON());
        _tick();
        _tick();
        assertEq(creator.rollCalls(), 1, "exactly one roll for the crossing");
    }

    /// @dev A roll that measured 61.6M on Shannon has to actually be handed that much, or the
    /// caught revert would blame the creator for a stipend that was ours.
    function test_the_creator_is_handed_a_stipend_a_real_roll_fits_in() public {
        vm.warp(BASE + STALENESS + 1);
        _tick();

        assertGe(creator.lastGasReceived(), 61_600_000, "the measured cost of a live roll");
        assertLe(creator.lastGasReceived(), series.ROLL_GAS(), "and never more than the ceiling");
    }

    /// @dev An hourly window says nothing about whether the five-minute roller is alive. Counting
    /// it as a heartbeat would mask exactly the outage this contract watches for.
    function test_only_the_watched_cadence_counts_as_a_heartbeat() public {
        vm.warp(BASE + STALENESS + 1);

        vm.prank(router);
        series.onVenueMarket(_market(3600));

        _tick();
        assertEq(creator.rollCalls(), 1, "an hourly market is not evidence the 300s roller is alive");
    }

    function test_a_watched_cadence_market_stands_the_venue_back_up() public {
        vm.warp(BASE + STALENESS + 1);
        _tick();
        assertEq(creator.rollCalls(), 1, "we took over during the outage");

        // The venue comes back. From here on this contract costs nothing again.
        vm.warp(BASE + STALENESS + 400);
        vm.prank(router);
        series.onVenueMarket(_market(INTERVAL));

        (, bool healthy, uint64 lastSeen,,,) = series.status();
        assertTrue(healthy, "the venue is rolling again");
        assertEq(lastSeen, uint64(BASE + STALENESS + 400), "heartbeat recorded");

        vm.warp(BASE + STALENESS + 800);
        _expectSkip(series.REASON_VENUE_HEALTHY());
        _tick();
        assertEq(creator.rollCalls(), 1, "and we stand down");
    }

    // ── the other two modes ───────────────────────────────────────────────────

    /// @dev Implemented properly, and not the mode this protocol operates in: 12 windows an hour at
    /// about 2.8 SOMI each is roughly 34 SOMI an hour.
    function test_continuous_rolls_regardless_of_venue_health() public {
        _setMode(LucidSeries.Mode.Continuous);

        // A venue market seconds ago: as healthy as it gets.
        vm.prank(router);
        series.onVenueMarket(_market(INTERVAL));

        _tick();
        assertEq(creator.rollCalls(), 1, "independence, at 34 SOMI an hour");

        vm.warp(BASE + INTERVAL);
        _tick();
        assertEq(creator.rollCalls(), 2, "every window");
    }

    function test_off_never_rolls() public {
        _setMode(LucidSeries.Mode.Off);
        vm.warp(BASE + STALENESS + 1);

        _expectSkip(series.REASON_OFF());
        _tick();

        vm.prank(stranger);
        series.rollNow();

        assertEq(creator.rollCalls(), 0, "not from the router, not from anywhere");
    }

    // ── the budget guards ─────────────────────────────────────────────────────

    /// @dev The float floor is the point of the contract read back at itself. Rolling towards the
    /// line rather than stopping at it would leave the series in the exact state this contract
    /// exists to route around: a creator that cannot schedule its oracle questions.
    function test_low_float_refuses_and_does_not_call_the_creator() public {
        _setMode(LucidSeries.Mode.Continuous);
        creator.setFloat(35 ether - 1 wei);

        _expectSkip(series.REASON_LOW_FLOAT());
        _tick();

        assertEq(creator.rollCalls(), 0, "the creator was never reached");
        (,,,, uint32 rolls,) = series.status();
        assertEq(rolls, 0, "and nothing was counted");

        // Exactly at the floor is enough; the floor is where `armFirstRoll` was seen to still work.
        creator.setFloat(35 ether);
        _tick();
        assertEq(creator.rollCalls(), 1, "at the floor it rolls");
    }

    function test_the_daily_cap_holds() public {
        _setMode(LucidSeries.Mode.Continuous);

        uint256 cap = series.maxRollsPerDay();
        for (uint256 i; i < cap; ++i) {
            vm.warp(BASE + i * INTERVAL);
            _tick();
        }
        assertEq(creator.rollCalls(), cap, "the whole budget, and no more than it");

        vm.warp(BASE + cap * INTERVAL);
        _expectSkip(series.REASON_DAILY_CAP());
        _tick();
        assertEq(creator.rollCalls(), cap, "the cap is a cap");

        (,,,, uint32 rolls,) = series.status();
        assertEq(rolls, uint32(cap), "reported as spent");
    }

    /// @dev The desk's daily budget rolls on the same UTC boundary, so the float's does too.
    function test_rollsToday_resets_across_a_utc_day() public {
        _setMode(LucidSeries.Mode.Continuous);
        vm.prank(owner);
        series.setBudget(2, 35 ether);

        _tick();
        vm.warp(BASE + INTERVAL);
        _tick();
        assertEq(creator.rollCalls(), 2, "the whole of today's budget");

        vm.warp(BASE + 2 * INTERVAL);
        _expectSkip(series.REASON_DAILY_CAP());
        _tick();

        // 01:00 UTC plus 23 hours and change is the next day.
        vm.warp(BASE + 1 days);
        _tick();
        assertEq(creator.rollCalls(), 3, "tomorrow's budget is a new budget");

        (,,,, uint32 rolls,) = series.status();
        assertEq(rolls, 1, "counted against today");
    }

    /// @dev A counter left on yesterday's day would charge yesterday's rolls against today's cap.
    /// `status` therefore reports against the current day rather than against whichever day the
    /// counter was last written in.
    function test_status_reports_todays_count_not_a_stale_one() public {
        _setMode(LucidSeries.Mode.Continuous);
        _tick();

        (,,,, uint32 sameDay,) = series.status();
        assertEq(sameDay, 1, "written today");

        vm.warp(BASE + 1 days);
        (,,,, uint32 nextDay,) = series.status();
        assertEq(nextDay, 0, "a stale counter never reads as a spent budget");
    }

    function test_too_soon_holds_within_one_interval() public {
        _setMode(LucidSeries.Mode.Continuous);
        _tick();

        vm.warp(BASE + INTERVAL - 1);
        _expectSkip(series.REASON_TOO_SOON());
        _tick();
        assertEq(creator.rollCalls(), 1, "not a second early");

        vm.warp(BASE + INTERVAL);
        _tick();
        assertEq(creator.rollCalls(), 2, "and exactly on the cadence");
    }

    function test_a_zero_cap_stops_rolling_entirely() public {
        _setMode(LucidSeries.Mode.Continuous);
        vm.prank(owner);
        series.setBudget(0, 35 ether);

        _expectSkip(series.REASON_DAILY_CAP());
        _tick();
        assertEq(creator.rollCalls(), 0, "a budget of nothing spends nothing");
    }

    // ── refusals that are about us, not about the money ───────────────────────

    function test_no_series_when_nothing_is_configured() public {
        LucidSeries bare = new LucidSeries(owner, router);
        vm.prank(owner);
        bare.setMode(LucidSeries.Mode.Continuous);

        vm.expectEmit(true, false, false, false, address(bare));
        emit LucidSeries.RollSkipped(bare.REASON_NO_SERIES());
        vm.prank(router);
        bare.onTick(_market(INTERVAL));
    }

    /// @dev `triggerRoll` returns nothing, so a call into an address with no code succeeds having
    /// executed nothing — the compiler inserts no `extcodesize` check to catch it and `try` has
    /// nothing to catch. Without the guard this contract would emit `Rolled` and count a window
    /// that does not exist. The guard is `code.length`, before the call.
    function test_a_codeless_creator_does_not_escape_the_catch() public {
        _setMode(LucidSeries.Mode.Continuous);
        vm.prank(owner);
        series.setSeries(makeAddr("notAContract"), SERIES_ID, INTERVAL);

        vm.recordLogs();
        vm.prank(router);
        series.onTick(_market(INTERVAL));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countReason(logs, series.REASON_NO_SERIES()), 1, "named, not silently skipped");
        assertEq(_countTopic(logs, LucidSeries.Rolled.selector), 0, "and never reported as a roll");

        (,,, uint64 lastRoll, uint32 rolls,) = series.status();
        assertEq(lastRoll, 0, "the clock never moved");
        assertEq(rolls, 0, "nothing counted");
    }

    /// @dev A stipend below the measured cost of a live roll is refused rather than spent. The
    /// alternative is a caught out-of-gas that is indistinguishable from a broken creator, and a
    /// log that sends whoever reads it to debug the wrong contract.
    function test_a_thin_frame_is_named_as_our_shortfall_not_the_creators() public {
        _setMode(LucidSeries.Mode.Continuous);

        vm.recordLogs();
        (bool ok,) = address(series).call{gas: 1_000_000}(abi.encodeCall(LucidSeries.rollNow, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "and it still did not revert");
        assertEq(_countReason(logs, series.REASON_NO_GAS()), 1, "the shortfall was ours");
        assertEq(creator.rollCalls(), 0, "so the creator was never called");
    }

    // ── the creator misbehaving ───────────────────────────────────────────────

    /// @dev The failure that shipped this contract. The creator's own auto-roll completed the roll
    /// and then reverted `PRECOMPILE_REVERTED` on the re-subscribe, unwinding everything it had
    /// just done. A revert here must be caught, reported, and must leave nothing behind that claims
    /// a window was rolled.
    function test_a_reverting_creator_is_caught_and_reported_not_propagated() public {
        _setMode(LucidSeries.Mode.Continuous);
        creator.setRevertOnRoll(true);

        vm.expectEmit(true, false, false, true, address(series));
        emit LucidSeries.RollFailed(SERIES_ID, abi.encodeWithSelector(MockMarketCreator.PrecompileReverted.selector));
        vm.prank(router);
        series.onTick(_market(INTERVAL));

        (,,, uint64 lastRoll, uint32 rolls,) = series.status();
        assertEq(lastRoll, 0, "a reverted roll spent nothing, so the clock is put back");
        assertEq(rolls, 0, "and the budget is put back too");

        // Put back, and therefore retryable in the same window rather than silenced until the next.
        creator.setRevertOnRoll(false);
        _tick();
        assertEq(creator.rollCalls(), 1, "the retry goes through");
    }

    function test_a_failed_roll_is_never_reported_as_a_roll() public {
        _setMode(LucidSeries.Mode.Continuous);
        creator.setRevertOnRoll(true);

        vm.recordLogs();
        _tick();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countTopic(logs, LucidSeries.Rolled.selector), 0, "no Rolled");
        assertEq(_countTopic(logs, LucidSeries.RollFailed.selector), 1, "one RollFailed");
    }

    /// @dev The load-bearing property. Both hooks run inside a reactivity handler, where a revert
    /// does not fail one roll — it discards the settlement fan-out for every desk woken in the same
    /// firing, and the router is charged for the gas anyway.
    function test_the_hooks_never_revert_however_broken_the_creator_is() public {
        _setMode(LucidSeries.Mode.Continuous);
        creator.setRevertOnRoll(true);
        creator.setFloat(0);

        vm.prank(router);
        series.onTick(_market(INTERVAL));

        vm.prank(router);
        series.onVenueMarket(_market(INTERVAL));

        vm.prank(owner);
        series.setSeries(makeAddr("gone"), SERIES_ID, INTERVAL);

        vm.prank(router);
        series.onTick(_market(INTERVAL));
    }

    // ── every refusal names itself ────────────────────────────────────────────

    /// @dev A roll is real money, so "we decided not to" and "nothing happened" must never look the
    /// same from outside. Every reason the contract can decline for is reachable and distinct.
    function test_every_refusal_emits_its_exact_reason() public {
        vm.recordLogs();

        // OFF
        _setMode(LucidSeries.Mode.Off);
        _tick();

        // NO_SERIES
        _setMode(LucidSeries.Mode.Continuous);
        vm.prank(owner);
        series.setSeries(address(0), 0, 0);
        _tick();
        vm.prank(owner);
        series.setSeries(address(creator), SERIES_ID, INTERVAL);

        // VENUE_HEALTHY
        _setMode(LucidSeries.Mode.Failover);
        _tick();

        // DAILY_CAP
        _setMode(LucidSeries.Mode.Continuous);
        vm.prank(owner);
        series.setBudget(0, 35 ether);
        _tick();

        // LOW_FLOAT
        vm.prank(owner);
        series.setBudget(12, 35 ether);
        creator.setFloat(1 ether);
        _tick();

        // TOO_SOON: one real roll, then a second attempt inside the same window.
        creator.setFloat(100 ether);
        _tick();
        _tick();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countReason(logs, series.REASON_OFF()), 1, "OFF");
        assertEq(_countReason(logs, series.REASON_NO_SERIES()), 1, "NO_SERIES");
        assertEq(_countReason(logs, series.REASON_VENUE_HEALTHY()), 1, "VENUE_HEALTHY");
        assertEq(_countReason(logs, series.REASON_DAILY_CAP()), 1, "DAILY_CAP");
        assertEq(_countReason(logs, series.REASON_LOW_FLOAT()), 1, "LOW_FLOAT");
        assertEq(_countReason(logs, series.REASON_TOO_SOON()), 1, "TOO_SOON");
        assertEq(_countTopic(logs, LucidSeries.Rolled.selector), 1, "and exactly one roll happened");
    }

    // ── access control ────────────────────────────────────────────────────────

    function test_only_the_router_may_drive_the_hooks() public {
        vm.warp(BASE + STALENESS + 1);

        vm.prank(stranger);
        vm.expectRevert(LucidSeries.NotRouter.selector);
        series.onTick(_market(INTERVAL));

        vm.prank(stranger);
        vm.expectRevert(LucidSeries.NotRouter.selector);
        series.onVenueMarket(_market(INTERVAL));

        vm.prank(owner);
        vm.expectRevert(LucidSeries.NotRouter.selector);
        series.onTick(_market(INTERVAL));

        assertEq(creator.rollCalls(), 0, "no roll from an outsider");
    }

    /// @dev The one entry point that is deliberately open, because during an outage there may be no
    /// handler firing at all and somebody has to be able to drive it.
    function test_rollNow_is_permissionless_but_obeys_every_guard() public {
        vm.warp(BASE + STALENESS + 1);

        vm.prank(stranger);
        series.rollNow();
        assertEq(creator.rollCalls(), 1, "anyone may drive it");

        _expectSkip(series.REASON_TOO_SOON());
        vm.prank(stranger);
        series.rollNow();
        assertEq(creator.rollCalls(), 1, "and it decides nothing");
    }

    function test_only_the_owner_may_set_mode_series_budget_and_staleness() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.setMode(LucidSeries.Mode.Continuous);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.setSeries(stranger, 9, 60);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.setBudget(1000, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.setStaleness(1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.setRouter(stranger);

        assertEq(uint8(series.mode()), uint8(LucidSeries.Mode.Failover), "unchanged");
        assertEq(series.creator(), address(creator), "unchanged");
        assertEq(series.maxRollsPerDay(), 12, "unchanged");
        assertEq(series.stalenessOverride(), 0, "unchanged");
        assertEq(series.router(), router, "unchanged");
    }

    function test_setRouter_moves_the_permission() public {
        address newRouter = makeAddr("newRouter");

        vm.expectEmit(false, false, false, true, address(series));
        emit LucidSeries.RouterSet(newRouter);
        vm.prank(owner);
        series.setRouter(newRouter);

        vm.prank(router);
        vm.expectRevert(LucidSeries.NotRouter.selector);
        series.onTick(_market(INTERVAL));

        vm.warp(BASE + STALENESS + 1);
        vm.prank(newRouter);
        series.onTick(_market(INTERVAL));
        assertEq(creator.rollCalls(), 1, "the new router drives it");
    }

    /// @dev A series with a creator and no window length would make the cadence guard vacuous and
    /// the derived staleness threshold meaningless — a configuration that can only spend by
    /// accident.
    function test_setSeries_refuses_a_zero_interval() public {
        vm.prank(owner);
        vm.expectRevert(LucidSeries.BadInterval.selector);
        series.setSeries(address(creator), SERIES_ID, 0);

        // Detaching entirely is allowed, because it spends nothing.
        vm.prank(owner);
        series.setSeries(address(0), 0, 0);
        assertEq(series.creator(), address(0), "detached");
    }

    /// @dev Re-pointing must not be a way to spend past the guards. If `setSeries` cleared the
    /// clock and the counter, the owner could call it in a loop and roll every block.
    function test_setSeries_does_not_reset_the_spending_guards() public {
        _setMode(LucidSeries.Mode.Continuous);
        _tick();
        assertEq(creator.rollCalls(), 1, "one roll on the record");

        MockMarketCreator other = new MockMarketCreator();
        vm.deal(address(other), 100 ether);
        vm.prank(owner);
        series.setSeries(address(other), 7, INTERVAL);

        _expectSkip(series.REASON_TOO_SOON());
        _tick();
        assertEq(other.rollCalls(), 0, "the cadence guard survives a re-point");

        (,,, uint64 lastRoll, uint32 rolls,) = series.status();
        assertEq(lastRoll, uint64(BASE), "and so does the clock");
        assertEq(rolls, 1, "and the day's count");
    }

    // ── the reserve ───────────────────────────────────────────────────────────

    /// @dev The reserve is a large locked balance, and a series that could take SOMI and not give
    /// it back would be a worse counterparty than the empty creator this contract routes around.
    function test_withdrawNative_is_owner_only_and_moves_the_float() public {
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        series.fund{value: 6 ether}();
        assertEq(address(series).balance, 6 ether, "held");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.withdrawNative(stranger, 1 ether);
        assertEq(address(series).balance, 6 ether, "an outsider moves nothing");

        // Topping the creator back up is the ordinary use: `to` is any address, and the creator's
        // float is the address that usually needs it.
        uint256 floatBefore = address(creator).balance;
        vm.expectEmit(true, false, false, true, address(series));
        emit LucidSeries.Withdrawn(address(creator), 4 ether);
        vm.prank(owner);
        series.withdrawNative(address(creator), 4 ether);

        assertEq(address(creator).balance, floatBefore + 4 ether, "the float was refilled");
        assertEq(address(series).balance, 2 ether, "and the reserve debited");
    }

    function test_fund_is_owner_only() public {
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        series.fund{value: 1 ether}();

        assertEq(address(series).balance, 0, "and there is no receive() to fall back on");
    }

    function test_withdrawNative_refuses_a_zero_recipient_and_a_rejecting_one() public {
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        series.fund{value: 3 ether}();

        vm.prank(owner);
        vm.expectRevert(LucidSeries.ZeroAddress.selector);
        series.withdrawNative(address(0), 1 ether);

        address rejecting = address(new RejectsNative());
        vm.prank(owner);
        vm.expectRevert(LucidSeries.WithdrawFailed.selector);
        series.withdrawNative(rejecting, 1 ether);

        assertEq(address(series).balance, 3 ether, "a withdrawal that did not land is not silent");
    }

    // ── status ────────────────────────────────────────────────────────────────

    function test_status_reports_what_an_operator_needs_to_answer_why_not() public {
        _setMode(LucidSeries.Mode.Continuous);
        vm.warp(BASE + STALENESS + 1);
        _tick();

        (LucidSeries.Mode mode, bool healthy, uint64 lastVenueAt, uint64 lastRoll, uint32 rolls, uint256 float) =
            series.status();

        assertEq(uint8(mode), uint8(LucidSeries.Mode.Continuous), "mode");
        assertFalse(healthy, "the venue has gone quiet");
        assertEq(lastVenueAt, uint64(BASE), "last heartbeat");
        assertEq(lastRoll, uint64(BASE + STALENESS + 1), "when we rolled");
        assertEq(rolls, 1, "one roll today");
        assertEq(float, address(creator).balance, "the number that ran out on 4 September");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _tick() internal {
        vm.prank(router);
        series.onTick(_market(INTERVAL));
    }

    function _setMode(LucidSeries.Mode m) internal {
        vm.prank(owner);
        series.setMode(m);
    }

    function _expectSkip(bytes32 reason) internal {
        vm.expectEmit(true, false, false, false, address(series));
        emit LucidSeries.RollSkipped(reason);
    }

    /// @dev How many refusals named one exact reason. The reason is the whole point of the event.
    function _countReason(Vm.Log[] memory logs, bytes32 reason) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(series)) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != LucidSeries.RollSkipped.selector) continue;
            if (logs[i].topics[1] != reason) continue;
            ++count;
        }
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(series)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) ++count;
        }
    }

    /// @dev Shaped like the router's own decoded log: the hooks are handed a window, not an id.
    function _market(uint32 intervalSec) internal pure returns (LucidTypes.MarketInfo memory) {
        return LucidTypes.MarketInfo({
            marketId: bytes32(uint256(0x14898)),
            market: 0xc7B7f71513EAF972B9Ff6C0DDb6144E322bA63B0,
            pool: 0xcc2c4f74C8c3Dd5684EE2e18B1eb8fB1952fb308,
            operatorId: 19,
            venueId: 0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581,
            yesId: 1,
            noId: 2,
            tradingStart: uint64(BASE),
            expiry: uint64(BASE) + intervalSec,
            nonce: 1,
            strike: 7_971_864,
            assetKey: LucidTypes.ASSET_BTC,
            intervalSec: intervalSec
        });
    }
}
