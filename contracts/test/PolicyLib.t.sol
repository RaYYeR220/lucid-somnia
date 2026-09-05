// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {PolicyLib} from "../src/lib/PolicyLib.sol";

/// @notice Thin external wrapper around the library.
/// @dev Every PolicyLib function is `internal pure`, so the suite reaches it through a real
/// contract boundary. That boundary is what lets a test observe a revert instead of inheriting it.
contract PolicyHarness {
    function preCheck(
        LucidTypes.Policy calldata p,
        LucidTypes.DeskState calldata s,
        LucidTypes.MarketInfo calldata m,
        uint256 nowTs
    ) external pure returns (LucidTypes.Refusal) {
        return PolicyLib.preCheck(p, s, m, nowTs);
    }

    function gate(
        LucidTypes.Policy calldata p,
        LucidTypes.DeskState calldata s,
        LucidTypes.MarketInfo calldata m,
        LucidTypes.Verdict calldata v,
        uint256 pBookBps,
        uint256 stake,
        uint256 equity,
        uint256 nowTs
    ) external pure returns (LucidTypes.Refusal) {
        return PolicyLib.gate(p, s, m, v, pBookBps, stake, equity, nowTs);
    }

    function maxStake(LucidTypes.Policy calldata p, LucidTypes.DeskState calldata s)
        external
        pure
        returns (uint64)
    {
        return PolicyLib.maxStake(p, s);
    }

    function assetBit(bytes32 assetKey) external pure returns (uint32) {
        return PolicyLib.assetBit(assetKey);
    }

    function cadenceBit(uint32 intervalSec) external pure returns (uint32) {
        return PolicyLib.cadenceBit(intervalSec);
    }

    function rollDay(LucidTypes.DeskState calldata s, uint256 nowTs)
        external
        pure
        returns (LucidTypes.DeskState memory)
    {
        return PolicyLib.rollDay(s, nowTs);
    }
}

