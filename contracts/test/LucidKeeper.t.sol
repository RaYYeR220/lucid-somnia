// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LucidKeeper} from "../src/LucidKeeper.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

import {MockKeeperModule} from "./mocks/MockKeeperModule.sol";
import {MockKeeperMarket} from "./mocks/MockKeeperMarket.sol";

/// @title LucidKeeperTest
/// @notice Exercises the venue-wide upkeep runner.
///
/// Three properties are worth more than the rest of this file put together, because each of them
/// has already broken something in this codebase:
///
///   1. `keep` never reverts past its access check. It is called from inside a reactivity handler,
///      where a revert discards the whole settlement fan-out rather than one market's upkeep.
///   2. A target with no code is refused before the call, not caught after it. `try`/`catch` does
///      not catch a return-data decode failure, so an unguarded read on an empty address escapes.
///   3. A counter only moves when the call actually returned. A call into an empty address reports
///      success without executing anything, which is the easiest way to fabricate a claim.
///
/// `LucidTypes.MODULE` is a compile-time constant, so the module mock is etched over it rather than
/// injected: the keeper deliberately cannot be pointed at a different venue module.
contract LucidKeeperTest is Test {
    bytes32 internal constant MARKET_ID = bytes32(uint256(0x14898));
    uint64 internal constant EXPIRY = 1_788_647_160;
    uint64 internal constant SETTLEMENT_WINDOW = 3_600;
    uint256 internal constant QUESTION_ID = 0x95cc7af8;

    address internal owner = makeAddr("owner");
    address internal router = makeAddr("router");
    address internal stranger = makeAddr("stranger");
    address internal pool = makeAddr("pool");

    LucidKeeper internal keeper;
    MockKeeperModule internal module;
    MockKeeperMarket internal market;

    function setUp() public {
        // Just after expiry and well inside the settlement window: the ordinary state of a window
        // the router has only now woken up for, in which voiding would be premature.
        vm.warp(EXPIRY + 10);

        vm.etch(LucidTypes.MODULE, address(new MockKeeperModule()).code);
        module = MockKeeperModule(LucidTypes.MODULE);
        module.setQuestion(MARKET_ID, QUESTION_ID);

        market = new MockKeeperMarket(EXPIRY, SETTLEMENT_WINDOW);
        keeper = new LucidKeeper(owner, router);
    }

    // ── access control ────────────────────────────────────────────────────────

    function test_only_router_can_keep() public {
        vm.prank(stranger);
        vm.expectRevert(LucidKeeper.NotRouter.selector);
        keeper.keep(_info());

        assertEq(module.finalizeCalls(), 0, "no upkeep from an outsider");
    }

    function test_only_owner_can_set_router() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        keeper.setRouter(stranger);

        assertEq(keeper.router(), router, "unchanged");
    }

    function test_setRouter_moves_the_permission() public {
        address newRouter = makeAddr("newRouter");

        vm.expectEmit(false, false, false, true, address(keeper));
        emit LucidKeeper.RouterSet(newRouter);
        vm.prank(owner);
        keeper.setRouter(newRouter);

        vm.prank(router);
        vm.expectRevert(LucidKeeper.NotRouter.selector);
        keeper.keep(_info());

        vm.prank(newRouter);
        keeper.keep(_info());
        assertEq(module.finalizeCalls(), 1, "the new router drives it");
    }

    // ── the upkeep calls ──────────────────────────────────────────────────────

    function test_finalize_is_called_and_counted() public {
        vm.expectEmit(true, false, false, true, address(keeper));
        emit LucidKeeper.Kept(MARKET_ID, keeper.WHAT_FINALIZE());
        _keep();

        assertEq(module.finalizeCalls(), 1, "the venue was actually called");
        assertEq(module.lastFinalized(), MARKET_ID, "for this window");

        (uint64 finalized,,,,, uint64 failures) = keeper.counts();
        assertEq(finalized, 1, "counted");
        assertEq(failures, 0, "nothing failed");
    }

    function test_each_upkeep_call_is_counted_separately() public {
        // Past the settlement window and never resolved, so the void is legitimate too.
        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW + 1);

        _keep();

        assertEq(module.finalizeCalls(), 1, "finalizeMarket");
        assertEq(module.syncCalls(), 1, "syncSettlement");
        assertEq(module.releaseCalls(), 1, "releasePool");
        assertEq(module.pokeCalls(), 1, "pokeOracle");
        assertEq(module.lastPoked(), QUESTION_ID, "the market's own oracle question");
        assertEq(market.voidCalls(), 1, "voidExpired");

        (uint64 finalized, uint64 released, uint64 synced, uint64 poked, uint64 voided, uint64 failures) =
            keeper.counts();
        assertEq(finalized, 1, "finalized");
        assertEq(released, 1, "released");
        assertEq(synced, 1, "synced");
        assertEq(poked, 1, "poked");
        assertEq(voided, 1, "voided");
        assertEq(failures, 0, "and nothing counted twice");
    }

    /// @dev The oracle question id is not carried in `MarketInfo`; it is read back from the module.
    /// When that read comes up empty there is no question to poke, and poking a guessed id would be
    /// worse than not poking at all — so this is silence, not a failure.
    function test_poke_is_skipped_when_the_oracle_question_is_unknown() public {
        module.setRevertMarkets(true);

        _keep();

        assertEq(module.pokeCalls(), 0, "nothing to poke");

        (uint64 finalized,,, uint64 poked,, uint64 failures) = keeper.counts();
        assertEq(finalized, 1, "the rest of the upkeep still ran");
        assertEq(poked, 0, "not counted as done");
        assertEq(failures, 0, "and not counted as failed either");
    }

    // ── failure handling ──────────────────────────────────────────────────────

    /// @dev This is the normal case, not the exceptional one. By the time the router wakes up, the
    /// venue's own infrastructure has often finalized the market already, and `finalizeMarket`
    /// reverts. The keeper's job is to have tried.
    function test_a_reverting_call_is_counted_as_a_failure_not_propagated() public {
        module.setReverts(true, false, false, false);

        vm.expectEmit(true, false, false, true, address(keeper));
        emit LucidKeeper.KeepFailed(
            MARKET_ID, keeper.WHAT_FINALIZE(), abi.encodeWithSelector(MockKeeperModule.AlreadyFinalized.selector)
        );
        _keep();

        (uint64 finalized,,,,, uint64 failures) = keeper.counts();
        assertEq(finalized, 0, "a revert is never reported as work done");
        assertEq(failures, 1, "counted once");
    }

    function test_one_failure_does_not_stop_the_rest() public {
        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW + 1);
        module.setReverts(true, false, false, false);

        _keep();

        assertEq(module.syncCalls(), 1, "sync still ran");
        assertEq(module.releaseCalls(), 1, "release still ran");
        assertEq(module.pokeCalls(), 1, "poke still ran");
        assertEq(market.voidCalls(), 1, "void still ran");

        (uint64 finalized, uint64 released, uint64 synced, uint64 poked, uint64 voided, uint64 failures) =
            keeper.counts();
        assertEq(finalized, 0, "only the broken call is missing");
        assertEq(released, 1, "released");
        assertEq(synced, 1, "synced");
        assertEq(poked, 1, "poked");
        assertEq(voided, 1, "voided");
        assertEq(failures, 1, "one failure");
    }

    /// @dev The load-bearing test. `keep` runs inside a reactivity handler, where a revert does not
    /// fail one market's upkeep — it discards the settlement fan-out for every desk woken in the
    /// same firing, and the router is charged for the gas anyway.
    function test_never_reverts_even_when_everything_fails() public {
        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW + 1);
        module.setReverts(true, true, true, true);
        market.setReverts(false, false, false, true);

        _keep();

        (uint64 finalized, uint64 released, uint64 synced, uint64 poked, uint64 voided, uint64 failures) =
            keeper.counts();
        assertEq(finalized, 0, "nothing succeeded");
        assertEq(released, 0, "nothing succeeded");
        assertEq(synced, 0, "nothing succeeded");
        assertEq(poked, 0, "nothing succeeded");
        assertEq(voided, 0, "nothing succeeded");
        assertEq(failures, 5, "and every one of them is on the record");
    }

    /// @dev Solidity checks the callee's `extcodesize` — or, since 0.8.10, lets the return-data
    /// decoder fail — *outside* the `catch` block, so a read on an address with no code escapes the
    /// wrapper and takes the handler down with it. The guard is `code.length`, before the call.
    ///
    /// The same guard is what keeps the counters honest: a call into an empty address returns
    /// success having executed nothing, so an unguarded `finalizeMarket` here would report upkeep
    /// that never happened.
    function test_codeless_target_does_not_blow_past_the_catch() public {
        vm.etch(LucidTypes.MODULE, "");

        LucidTypes.MarketInfo memory m = _info();
        m.market = makeAddr("notAContract");

        vm.prank(router);
        keeper.keep(m);

        (uint64 finalized, uint64 released, uint64 synced, uint64 poked, uint64 voided, uint64 failures) =
            keeper.counts();
        assertEq(finalized, 0, "an empty address executes nothing");
        assertEq(released, 0, "an empty address executes nothing");
        assertEq(synced, 0, "an empty address executes nothing");
        assertEq(poked, 0, "an empty address executes nothing");
        assertEq(voided, 0, "an empty address executes nothing");
        assertEq(failures, 2, "one for the module, one for the market");
    }

    // ── voidExpired preconditions ─────────────────────────────────────────────

    function test_voidExpired_only_after_the_settlement_window() public {
        // Exactly at the boundary the window has not yet run out.
        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW);
        _keep();

        assertEq(market.voidCalls(), 0, "not voidable yet");
        (,,,, uint64 voidedBefore, uint64 failuresBefore) = keeper.counts();
        assertEq(voidedBefore, 0, "not counted");
        assertEq(failuresBefore, 0, "and waiting is not a failure");

        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW + 1);
        _keep();

        assertEq(market.voidCalls(), 1, "voidable one second later");
        (,,,, uint64 voidedAfter,) = keeper.counts();
        assertEq(voidedAfter, 1, "counted");
    }

    /// @dev A resolved market has an answer. Voiding it would throw that answer away, so the
    /// keeper checks before it acts rather than letting the venue reject it.
    function test_voidExpired_skipped_when_already_resolved() public {
        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW + 1);
        market.setResolved(true);

        _keep();

        assertEq(market.voidCalls(), 0, "a resolved window is left alone");
        (,,,, uint64 voided, uint64 failures) = keeper.counts();
        assertEq(voided, 0, "not counted");
        assertEq(failures, 0, "and not a failure");
    }

    // ── the ecosystem-impact number ───────────────────────────────────────────

    /// @dev These counters are the protocol's public claim about how much venue upkeep it actually
    /// performed, so nothing may ever walk them back.
    function test_counters_are_monotonic() public {
        vm.warp(uint256(EXPIRY) + SETTLEMENT_WINDOW + 1);
        _keep();

        (uint64 f0, uint64 r0, uint64 s0, uint64 p0, uint64 v0, uint64 x0) = keeper.counts();

        // A second firing in which every call reverts: the failures rise, and not one success does.
        module.setReverts(true, true, true, true);
        market.setReverts(false, false, false, true);
        _keep();

        (uint64 f1, uint64 r1, uint64 s1, uint64 p1, uint64 v1, uint64 x1) = keeper.counts();
        assertEq(f1, f0, "finalized never falls");
        assertEq(r1, r0, "released never falls");
        assertEq(s1, s0, "synced never falls");
        assertEq(p1, p0, "poked never falls");
        assertEq(v1, v0, "voided never falls");
        assertEq(x1, x0 + 5, "failures rise instead");

        // And a third, healthy one: the successes resume from where they stopped.
        module.setReverts(false, false, false, false);
        market.setReverts(false, false, false, false);
        _keep();

        (uint64 f2, uint64 r2, uint64 s2, uint64 p2, uint64 v2, uint64 x2) = keeper.counts();
        assertEq(f2, f1 + 1, "finalized resumes");
        assertEq(r2, r1 + 1, "released resumes");
        assertEq(s2, s1 + 1, "synced resumes");
        assertEq(p2, p1 + 1, "poked resumes");
        assertEq(v2, v1 + 1, "voided resumes");
        assertEq(x2, x1, "and nothing new failed");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _keep() internal {
        vm.prank(router);
        keeper.keep(_info());
    }

    /// @dev Shaped like the router's own decoded log: the keeper is handed a window, not an id.
    function _info() internal view returns (LucidTypes.MarketInfo memory) {
        return LucidTypes.MarketInfo({
            marketId: MARKET_ID,
            market: address(market),
            pool: pool,
            operatorId: 4,
            venueId: 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f,
            yesId: 1,
            noId: 2,
            tradingStart: EXPIRY - 60,
            expiry: EXPIRY,
            nonce: 167,
            strike: 79_869_750_000,
            assetKey: LucidTypes.ASSET_BTC,
            intervalSec: 60
        });
    }
}
