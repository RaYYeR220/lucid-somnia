// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ISomniaEventHandler} from "@somnia/reactivity/interfaces/ISomniaEventHandler.sol";
import {ISomniaReactivityPrecompile} from "@somnia/reactivity/interfaces/ISomniaReactivityPrecompile.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LucidRouter} from "../src/LucidRouter.sol";
import {LucidWatch} from "../src/LucidWatch.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

import {MockPrecompile} from "./mocks/MockPrecompile.sol";
import {MockBrain} from "./mocks/MockBrain.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @title LucidWatchTest
/// @notice Exercises the contract that exists because the router could not re-arm itself.
///
/// The suite is organised around one fact rather than around one contract. Somnia reaps a
/// subscription whose owner falls below the 32 SOMI floor, and the owner is not told: it goes on
/// holding an id that now names nothing. Every assertion here is about what happens next.
///
/// Two tests carry the argument. `test_router_armVenue_is_bricked_by_a_reap` runs the live
/// router's own recovery path against a reaped subscription and watches it revert — that is the
/// production bug, reproduced, not described. `test_arm_recovers_after_the_chain_reaped_the_id`
/// runs the watch's path against the identical setup and watches it succeed. Nothing else in the
/// file is worth much without those two next to each other.
///
/// The fixture is the same verbatim Shannon log `LucidRouter.t.sol` and `MarketDecoder.t.sol`
/// pin, for the same reason: a watch that delivers hand-rolled bytes to a decoder proves that the
/// two agree with each other, which is not the claim.
contract LucidWatchTest is Test {
    address internal constant PRECOMPILE = address(0x0100);
    address internal constant MODULE = 0x3ecC694Cef705358864a646142ac17A90E29e388;

    bytes32 internal constant VENUE_ID = 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f;
    bytes32 internal constant BTC_MARKET_ID = bytes32(uint256(0x14898));
    address internal constant BTC_POOL = 0xcc2c4f74C8c3Dd5684EE2e18B1eb8fB1952fb308;
    uint64 internal constant TRADING_START = 1_788_647_100;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    LucidRouter internal router;
    LucidWatch internal watch;
    MockPrecompile internal precompile;
    MockBrain internal brain;

    function setUp() public {
        vm.warp(TRADING_START);
        vm.deal(address(this), 1_000 ether);

        vm.etch(PRECOMPILE, address(new MockPrecompile()).code);
        precompile = MockPrecompile(PRECOMPILE);

        vm.etch(BTC_POOL, address(new MockPool()).code);

        brain = new MockBrain();
        router = new LucidRouter(owner, address(brain));
        vm.deal(address(router), 33 ether);

        // The router is armed first, exactly as the live deployment was. Its own subscription is
        // id 1, and it is the thing the chain later takes away.
        vm.prank(owner);
        router.armVenue(MODULE, VENUE_ID);

        watch = new LucidWatch(owner, address(router));
        vm.deal(address(watch), 36 ether);
    }

    // ── the bug this contract exists for ──────────────────────────────────────

    /// @notice The deployed router cannot be re-armed once the chain has reaped its subscription.
    /// @dev This is not a hypothetical failure written up as a test. It is what happened to the
    /// live deployment: the router spent its float on committee calls and settlement wake-ups,
    /// dropped through the floor, had its venue subscription removed, and then refused every
    /// `armVenue` it was offered afterwards — including with 40 SOMI in hand. Money is not the
    /// cure, because the revert comes from cancelling an id the precompile no longer holds.
    function test_router_armVenue_is_bricked_by_a_reap() public {
        uint256 id = router.venueSubscriptionId();
        assertEq(id, 1, "the router owns its own subscription to begin with");

        precompile.reap(id);

        // Funded far above the floor: the failure has nothing to do with the balance.
        vm.deal(address(router), 100 ether);

        vm.prank(owner);
        vm.expectRevert(SomniaExtensionsErrors.UnsubscribeFailed.selector);
        router.armVenue(MODULE, VENUE_ID);

        assertEq(router.venueSubscriptionId(), id, "the router still holds an id that names nothing");
        assertFalse(precompile.isLive(id), "and the chain does not have it");
    }

    /// @notice The watch survives the same reap and re-arms.
    function test_arm_recovers_after_the_chain_reaped_the_id() public {
        vm.prank(owner);
        uint256 first = watch.arm(MODULE);

        precompile.reap(first);
        assertFalse(watch.armed(), "the chain has taken it, whatever storage says");
        assertEq(watch.subscriptionId(), first, "and the watch is still holding the id");

        vm.expectEmit(true, false, false, true, address(watch));
        emit LucidWatch.Disarmed(first, false);

        vm.prank(owner);
        uint256 second = watch.arm(MODULE);

        assertTrue(second != first, "a new subscription");
        assertEq(watch.subscriptionId(), second, "recorded");
        assertTrue(watch.armed(), "and live");
    }

    // ── arming ────────────────────────────────────────────────────────────────

    function test_arm_reverts_below_the_floor() public {
        LucidWatch poor = new LucidWatch(owner, address(router));
        vm.deal(address(poor), 31.999 ether);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LucidWatch.WatchUnderfunded.selector, uint256(31.999 ether), uint256(32 ether))
        );
        poor.arm(MODULE);
    }

    /// @dev The whole point of the contract in one assertion: the subscription is *owned* by the
    /// watch and *handled* by the router. Getting that pair backwards produces a subscription that
    /// bills the right contract and calls the wrong one, which fires silently forever.
    function test_arm_names_the_router_as_handler_and_the_watch_as_owner() public {
        vm.prank(owner);
        uint256 id = watch.arm(MODULE);

        ISomniaReactivityPrecompile.SubscriptionData memory s = precompile.subscriptionAt(id - 1);
        assertEq(s.handlerContractAddress, address(router), "the router handles it");
        assertEq(precompile.ownerAt(id - 1), address(watch), "the watch owns and pays for it");
        assertEq(s.handlerFunctionSelector, ISomniaEventHandler.onEvent.selector, "default handler selector");

        assertEq(s.eventTopics[0], LucidTypes.TOPIC_MARKET_CREATED, "topic0");
        assertEq(s.eventTopics[1], bytes32(0), "topic1 is a wildcard");
        assertEq(s.eventTopics[2], bytes32(0), "topic2 is a wildcard");
        assertEq(s.eventTopics[3], bytes32(0), "topic3 is a wildcard");
        assertEq(s.emitter, MODULE, "only the venue module's logs");
        assertEq(s.origin, address(0), "any origin");

        assertEq(watch.module(), MODULE, "module recorded");
        assertEq(watch.handler(), address(router), "handler is fixed at construction");
    }

    /// @dev The same floor the router's own subscriptions are held to. Below 5M Somnia charges for
    /// a handler it never executes, and the whole venue goes quiet with nothing in the logs.
    function test_arm_uses_the_routers_own_gas_ceiling() public {
        vm.prank(owner);
        uint256 id = watch.arm(MODULE);

        ISomniaReactivityPrecompile.SubscriptionData memory s = precompile.subscriptionAt(id - 1);
        assertGe(s.gasLimit, 5_000_000, "below 5M the handler silently never runs");
        assertEq(s.gasLimit, router.HANDLER_GAS_LIMIT(), "the router's own limit, not a second opinion");
        assertEq(s.priorityFeePerGas, router.HANDLER_PRIORITY_FEE(), "priority fee");
        assertEq(s.maxFeePerGas, router.HANDLER_MAX_FEE(), "max fee clears the 6 gwei protocol floor");
    }

    function test_arm_replaces_a_live_subscription() public {
        vm.prank(owner);
        uint256 first = watch.arm(MODULE);

        vm.prank(owner);
        uint256 second = watch.arm(MODULE);

        assertEq(precompile.unsubscribeCount(), 1, "the previous one is cancelled");
        assertEq(precompile.unsubscribedAt(0), first, "by id");
        assertFalse(precompile.isLive(first), "so it stops delivering");
        assertEq(watch.subscriptionId(), second, "and the new id is stored");
    }

    function test_arm_rejects_a_zero_module() public {
        vm.prank(owner);
        vm.expectRevert(LucidWatch.ZeroAddress.selector);
        watch.arm(address(0));
    }

    function test_arm_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        watch.arm(MODULE);
    }

    function test_constructor_rejects_a_zero_handler() public {
        vm.expectRevert(LucidWatch.ZeroAddress.selector);
        new LucidWatch(owner, address(0));
    }

    // ── disarming ─────────────────────────────────────────────────────────────

    function test_disarm_cancels_and_forgets() public {
        vm.prank(owner);
        uint256 id = watch.arm(MODULE);

        vm.expectEmit(true, false, false, true, address(watch));
        emit LucidWatch.Disarmed(id, true);

        vm.prank(owner);
        watch.disarm();

        assertEq(watch.subscriptionId(), 0, "no id held");
        assertEq(watch.module(), address(0), "and nothing watched");
        assertFalse(watch.armed(), "reported honestly");
    }

    /// @dev The recovery path's other half: disarming after a reap must not revert either, or an
    /// owner who wants to stand the watch down is as stuck as one who wants to raise it.
    function test_disarm_is_safe_after_a_reap() public {
        vm.prank(owner);
        uint256 id = watch.arm(MODULE);
        precompile.reap(id);

        vm.expectEmit(true, false, false, true, address(watch));
        emit LucidWatch.Disarmed(id, false);

        vm.prank(owner);
        watch.disarm();

        assertEq(watch.subscriptionId(), 0, "the dead id is dropped");
    }

    function test_disarm_on_a_fresh_watch_does_nothing() public {
        vm.prank(owner);
        watch.disarm();

        assertEq(precompile.unsubscribeCount(), 0, "nothing was cancelled");
        assertEq(watch.subscriptionId(), 0, "and nothing is held");
    }

    function test_disarm_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        watch.disarm();
    }

    // ── armed() tells the truth about the chain, not about storage ────────────

    function test_armed_is_false_before_arming() public view {
        assertFalse(watch.armed());
    }

    function test_armed_is_false_when_the_precompile_disowns_the_id() public {
        vm.prank(owner);
        uint256 id = watch.arm(MODULE);
        assertTrue(watch.armed(), "live to begin with");

        precompile.reap(id);

        assertEq(watch.subscriptionId(), id, "storage is unchanged, because nobody told the watch");
        assertFalse(watch.armed(), "and the only address that knows is asked");
    }

    // ── float ─────────────────────────────────────────────────────────────────

    function test_sweep_moves_float_to_the_owner() public {
        uint256 before = stranger.balance;

        vm.prank(owner);
        watch.sweep(stranger, 4 ether);

        assertEq(stranger.balance - before, 4 ether, "sent");
        assertEq(address(watch).balance, 32 ether, "and the bond is what is left");
    }

    function test_sweep_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        watch.sweep(stranger, 1 ether);
    }

    function test_sweep_rejects_the_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(LucidWatch.ZeroAddress.selector);
        watch.sweep(address(0), 1 ether);
    }

    function test_watch_takes_a_plain_transfer() public {
        (bool ok,) = address(watch).call{value: 1 ether}("");
        assertTrue(ok, "the precompile bills this balance directly");
        assertEq(address(watch).balance, 37 ether);
    }

    // ── delivery ──────────────────────────────────────────────────────────────

    /// @notice A log delivered on the watch's subscription reaches the router and is acted on.
    /// @dev The router is not modified for any of this, and that is the assertion. Somnia's handler
    /// base admits any call from `0x0100` without asking who owns the subscription behind it, so a
    /// contract can be paid for by one address and executed on behalf of another.
    function test_a_log_on_the_watchs_subscription_is_handled_by_the_router() public {
        vm.prank(owner);
        watch.arm(MODULE);

        assertEq(router.marketOf(BTC_MARKET_ID).marketId, bytes32(0), "nothing known yet");

        vm.prank(PRECOMPILE);
        router.onEvent(MODULE, _btcTopics(), _btcData());

        LucidTypes.MarketInfo memory m = router.marketOf(BTC_MARKET_ID);
        assertEq(m.marketId, BTC_MARKET_ID, "the router recorded the window");
        assertEq(m.venueId, VENUE_ID, "on the venue it serves");
        assertEq(m.pool, BTC_POOL, "with the pool from the log");
    }

    /// @dev A watch pointed at the wrong module cannot make the router believe anything: the
    /// router re-checks the emitter against its own `venueModule` before it decodes a byte.
    function test_a_log_from_another_module_is_ignored_by_the_router() public {
        vm.prank(owner);
        watch.arm(makeAddr("someoneElsesModule"));

        vm.prank(PRECOMPILE);
        router.onEvent(makeAddr("someoneElsesModule"), _btcTopics(), _btcData());

        assertEq(router.marketOf(BTC_MARKET_ID).marketId, bytes32(0), "nothing was taken on trust");
    }

    // ── fixture ───────────────────────────────────────────────────────────────
    //
    // Verbatim from Shannon testnet, block 480739596, tx
    // 0x5d1cf9cea46cdaaf4231c5c41235d616f0dfe91ffc67dd19fc6ca8404c8c7822, logIndex 91.

    function _btcTopics() internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](4);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;
        topics[1] = 0x0000000000000000000000000000000000000000000000000000000000014898;
        topics[2] = 0x000000000000000000000000c7b7f71513eaf972b9ff6c0ddb6144e322ba63b0;
        topics[3] = 0x000000000000000000000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb308;
    }

    function _btcData() internal pure returns (bytes memory) {
        return hex"95cc7af87c01e66a3bfa3feb6f3f39812bc4923d655d1524bcf534abf6d84b04"
            hex"0000000000000000000000000000000000000000000000000000000000000004"
            hex"1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f"
            hex"000000000000000000000000ee3aff92812a2cb7bf801b500687bc97b55cab34"
            hex"00000000000000000000000070a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e"
            hex"000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb30800000000000000a700"
            hex"000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb30800000000000000a701"
            hex"00000000000000000000000000000000000000000000000000000000000000a7"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000006a9c96bc"
            hex"000000000000000000000000000000000000000000000000000000006a9c96f8"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000220"
            hex"000000000000000000000000000000000000000000000000000000000079df1f"
            hex"0000000000000000000000000000000000000000000000000000000000000260"
            hex"00000000000000000000000000000000000000000000000000000000000002e0"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"4254430000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000056"
            hex"50726963656665656420746573743a2077696c6c204254432f55534443277320"
            hex"7072696365206265206174206f722061626f76652037393836392e3735206174"
            hex"20756e69782074696d6520313738383634373136303f00000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000";
    }
}

/// @notice The errors `SomniaExtensions` declares, restated so a test can name one.
/// @dev A library's custom errors are not reachable through the library type in Solidity, and the
/// selector matters here: `UnsubscribeFailed` is the exact revert that bricked the live router,
/// and asserting on a hand-copied `bytes4` would pass just as happily if the library renamed it.
interface SomniaExtensionsErrors {
    error UnsubscribeFailed();
}