contract PolicyLibTest is Test {
    PolicyHarness internal harness;

    /// A fixed point in time keeps every fixture readable; nothing here depends on the wall clock.
    uint64 internal constant NOW = 1_800_000_000;
    uint32 internal constant BIT_BTC = 1;
    uint32 internal constant BIT_ETH = 2;
    uint32 internal constant ALL_CADENCES = 15;

    function setUp() public {
        harness = new PolicyHarness();
    }

    // -- fixtures --------------------------------------------------------------

    /// A deliberately permissive policy: every test below breaks exactly one dial of it,
    /// so a failure names the gate that fired rather than a soup of interacting limits.
    function _policy() internal pure returns (LucidTypes.Policy memory p) {
        p = LucidTypes.Policy({
            maxStakePerWindow: 100e6,
            dailyBudget: 1000e6,
            maxOpenMarkets: 5,
            maxDrawdownBps: 2000,
            maxConsecutiveLosses: 3,
            minEdgeBps: 300,
            allowedAssets: BIT_BTC | BIT_ETH,
            allowedCadences: ALL_CADENCES,
            strategy: uint8(LucidTypes.Strategy.AiEdge),
            armed: true
        });
    }

    function _state() internal pure returns (LucidTypes.DeskState memory s) {
        s = LucidTypes.DeskState({
            dayKey: NOW / 1 days,
            spentToday: 0,
            highWaterMark: 1000e6,
            openMarkets: 0,
            consecutiveLosses: 0
        });
    }

    function _market() internal pure returns (LucidTypes.MarketInfo memory m) {
        m = LucidTypes.MarketInfo({
            marketId: keccak256("market"),
            market: address(0xBEEF),
            pool: address(0xCAFE),
            operatorId: 4,
            venueId: keccak256("venue"),
            yesId: 1,
            noId: 2,
            tradingStart: NOW,
            expiry: NOW + 300,
            nonce: 7,
            strike: 100_000e6,
            assetKey: LucidTypes.ASSET_BTC,
            intervalSec: 60
        });
    }

    function _verdict() internal pure returns (LucidTypes.Verdict memory v) {
        v = LucidTypes.Verdict({probUpBps: 6000, responded: 3, agreed: 3, ok: true, requestId: 1});
    }

    function _gate(
        LucidTypes.Policy memory p,
        LucidTypes.DeskState memory s,
        LucidTypes.MarketInfo memory m,
        LucidTypes.Verdict memory v,
        uint256 pBookBps,
        uint256 stake,
        uint256 equity
    ) internal view returns (LucidTypes.Refusal) {
        return harness.gate(p, s, m, v, pBookBps, stake, equity, NOW);
    }

    function _expect(LucidTypes.Refusal actual, LucidTypes.Refusal expected) internal pure {
        assertEq(uint256(actual), uint256(expected));
    }

    // -- the clean path --------------------------------------------------------

    function test_gate_passes_on_clean_path() public view {
        _expect(_gate(_policy(), _state(), _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.None);
    }

    function test_preCheck_passes_on_clean_path() public view {
        _expect(harness.preCheck(_policy(), _state(), _market(), NOW), LucidTypes.Refusal.None);
    }

    // -- one test per refusal reason -------------------------------------------

    function test_gate_refuses_when_disarmed() public view {
        LucidTypes.Policy memory p = _policy();
        p.armed = false;
        _expect(_gate(p, _state(), _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.NotArmed);
    }

    function test_gate_refuses_an_unlisted_asset() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedAssets = BIT_ETH;
        _expect(_gate(p, _state(), _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.AssetNotAllowed);
    }

    function test_gate_refuses_an_unknown_asset_even_when_all_bits_are_set() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedAssets = type(uint32).max;
        LucidTypes.MarketInfo memory m = _market();
        m.assetKey = keccak256("SOL");
        _expect(_gate(p, _state(), m, _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.AssetNotAllowed);
    }

    function test_gate_refuses_an_unlisted_cadence() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedCadences = 2; // 300s only
        _expect(_gate(p, _state(), _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.CadenceNotAllowed);
    }

    function test_gate_refuses_an_unknown_cadence_even_when_all_bits_are_set() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedCadences = type(uint32).max;
        LucidTypes.MarketInfo memory m = _market();
        m.intervalSec = 137;
        _expect(_gate(p, _state(), m, _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.CadenceNotAllowed);
    }

    function test_gate_refuses_a_window_that_closes_too_soon() public view {
        LucidTypes.MarketInfo memory m = _market();
        m.expiry = NOW + 89;
        _expect(_gate(_policy(), _state(), m, _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.WindowTooShort);
    }

    /// The slack is a floor, not a strict inequality: exactly 90 seconds of runway still trades.
    function test_gate_accepts_a_window_with_exactly_the_minimum_slack() public view {
        LucidTypes.MarketInfo memory m = _market();
        m.expiry = NOW + 90;
        _expect(_gate(_policy(), _state(), m, _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.None);
    }

    function test_gate_refuses_when_every_open_slot_is_used() public view {
        LucidTypes.DeskState memory s = _state();
        s.openMarkets = 5;
        _expect(_gate(_policy(), s, _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.MaxOpenReached);
    }

    function test_gate_refuses_on_a_losing_streak() public view {
        LucidTypes.DeskState memory s = _state();
        s.consecutiveLosses = 3;
        _expect(_gate(_policy(), s, _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.RiskHalt);
    }

    function test_gate_refuses_below_the_drawdown_floor() public view {
        // hwm 1000, 20% tolerance -> the floor is 800. One unit under it must halt.
        _expect(_gate(_policy(), _state(), _market(), _verdict(), 5000, 10e6, 800e6 - 1), LucidTypes.Refusal.RiskHalt);
    }

    function test_gate_accepts_equity_exactly_on_the_drawdown_floor() public view {
        _expect(_gate(_policy(), _state(), _market(), _verdict(), 5000, 10e6, 800e6), LucidTypes.Refusal.None);
    }

    function test_gate_refuses_when_the_committee_did_not_answer() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.ok = false;
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.AiUnavailable);
    }

    function test_gate_refuses_an_out_of_range_probability() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = 10_001;
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.AiMalformed);
    }

    function test_gate_refuses_when_the_edge_is_thin() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = 5299; // 299 bps of edge against a 5000 book, policy demands 300
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.LowEdge);
    }

    function test_gate_accepts_an_edge_exactly_at_the_threshold() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = 5300;
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.None);
    }

    /// The hero case: a maximally confident committee still cannot spend past the owner cap.
    function test_gate_refuses_over_the_window_cap() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = 9900;
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 100e6 + 1, 1000e6), LucidTypes.Refusal.CapExceeded);
    }

    function test_gate_refuses_over_the_daily_budget() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 950e6;
        _expect(_gate(_policy(), s, _market(), _verdict(), 5000, 51e6, 1000e6), LucidTypes.Refusal.DailyBudgetExceeded);
    }

    function test_gate_accepts_a_stake_that_exactly_exhausts_the_budget() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 950e6;
        _expect(_gate(_policy(), s, _market(), _verdict(), 5000, 50e6, 1000e6), LucidTypes.Refusal.None);
    }

    // -- ordering: the first failing check wins --------------------------------

    function test_gate_reports_notArmed_before_anything_else() public view {
        LucidTypes.Policy memory p = _policy();
        p.armed = false;
        p.allowedAssets = 0;
        p.allowedCadences = 0;
        LucidTypes.DeskState memory s = _state();
        s.openMarkets = 99;
        s.consecutiveLosses = 99;
        LucidTypes.Verdict memory v = _verdict();
        v.ok = false;
        _expect(_gate(p, s, _market(), v, 5000, type(uint64).max, 0), LucidTypes.Refusal.NotArmed);
    }

    function test_gate_reports_asset_before_cadence() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedAssets = 0;
        p.allowedCadences = 0;
        _expect(_gate(p, _state(), _market(), _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.AssetNotAllowed);
    }

    function test_gate_reports_window_before_open_slots() public view {
        LucidTypes.DeskState memory s = _state();
        s.openMarkets = 99;
        LucidTypes.MarketInfo memory m = _market();
        m.expiry = NOW;
        _expect(_gate(_policy(), s, m, _verdict(), 5000, 10e6, 1000e6), LucidTypes.Refusal.WindowTooShort);
    }

    /// Risk state is cheaper and more important than the AI answer, so it must be read first.
    function test_gate_reports_risk_before_the_ai_result() public view {
        LucidTypes.DeskState memory s = _state();
        s.consecutiveLosses = 9;
        LucidTypes.Verdict memory v = _verdict();
        v.ok = false;
        _expect(_gate(_policy(), s, _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.RiskHalt);
    }

    function test_gate_reports_unavailable_before_malformed() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.ok = false;
        v.probUpBps = 60_000;
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.AiUnavailable);
    }

    function test_gate_reports_malformed_before_lowEdge() public view {
        LucidTypes.Policy memory p = _policy();
        p.minEdgeBps = 9999;
        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = 10_001;
        _expect(_gate(p, _state(), _market(), v, 5000, 10e6, 1000e6), LucidTypes.Refusal.AiMalformed);
    }

    function test_gate_reports_lowEdge_before_the_cap() public view {
        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = 5000;
        _expect(_gate(_policy(), _state(), _market(), v, 5000, 999e6, 1000e6), LucidTypes.Refusal.LowEdge);
    }

    function test_gate_reports_the_cap_before_the_daily_budget() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 999e6;
        _expect(_gate(_policy(), s, _market(), _verdict(), 5000, 500e6, 1000e6), LucidTypes.Refusal.CapExceeded);
    }

    // -- edge symmetry ---------------------------------------------------------

    function test_edge_is_symmetric_for_down_side() public view {
        LucidTypes.Policy memory p = _policy();
        p.minEdgeBps = 3000;

        LucidTypes.Verdict memory up = _verdict();
        up.probUpBps = 8000;
        LucidTypes.Verdict memory down = _verdict();
        down.probUpBps = 2000;

        _expect(_gate(p, _state(), _market(), up, 5000, 10e6, 1000e6), LucidTypes.Refusal.None);
        _expect(_gate(p, _state(), _market(), down, 5000, 10e6, 1000e6), LucidTypes.Refusal.None);

        p.minEdgeBps = 3001;
        _expect(_gate(p, _state(), _market(), up, 5000, 10e6, 1000e6), LucidTypes.Refusal.LowEdge);
        _expect(_gate(p, _state(), _market(), down, 5000, 10e6, 1000e6), LucidTypes.Refusal.LowEdge);
    }

    function testFuzz_edge_is_symmetric_around_the_book(uint16 pBook, uint16 delta) public view {
        pBook = uint16(bound(pBook, 1000, 9000));
        delta = uint16(bound(delta, 0, 1000));

        LucidTypes.Policy memory p = _policy();
        p.minEdgeBps = delta + 1; // strictly more edge than either side offers

        LucidTypes.Verdict memory up = _verdict();
        up.probUpBps = pBook + delta;
        LucidTypes.Verdict memory down = _verdict();
        down.probUpBps = pBook - delta;

        _expect(_gate(p, _state(), _market(), up, pBook, 10e6, 1000e6), LucidTypes.Refusal.LowEdge);
        _expect(_gate(p, _state(), _market(), down, pBook, 10e6, 1000e6), LucidTypes.Refusal.LowEdge);
    }

    // -- preCheck --------------------------------------------------------------

    function test_preCheck_refuses_when_disarmed() public view {
        LucidTypes.Policy memory p = _policy();
        p.armed = false;
        _expect(harness.preCheck(p, _state(), _market(), NOW), LucidTypes.Refusal.NotArmed);
    }

    function test_preCheck_refuses_an_unlisted_asset() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedAssets = BIT_ETH;
        _expect(harness.preCheck(p, _state(), _market(), NOW), LucidTypes.Refusal.AssetNotAllowed);
    }

    function test_preCheck_refuses_an_unlisted_cadence() public view {
        LucidTypes.Policy memory p = _policy();
        p.allowedCadences = 8; // 3600s only
        _expect(harness.preCheck(p, _state(), _market(), NOW), LucidTypes.Refusal.CadenceNotAllowed);
    }

    function test_preCheck_refuses_a_window_that_closes_too_soon() public view {
        LucidTypes.MarketInfo memory m = _market();
        m.expiry = NOW + 89;
        _expect(harness.preCheck(_policy(), _state(), m, NOW), LucidTypes.Refusal.WindowTooShort);
    }

    function test_preCheck_refuses_when_every_open_slot_is_used() public view {
        LucidTypes.DeskState memory s = _state();
        s.openMarkets = 5;
        _expect(harness.preCheck(_policy(), s, _market(), NOW), LucidTypes.Refusal.MaxOpenReached);
    }

    function test_preCheck_refuses_on_a_losing_streak() public view {
        LucidTypes.DeskState memory s = _state();
        s.consecutiveLosses = 4;
        _expect(harness.preCheck(_policy(), s, _market(), NOW), LucidTypes.Refusal.RiskHalt);
    }

    /// A zero window cap can never fund a trade, so the desk must not pay for a verdict first.
    function test_preCheck_refuses_a_zero_window_cap() public view {
        LucidTypes.Policy memory p = _policy();
        p.maxStakePerWindow = 0;
        _expect(harness.preCheck(p, _state(), _market(), NOW), LucidTypes.Refusal.CapExceeded);
    }

    function test_preCheck_refuses_once_the_budget_is_spent() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 1000e6;
        _expect(harness.preCheck(_policy(), s, _market(), NOW), LucidTypes.Refusal.DailyBudgetExceeded);
    }

    /// The pre-filter exists to protect AI spend: whenever it clears, real room must remain.
    function test_preCheck_clearing_implies_a_nonzero_maxStake() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 999_999_999;
        _expect(harness.preCheck(_policy(), s, _market(), NOW), LucidTypes.Refusal.None);
        assertEq(harness.maxStake(_policy(), s), 1);
    }

    // -- maxStake --------------------------------------------------------------

    function test_maxStake_is_min_of_window_cap_and_remaining_budget() public view {
        LucidTypes.Policy memory p = _policy();
        LucidTypes.DeskState memory s = _state();

        // Budget is the binding constraint.
        s.spentToday = 960e6;
        assertEq(harness.maxStake(p, s), 40e6);

        // Window cap is the binding constraint.
        s.spentToday = 0;
        assertEq(harness.maxStake(p, s), 100e6);
    }

    function test_maxStake_is_zero_when_disarmed() public view {
        LucidTypes.Policy memory p = _policy();
        p.armed = false;
        assertEq(harness.maxStake(p, _state()), 0);
    }

    function test_maxStake_is_zero_when_halted() public view {
        LucidTypes.DeskState memory s = _state();
        s.consecutiveLosses = 3;
        assertEq(harness.maxStake(_policy(), s), 0);

        LucidTypes.DeskState memory full = _state();
        full.openMarkets = 5;
        assertEq(harness.maxStake(_policy(), full), 0);
    }

    function test_maxStake_is_zero_when_the_budget_is_spent() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 1000e6;
        assertEq(harness.maxStake(_policy(), s), 0);
    }

    /// An overspent desk is a real state after a mid-day policy cut; the subtraction must not wrap.
    function test_maxStake_does_not_underflow_when_overspent() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 5000e6;
        assertEq(harness.maxStake(_policy(), s), 0);
    }

    function test_maxStake_is_accepted_by_the_gate() public view {
        LucidTypes.Policy memory p = _policy();
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 970e6;
        uint64 max = harness.maxStake(p, s);
        assertEq(max, 30e6);
        _expect(_gate(p, s, _market(), _verdict(), 5000, max, 1000e6), LucidTypes.Refusal.None);
        _expect(
            _gate(p, s, _market(), _verdict(), 5000, uint256(max) + 1, 1000e6),
            LucidTypes.Refusal.DailyBudgetExceeded
        );
    }

    // -- rollDay ---------------------------------------------------------------

    function test_rollDay_resets_spentToday_on_new_utc_day() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 750e6;

        LucidTypes.DeskState memory rolled = harness.rollDay(s, NOW + 1 days);
        assertEq(rolled.spentToday, 0);
        assertEq(rolled.dayKey, (NOW + 1 days) / 1 days);
    }

    function test_rollDay_keeps_spend_inside_the_same_day() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 750e6;

        LucidTypes.DeskState memory rolled = harness.rollDay(s, NOW + 3600);
        assertEq(rolled.spentToday, 750e6);
        assertEq(rolled.dayKey, s.dayKey);
    }

    function test_rollDay_leaves_the_rest_of_the_state_untouched() public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = 750e6;
        s.openMarkets = 4;
        s.consecutiveLosses = 2;

        LucidTypes.DeskState memory rolled = harness.rollDay(s, NOW + 2 days);
        assertEq(rolled.highWaterMark, s.highWaterMark);
        assertEq(rolled.openMarkets, 4);
        assertEq(rolled.consecutiveLosses, 2);
    }

    function testFuzz_rollDay_is_idempotent(uint64 spentToday, uint32 nowTs) public view {
        LucidTypes.DeskState memory s = _state();
        s.spentToday = spentToday;

        LucidTypes.DeskState memory once = harness.rollDay(s, nowTs);
        LucidTypes.DeskState memory twice = harness.rollDay(once, nowTs);
        assertEq(twice.spentToday, once.spentToday);
        assertEq(twice.dayKey, once.dayKey);
    }

    // -- bit helpers -----------------------------------------------------------

    function test_assetBit_maps_only_the_two_listed_assets() public view {
        assertEq(harness.assetBit(LucidTypes.ASSET_BTC), 1);
        assertEq(harness.assetBit(LucidTypes.ASSET_ETH), 2);
        assertEq(harness.assetBit(keccak256("SOL")), 0);
        assertEq(harness.assetBit(bytes32(0)), 0);
    }

    function test_cadenceBit_maps_only_the_four_venue_cadences() public view {
        assertEq(harness.cadenceBit(60), 1);
        assertEq(harness.cadenceBit(300), 2);
        assertEq(harness.cadenceBit(900), 4);
        assertEq(harness.cadenceBit(3600), 8);
    }

    function test_cadenceBit_is_zero_for_anything_else() public view {
        assertEq(harness.cadenceBit(0), 0);
        assertEq(harness.cadenceBit(59), 0);
        assertEq(harness.cadenceBit(61), 0);
        assertEq(harness.cadenceBit(1800), 0);
        assertEq(harness.cadenceBit(type(uint32).max), 0);
    }

    // -- the gate must survive nonsense ----------------------------------------

    /// Router-driven code paths cannot afford a revert here: one would kill the whole fan-out.
    function testFuzz_gate_never_reverts(
        uint16 maxDrawdownBps,
        uint16 minEdgeBps,
        uint64 highWaterMark,
        uint64 spentToday,
        uint64 dailyBudget,
        uint16 probUpBps,
        uint256 pBookBps,
        uint256 stake,
        uint256 equity,
        uint256 nowTs
    ) public view {
        LucidTypes.Policy memory p = _policy();
        p.maxDrawdownBps = maxDrawdownBps;
        p.minEdgeBps = minEdgeBps;
        p.dailyBudget = dailyBudget;

        LucidTypes.DeskState memory s = _state();
        s.highWaterMark = highWaterMark;
        s.spentToday = spentToday;

        LucidTypes.Verdict memory v = _verdict();
        v.probUpBps = probUpBps;

        try harness.gate(p, s, _market(), v, pBookBps, stake, equity, nowTs) returns (LucidTypes.Refusal) {}
        catch {
            assertTrue(false, "gate reverted");
        }
    }

    function testFuzz_preCheck_never_reverts(uint64 dailyBudget, uint64 spentToday, uint64 expiry, uint256 nowTs)
        public
        view
    {
        LucidTypes.Policy memory p = _policy();
        p.dailyBudget = dailyBudget;

        LucidTypes.DeskState memory s = _state();
        s.spentToday = spentToday;

        LucidTypes.MarketInfo memory m = _market();
        m.expiry = expiry;

        try harness.preCheck(p, s, m, nowTs) returns (LucidTypes.Refusal) {}
        catch {
            assertTrue(false, "preCheck reverted");
        }
    }

    /// A drawdown tolerance of 100% or more means "never halt", not an underflowing floor.
    function test_gate_treats_a_total_drawdown_tolerance_as_no_halt() public view {
        LucidTypes.Policy memory p = _policy();
        p.maxDrawdownBps = type(uint16).max;
        _expect(_gate(p, _state(), _market(), _verdict(), 5000, 10e6, 0), LucidTypes.Refusal.None);
    }

    /// An absurd clock must refuse, not overflow while adding the window slack.
    function test_gate_refuses_a_far_future_clock_without_overflowing() public view {
        _expect(
            harness.gate(_policy(), _state(), _market(), _verdict(), 5000, 10e6, 1000e6, type(uint256).max),
            LucidTypes.Refusal.WindowTooShort
        );
    }
}
