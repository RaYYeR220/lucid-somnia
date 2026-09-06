// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SomniaEventHandler} from "@somnia/reactivity/SomniaEventHandler.sol";
import {SomniaExtensions} from "@somnia/reactivity/interfaces/SomniaExtensions.sol";
import {ISomniaEventHandler} from "@somnia/reactivity/interfaces/ISomniaEventHandler.sol";
import {ISomniaReactivityPrecompile} from "@somnia/reactivity/interfaces/ISomniaReactivityPrecompile.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LucidRouter} from "../src/LucidRouter.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

import {MockPrecompile} from "./mocks/MockPrecompile.sol";
import {MockDeskForRouter} from "./mocks/MockDeskForRouter.sol";
import {MockBrain} from "./mocks/MockBrain.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @notice The slice of `LucidFactory` the router reads: the copy-trade graph and nothing else.
/// @dev Kept here rather than in `test/mocks/` because it exists to pin the router's read-only view
/// of a contract it deliberately does not depend on.
contract MockFactoryView {
    error FactoryIsDown();

    mapping(address leader => address[]) internal _followers;
    mapping(address leader => mapping(address follower => uint16)) internal _scale;
    bool public revertOnRead;

    function link(address leader, address follower, uint16 scaleBps) external {
        _followers[leader].push(follower);
        _scale[leader][follower] = scaleBps;
    }

    function setRevertOnRead(bool on) external {
        revertOnRead = on;
    }

    function followersOf(address leader) external view returns (address[] memory) {
        if (revertOnRead) revert FactoryIsDown();
        return _followers[leader];
    }

    function scaleOf(address leader, address follower) external view returns (uint16) {
        return _scale[leader][follower];
    }
}

/// @notice The slice of `LucidKeeper` the router drives: one call, and nothing else.
/// @dev Kept here for the same reason as `MockFactoryView`: it pins the router's view of a contract
/// it deliberately does not depend on. The keeper runs upkeep for the whole venue, so the router
/// must be able to call it without being able to break when it misbehaves.
contract MockKeeperForRouter {
    error KeeperIsDown();

    uint256 public keepCalls;
    bytes32 public lastMarketId;
    address public lastMarket;
    bool public revertOnKeep;

    function setRevertOnKeep(bool on) external {
        revertOnKeep = on;
    }

    function keep(LucidTypes.MarketInfo calldata m) external {
        if (revertOnKeep) revert KeeperIsDown();
        ++keepCalls;
        lastMarketId = m.marketId;
        lastMarket = m.market;
    }
}

/// @notice The slice of `LucidRelay` the router drives: one call, and nothing else.
/// @dev Kept here for the same reason as `MockKeeperForRouter`. The relay is an ownerless public
/// good that redeems exits their owners signed in advance; the router only nudges it, so it must
/// be able to do that without being able to break when the relay misbehaves.
contract MockRelayForRouter {
    error RelayIsDown();

    uint256 public relayCalls;
    bytes32 public lastMarketId;
    uint256 public lastMax;
    bool public revertOnRelay;

    /// @dev Sampled at call time. A redemption reverts until the market is finalized, and
    /// finalizing it is the keeper's first call — so "the relay ran after the keeper" is a real
    /// property, not a detail, and this is what lets a test pin it.
    MockKeeperForRouter public witness;
    uint256 public keepsWhenRelayed;

    function setRevertOnRelay(bool on) external {
        revertOnRelay = on;
    }

    function watch(MockKeeperForRouter keeper) external {
        witness = keeper;
    }

    function relayUpTo(bytes32 marketId, uint256 max) external {
        if (revertOnRelay) revert RelayIsDown();
        ++relayCalls;
        lastMarketId = marketId;
        lastMax = max;
        if (address(witness) != address(0)) keepsWhenRelayed = witness.keepCalls();
    }
}

/// @notice A brain that refuses the way the real one refuses: quietly, and without reverting.
/// @dev Kept here rather than in `test/mocks/` because it exists for exactly one property, and it
/// is a property of `LucidBrain`'s contract rather than of any mock. `requestVerdict` returns zero
/// — window too tight, no feed for the asset, no float for the second stage — instead of reverting,
/// deliberately, so the desk is told why it stood down rather than left waiting on silence. The
/// router's `try` therefore *succeeds* on the one path where nothing was bought, which is exactly
/// how a caller ends up charging for work that never happened.
contract MockRefusingBrain {
    uint256 public fee = 0.213 ether;
    uint256 public requestCount;
    uint256 public totalReceived;

    function quote() external view returns (uint256) {
        return fee;
    }

    function requestVerdict(bytes32, LucidTypes.MarketInfo calldata, uint256, uint16[] calldata)
        external
        payable
        returns (uint256)
    {
        ++requestCount;
        totalReceived += msg.value;
        return 0;
    }

    receive() external payable {}
}

/// @notice A desk that reports the gas budget it was actually handed.
/// @dev Kept here rather than in `test/mocks/` because it exists for exactly one property: a
/// stipend is a promise about a number, and the only place that number is observable is inside the
/// callee's own frame. Everything else — did it revert, did it emit — is downstream of it.
contract MockGasWitnessDesk {
    uint256 public lastVerdictGas;
    uint256 public lastSettlementGas;

    function preCheck(LucidTypes.MarketInfo calldata) external pure returns (bool) {
        return true;
    }

    function onVerdict(LucidTypes.MarketInfo calldata, LucidTypes.Verdict calldata, uint256) external {
        lastVerdictGas = gasleft();
    }

    function onSettlement(LucidTypes.MarketInfo calldata) external {
        lastSettlementGas = gasleft();
    }

    function onLeaderTrade(LucidTypes.MarketInfo calldata, uint8, uint256) external {}
}

/// @title LucidRouterTest
/// @notice Exercises the one contract that talks to Somnia's reactivity precompile.
///
/// Two things make this suite worth reading. First, the `MarketCreated` fixtures are verbatim logs
/// captured from Shannon testnet (chain 50312) — the same ones `MarketDecoder.t.sol` pins — so the
/// router is driven with the exact bytes the precompile will hand it in production, not with a
/// hand-rolled encoding that could agree with a wrong decoder. Second, `MockPrecompile` is etched
/// at `0x0100`, so every assertion about a subscription is an assertion about the literal
/// `SubscriptionData` that would be committed on-chain — including the 5M gas-limit floor, below
/// which Somnia silently charges for a handler that never runs.
///
/// Fixture provenance:
///   block    480739596
///   tx       0x5d1cf9cea46cdaaf4231c5c41235d616f0dfe91ffc67dd19fc6ca8404c8c7822
///   logIndex 91  (BTC, marketId 0x14898) · 113 (ETH, marketId 0x14899) — one tx, one 60s window.
contract LucidRouterTest is Test {
    // ── chain constants ───────────────────────────────────────────────────────
    address internal constant PRECOMPILE = address(0x0100);
    address internal constant MODULE = 0x3ecC694Cef705358864a646142ac17A90E29e388;

    // ── fixture identities ────────────────────────────────────────────────────
    bytes32 internal constant VENUE_ID = 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f;
    bytes32 internal constant BTC_MARKET_ID = bytes32(uint256(0x14898));
    address internal constant BTC_MARKET_ADDR = 0xc7B7f71513EAF972B9Ff6C0DDb6144E322bA63B0;
    address internal constant BTC_POOL = 0xcc2c4f74C8c3Dd5684EE2e18B1eb8fB1952fb308;
    bytes32 internal constant ETH_MARKET_ID = bytes32(uint256(0x14899));
    address internal constant ETH_POOL = 0x56154C18cf0e7E601919b13c7478747398AA5057;
    uint64 internal constant TRADING_START = 1_788_647_100;
    uint64 internal constant EXPIRY = 1_788_647_160;

    /// @dev The router schedules settlement five seconds after expiry, in milliseconds.
    uint256 internal constant DUE_MS = (uint256(EXPIRY) + 5) * 1000;

    address internal owner = makeAddr("owner");
    address internal deskOwner = makeAddr("deskOwner");
    address internal stranger = makeAddr("stranger");

    LucidRouter internal router;
    MockPrecompile internal precompile;
    MockBrain internal brain;
    MockFactoryView internal factory;

    function setUp() public {
        vm.warp(TRADING_START);
        vm.deal(address(this), 1_000 ether);

        vm.etch(PRECOMPILE, address(new MockPrecompile()).code);
        precompile = MockPrecompile(PRECOMPILE);

        // The pools the fixture logs point at must answer `getBookLevels`, because the router
        // resolves the book from the log rather than from anything the test hands it.
        bytes memory poolCode = address(new MockPool()).code;
        vm.etch(BTC_POOL, poolCode);
        vm.etch(ETH_POOL, poolCode);

        brain = new MockBrain();
        router = new LucidRouter(owner, address(brain));

        // 33 SOMI: the 32 bond the precompile checks, plus float for verdicts and one-shots.
        vm.deal(address(router), 33 ether);

        vm.prank(owner);
        router.armVenue(MODULE, VENUE_ID);
    }

    // ── arming ────────────────────────────────────────────────────────────────

    function test_armVenue_reverts_when_underfunded() public {
        LucidRouter poor = new LucidRouter(owner, address(brain));
        vm.deal(address(poor), 31.999 ether);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LucidRouter.RouterUnderfunded.selector, uint256(31.999 ether), uint256(32 ether))
        );
        poor.armVenue(MODULE, VENUE_ID);
    }

    function test_armVenue_subscribes_with_the_market_created_topic() public view {
        assertEq(precompile.subscriptionCount(), 1, "one subscription");
        assertEq(router.venueSubscriptionId(), 1, "id recorded");
        assertEq(router.venue(), VENUE_ID, "venue recorded");
        assertEq(router.venueModule(), MODULE, "module recorded");

        ISomniaReactivityPrecompile.SubscriptionData memory s = precompile.subscriptionAt(0);
        assertEq(s.eventTopics[0], LucidTypes.TOPIC_MARKET_CREATED, "topic0");
        assertEq(s.eventTopics[1], bytes32(0), "topic1 is a wildcard");
        assertEq(s.eventTopics[2], bytes32(0), "topic2 is a wildcard");
        assertEq(s.eventTopics[3], bytes32(0), "topic3 is a wildcard");
        assertEq(s.emitter, MODULE, "only the venue module's logs");
        assertEq(s.origin, address(0), "any origin");
        assertEq(s.caller, address(0), "reserved");
        assertEq(s.handlerContractAddress, address(router), "the router handles its own subscriptions");
        assertEq(s.handlerFunctionSelector, ISomniaEventHandler.onEvent.selector, "default handler selector");
        assertEq(s.handlerFunctionSelector, bytes4(0x53edf33d), "selector observed live on Shannon");
        assertFalse(s.isGuaranteed, "not guaranteed");
        assertFalse(s.isCoalesced, "not coalesced");
        assertEq(precompile.ownerAt(0), address(router), "the router owns the subscription");
    }

    /// @dev The load-bearing assertion in this whole file. At 2M gas Somnia charged for the
    /// handler and never executed it, with no revert and no event: a silent no-op that looks
    /// exactly like a market nobody wanted.
    function test_armVenue_uses_gas_limit_of_at_least_5m() public view {
        ISomniaReactivityPrecompile.SubscriptionData memory s = precompile.subscriptionAt(0);
        assertGe(s.gasLimit, 5_000_000, "below 5M the handler silently never runs");
        assertEq(s.gasLimit, 100_000_000, "the value this protocol ships");
        assertEq(s.priorityFeePerGas, 1 gwei, "priority fee");
        assertEq(s.maxFeePerGas, 20 gwei, "max fee clears the 6 gwei protocol floor");
    }

    function test_armVenue_replaces_the_previous_subscription() public {
        vm.prank(owner);
        router.armVenue(MODULE, bytes32(uint256(0xbeef)));

        assertEq(precompile.unsubscribeCount(), 1, "the stale subscription is cancelled");
        assertEq(precompile.unsubscribedAt(0), 1, "by id");
        assertEq(router.venueSubscriptionId(), 2, "the new id is stored");
    }

    function test_armVenue_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.armVenue(MODULE, VENUE_ID);
    }

    // ── handler access control ────────────────────────────────────────────────

    function test_onEvent_rejects_a_non_precompile_caller() public {
        vm.prank(stranger);
        vm.expectRevert(SomniaEventHandler.OnlyReactivityPrecompile.selector);
        router.onEvent(MODULE, _btcTopics(), _btcData());
    }

    // ── MarketCreated branch ──────────────────────────────────────────────────

    function test_marketCreated_ignores_a_foreign_venue() public {
        _newDesk(true, 1 ether);

        // The same operator's module serves several venues; only ours is our business.
        vm.prank(owner);
        router.armVenue(MODULE, bytes32(uint256(0xdead)));

        _fireBtc();

        assertEq(router.marketOf(BTC_MARKET_ID).marketId, bytes32(0), "not stored");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "no fan-out");
        assertEq(brain.requestCount(), 0, "no AI spend");
    }

    function test_marketCreated_stores_the_market() public {
        _newDesk(true, 1 ether);

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.MarketSeen(BTC_MARKET_ID, 60, LucidTypes.ASSET_BTC);
        _fireBtc();

        LucidTypes.MarketInfo memory m = router.marketOf(BTC_MARKET_ID);
        assertEq(m.marketId, BTC_MARKET_ID, "marketId");
        assertEq(m.pool, BTC_POOL, "pool");
        assertEq(m.venueId, VENUE_ID, "venueId");
        assertEq(m.operatorId, 4, "operatorId");
        assertEq(m.expiry, EXPIRY, "expiry");
        assertEq(m.tradingStart, TRADING_START, "tradingStart");
        assertEq(m.assetKey, LucidTypes.ASSET_BTC, "assetKey");
        assertEq(m.intervalSec, 60, "intervalSec");
    }

    function test_marketCreated_requests_exactly_one_verdict_for_many_desks() public {
        MockDeskForRouter a = _newDesk(true, 1 ether);
        MockDeskForRouter b = _newDesk(true, 1 ether);
        MockDeskForRouter c = _newDesk(true, 1 ether);

        uint256 fee = brain.fee();

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.VerdictRequested(BTC_MARKET_ID, fee, 3);
        _fireBtc();

        assertEq(brain.requestCount(), 1, "one request serves the whole fan-out");
        assertEq(brain.lastValue(), fee, "the full quoted fee is forwarded");
        assertEq(brain.lastMarketId(), BTC_MARKET_ID, "for this market");

        address[] memory interested = router.interestedIn(BTC_MARKET_ID);
        assertEq(interested.length, 3, "all three desks are on the hook");

        // The fee is split, and each desk also pre-pays its slice of the settlement one-shot.
        uint256 share = _ceilDiv(fee, 3) + router.SETTLEMENT_BUDGET();
        assertEq(router.gasCreditOf(address(a)), 1 ether - share, "desk a debited");
        assertEq(router.gasCreditOf(address(b)), 1 ether - share, "desk b debited");
        assertEq(router.gasCreditOf(address(c)), 1 ether - share, "desk c debited");
    }

    function test_no_verdict_requested_when_every_desk_declines() public {
        MockDeskForRouter a = _newDesk(false, 1 ether);
        MockDeskForRouter b = _newDesk(false, 1 ether);

        _fireBtc();

        assertEq(brain.requestCount(), 0, "no verdict");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "nobody on the hook");
        assertEq(router.gasCreditOf(address(a)), 1 ether, "not charged");
        assertEq(router.gasCreditOf(address(b)), 1 ether, "not charged");
        assertEq(precompile.subscriptionCount(), 1, "no settlement one-shot for an empty market");
    }

    function test_a_reverting_precheck_only_drops_that_desk() public {
        MockDeskForRouter bad = _newDesk(true, 1 ether);
        bad.setRevertModes(true, false, false, false);
        MockDeskForRouter good = _newDesk(true, 1 ether);

        _fireBtc();

        address[] memory interested = router.interestedIn(BTC_MARKET_ID);
        assertEq(interested.length, 1, "only the healthy desk");
        assertEq(interested[0], address(good), "the healthy desk");
    }

    /// @dev The brain refuses by returning zero, not by reverting, so the router's `try` succeeds
    /// on the one path where nothing was bought. Reading only "it did not revert" would debit every
    /// desk for a committee call that was never made — and then wake them at settlement for a
    /// position none of them hold.
    function test_a_refused_verdict_charges_nobody_and_says_so() public {
        MockRefusingBrain refusing = new MockRefusingBrain();
        vm.prank(owner);
        router.setBrain(address(refusing));

        MockDeskForRouter a = _newDesk(true, 1 ether);
        MockDeskForRouter b = _newDesk(true, 1 ether);

        vm.recordLogs();
        _fireBtc();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(refusing.requestCount(), 1, "the brain was asked, and it declined");

        assertEq(router.gasCreditOf(address(a)), 1 ether, "not charged for a request that never went out");
        assertEq(router.gasCreditOf(address(b)), 1 ether, "not charged either");
        assertEq(router.totalGasCredit(), 2 ether, "and the credit book agrees");

        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "nobody is on the hook for a verdict nobody bought");
        assertEq(precompile.subscriptionCount(), 1, "and no settlement one-shot was booked for them");

        // Every desk that would have paid is named, because "we decided not to" and "nothing
        // happened" have to be distinguishable from outside.
        assertEq(_countReason(logs, address(a), "NO_VERDICT"), 1, "desk a is told why");
        assertEq(_countReason(logs, address(b), "NO_VERDICT"), 1, "desk b is told why");
        assertEq(_countSkipped(logs), 2, "and nothing else was skipped for any other reason");

        // A refusal is not a verdict request, and the log must not claim otherwise.
        assertEq(_countTopic(logs, keccak256("VerdictRequested(bytes32,uint256,uint256)")), 0, "nothing was requested");
        assertEq(_countTopic(logs, keccak256("Debited(address,bytes32,uint256)")), 0, "and nothing was debited");
    }

    /// @dev The other half of the same property: a real request id still debits exactly as it did
    /// before the refusal path existed. A guard that also suppressed the paying case would be the
    /// more expensive bug.
    function test_a_granted_verdict_still_debits_exactly_as_before() public {
        MockDeskForRouter a = _newDesk(true, 1 ether);
        MockDeskForRouter b = _newDesk(true, 1 ether);

        uint256 fee = brain.fee();
        uint256 share = _ceilDiv(fee, 2) + router.SETTLEMENT_BUDGET();

        vm.recordLogs();
        _fireBtc();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(brain.requestCount(), 1, "the mock brain answers with a non-zero id");
        assertEq(router.gasCreditOf(address(a)), 1 ether - share, "desk a debited its share");
        assertEq(router.gasCreditOf(address(b)), 1 ether - share, "desk b debited its share");
        assertEq(router.totalGasCredit(), 2 ether - 2 * share, "and the credit book agrees");

        assertEq(router.interestedIn(BTC_MARKET_ID).length, 2, "both desks are on the hook");
        assertEq(precompile.subscriptionCount(), 2, "and their settlement wake-up is booked");

        assertEq(_countTopic(logs, keccak256("VerdictRequested(bytes32,uint256,uint256)")), 1, "one request");
        assertEq(_countReason(logs, address(a), "NO_VERDICT"), 0, "and nobody was told it was refused");
        assertEq(_countReason(logs, address(b), "NO_VERDICT"), 0);
    }

    // ── settlement scheduling ─────────────────────────────────────────────────

    function test_settlement_oneshot_is_scheduled_after_expiry() public {
        _newDesk(true, 1 ether);

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.SettlementScheduled(BTC_MARKET_ID, DUE_MS, 2);
        _fireBtc();

        assertEq(precompile.subscriptionCount(), 2, "venue subscription plus one-shot");

        ISomniaReactivityPrecompile.SubscriptionData memory s = precompile.subscriptionAt(1);
        assertEq(s.eventTopics[0], LucidTypes.TOPIC_SCHEDULE, "Schedule(uint256)");
        assertEq(s.eventTopics[1], bytes32(DUE_MS), "absolute millisecond timestamp");
        assertEq(s.eventTopics[2], bytes32(0), "wildcard");
        assertEq(s.eventTopics[3], bytes32(0), "wildcard");
        assertEq(s.emitter, PRECOMPILE, "system events come from the precompile");
        assertEq(s.handlerContractAddress, address(router), "the router handles it");
        assertGe(s.gasLimit, 5_000_000, "the same 5M floor applies to one-shots");

        bytes32[] memory due = router.pendingAt(DUE_MS);
        assertEq(due.length, 1, "one market due");
        assertEq(due[0], BTC_MARKET_ID, "the BTC window");
        assertEq(router.scheduleIdAt(DUE_MS), 2, "the one-shot id is remembered");
    }

    function test_one_schedule_subscription_per_timestamp() public {
        _newDesk(true, 1 ether);

        _fireBtc();
        _fireEth();

        // Both fixtures are the same 60-second window, so they settle at the same millisecond.
        assertEq(precompile.subscriptionCount(), 2, "the second market reuses the one-shot");
        assertEq(router.pendingAt(DUE_MS).length, 2, "both markets queued on it");
    }

    function test_schedule_fires_settlement_for_all_markets_due_at_that_timestamp() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _fireEth();

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 2, "settled in both markets");
        assertEq(router.pendingAt(DUE_MS).length, 0, "the queue is drained");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "the one-shot slot is freed for reuse");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "positions closed out");
        assertEq(router.interestedIn(ETH_MARKET_ID).length, 0, "positions closed out");
    }

    function test_an_unknown_topic_is_ignored_silently() public {
        _newDesk(true, 1 ether);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("SomethingElse()");

        vm.prank(PRECOMPILE);
        router.onEvent(MODULE, topics, "");

        assertEq(brain.requestCount(), 0, "nothing happened");
    }

    // ── fan-out bounds and isolation ──────────────────────────────────────────

    function test_fanout_is_bounded_at_max() public {
        uint256 max = router.MAX_FANOUT();
        for (uint256 i; i < max + 8; ++i) {
            _newDesk(true, 1 ether);
        }

        _fireBtc();

        assertEq(router.armedDesks().length, max + 8, "all desks are armed");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, max, "but only MAX_FANOUT are served");
        assertEq(brain.requestCount(), 1, "still one verdict");
    }

    function test_a_reverting_desk_does_not_break_the_others() public {
        MockDeskForRouter bad = _newDesk(true, 1 ether);
        MockDeskForRouter good = _newDesk(true, 1 ether);
        bad.setRevertModes(false, true, true, false);

        _fireBtc();

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(bad), BTC_MARKET_ID, "DESK_REVERTED");
        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(good.verdictCalls(), 1, "the healthy desk still traded");
        assertEq(bad.verdictCalls(), 0, "the broken one did not");

        vm.warp(EXPIRY + 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(bad), BTC_MARKET_ID, "SETTLEMENT_REVERTED");
        _fireSchedule(DUE_MS);

        assertEq(good.settlementCalls(), 1, "the healthy desk still settled");
    }

    /// @dev A desk that reverts is cheap to survive; a desk that eats the whole gas budget is not.
    /// The per-call stipend is what keeps one runaway desk from starving the rest of the fan-out.
    function test_a_gas_burning_desk_cannot_starve_the_others() public {
        MockDeskForRouter bomb = _newDesk(true, 1 ether);
        MockDeskForRouter good = _newDesk(true, 1 ether);
        bomb.setGasBombs(true, true);

        _fireBtc();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));
        assertEq(good.verdictCalls(), 1, "survived the runaway desk");

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);
        assertEq(good.settlementCalls(), 1, "survived it again at settlement");
    }

    // ── gas credit ────────────────────────────────────────────────────────────

    function test_desk_without_credit_is_skipped_and_emits() public {
        MockDeskForRouter broke = _newDesk(true, 0);
        MockDeskForRouter funded = _newDesk(true, 1 ether);

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(broke), BTC_MARKET_ID, "NO_CREDIT");
        _fireBtc();

        address[] memory interested = router.interestedIn(BTC_MARKET_ID);
        assertEq(interested.length, 1, "only the funded desk");
        assertEq(interested[0], address(funded), "the funded desk");
        assertEq(router.gasCreditOf(address(broke)), 0, "nothing to take");
    }

    /// @dev Dropping a desk raises the share for everyone left, so the split has to settle on the
    /// set that actually pays it rather than on the set that was merely considered.
    function test_the_fee_share_is_computed_on_the_desks_that_actually_pay() public {
        uint256 fee = brain.fee();
        uint256 budget = router.SETTLEMENT_BUDGET();

        // One wei short of a half share, so it is dropped in the first round; the desk left behind
        // must then be charged the whole fee rather than half of it.
        uint256 thinCredit = _ceilDiv(fee, 2) + budget - 1;
        MockDeskForRouter thin = _newDesk(true, thinCredit);
        MockDeskForRouter rich = _newDesk(true, 1 ether);

        _fireBtc();

        address[] memory interested = router.interestedIn(BTC_MARKET_ID);
        assertEq(interested.length, 1, "the thin desk cannot afford the reduced set's share");
        assertEq(interested[0], address(rich), "the rich desk");
        assertEq(router.gasCreditOf(address(thin)), thinCredit, "a dropped desk is never charged");
        assertEq(router.gasCreditOf(address(rich)), 1 ether - (fee + budget), "charged the whole fee");
        assertEq(brain.lastValue(), fee, "the brain still receives exactly the quote");
    }

    function test_topUp_credits_the_desk_and_locks_it_against_sweep() public {
        MockDeskForRouter d = _newDesk(true, 0);

        router.topUp{value: 2 ether}(address(d));
        assertEq(router.gasCreditOf(address(d)), 2 ether, "credited");
        assertEq(router.totalGasCredit(), 2 ether, "tracked");

        uint256 free = address(router).balance - 2 ether;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LucidRouter.CreditsLocked.selector, free, free + 1));
        router.sweep(owner, free + 1);

        vm.prank(owner);
        router.sweep(owner, free);
        assertEq(owner.balance, free, "the operator may only take its own float");
    }

    function test_topUp_rejects_an_unregistered_desk() public {
        vm.expectRevert(abi.encodeWithSelector(LucidRouter.UnknownDesk.selector, stranger));
        router.topUp{value: 1 ether}(stranger);
    }

    // ── verdict fan-out ───────────────────────────────────────────────────────

    function test_onVerdict_only_from_brain() public {
        _newDesk(true, 1 ether);
        _fireBtc();

        vm.prank(stranger);
        vm.expectRevert(LucidRouter.NotBrain.selector);
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));
    }

    function test_pBook_is_the_book_mid() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).setLevel(true, 870_000, 200);
        MockPool(BTC_POOL).setLevel(false, 890_000, 200);

        _fireBtc();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        // (0.87 + 0.89) / 2 = 0.88 of one collateral unit.
        assertEq(d.lastPBookBps(), 8_800, "book mid in bps");
        assertEq(d.lastProbUpBps(), 6_200, "the committee's number is passed through");
        assertEq(d.lastVerdictMarketId(), BTC_MARKET_ID, "for this market");
    }

    function test_pBook_uses_the_one_side_that_exists() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).setLevel(true, 640_000, 100);

        _fireBtc();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(5000));

        assertEq(d.lastPBookBps(), 6_400, "a one-sided book is still information");
    }

    function test_pBook_defaults_to_5000_when_the_book_is_empty() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).clearBook();

        _fireBtc();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(d.lastPBookBps(), 5_000, "an empty book implies nothing but a coin flip");
    }

    function test_pBook_defaults_to_5000_when_the_pool_reverts() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).setRevertOnBook(true);

        _fireBtc();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(d.lastPBookBps(), 5_000, "a broken pool must not take the fan-out down");
    }

    // ── copy trading ──────────────────────────────────────────────────────────
    //
    // The copy-trade graph itself lives in LucidFactory. The router only reads it, through a
    // two-function view, so that a change to how leaders are published cannot reach the contract
    // holding the reactivity bond.

    function test_follower_receives_a_scaled_trade() public {
        MockDeskForRouter leader = _newDesk(true, 1 ether);
        leader.setTradeReport(true, LucidTypes.BUY_YES, 100e6);

        // The follower declines the market on its own account; it is here purely to copy.
        MockDeskForRouter follower = _newDesk(false, 1 ether);
        _linkFollower(address(leader), address(follower), 2_500);

        _fireBtc();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(follower.leaderTradeCalls(), 1, "copied once");
        assertEq(follower.lastLeaderMarketId(), BTC_MARKET_ID, "same market");
        assertEq(follower.lastLeaderKind(), LucidTypes.BUY_YES, "same direction");
        assertEq(follower.lastLeaderStake(), 25e6, "25% of the leader's stake");

        // A desk that took a position must be settled, so copying puts it on the settlement list.
        address[] memory interested = router.interestedIn(BTC_MARKET_ID);
        assertEq(interested.length, 2, "leader plus follower");
        assertEq(interested[1], address(follower), "the follower was added");
    }

    function test_fanout_skips_when_no_factory_is_set() public {
        MockDeskForRouter leader = _newDesk(true, 1 ether);
        leader.setTradeReport(true, LucidTypes.BUY_YES, 100e6);
        MockDeskForRouter follower = _newDesk(false, 1 ether);

        // Deliberately no setFactory: there is no graph to read.
        assertEq(router.factory(), address(0), "no factory");

        _fireBtc();
        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(follower.leaderTradeCalls(), 0, "nothing copied");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 1, "only the leader");
    }

    function test_a_broken_factory_does_not_break_the_verdict_fanout() public {
        MockDeskForRouter leader = _newDesk(true, 1 ether);
        leader.setTradeReport(true, LucidTypes.BUY_YES, 100e6);
        MockDeskForRouter follower = _newDesk(false, 1 ether);
        _linkFollower(address(leader), address(follower), 2_500);
        factory.setRevertOnRead(true);

        _fireBtc();
        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(leader.verdictCalls(), 1, "the leader still traded");
        assertEq(follower.leaderTradeCalls(), 0, "the copy simply did not happen");
    }

    function test_an_over_leveraged_link_is_refused() public {
        MockDeskForRouter leader = _newDesk(true, 1 ether);
        leader.setTradeReport(true, LucidTypes.BUY_YES, 100e6);
        MockDeskForRouter follower = _newDesk(false, 1 ether);
        _linkFollower(address(leader), address(follower), 10_001);

        _fireBtc();

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(follower), BTC_MARKET_ID, "BAD_SCALE");
        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(follower.leaderTradeCalls(), 0, "a follower is never levered above its leader");
    }

    function test_follower_without_credit_is_skipped_and_emits() public {
        MockDeskForRouter leader = _newDesk(true, 1 ether);
        leader.setTradeReport(true, LucidTypes.BUY_YES, 100e6);
        MockDeskForRouter follower = _newDesk(false, 0);
        _linkFollower(address(leader), address(follower), 5_000);

        _fireBtc();

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(follower), BTC_MARKET_ID, "NO_CREDIT");
        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(follower.leaderTradeCalls(), 0, "copying is work, and work is paid for");
    }

    function test_setFactory_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setFactory(address(1));
    }

    function test_reportTrade_is_desk_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LucidRouter.UnknownDesk.selector, stranger));
        router.reportTrade(BTC_MARKET_ID, LucidTypes.BUY_YES, 1e6);
    }

    // ── venue-wide upkeep ─────────────────────────────────────────────────────
    //
    // DreamDEX's upkeep calls are permissionless and effectively nobody makes them. This router is
    // already awake for every market the venue creates, so with a keeper attached it wakes up for
    // all of them rather than only for the ones its own desks took a position in. Without one it
    // behaves exactly as it did before, and pays for exactly what its desks asked for.

    function test_no_keeper_means_unchanged_scheduling() public {
        assertEq(router.keeper(), address(0), "no keeper by default");
        _newDesk(false, 1 ether);

        _fireBtc();

        assertEq(precompile.subscriptionCount(), 1, "no one-shot for a market nobody wanted");
        assertEq(router.pendingAt(DUE_MS).length, 0, "nothing queued");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "no one-shot recorded");
    }

    function test_with_a_keeper_every_venue_market_gets_a_oneshot() public {
        MockKeeperForRouter keeper = _attachKeeper();

        // No desks at all: these two windows are pure public good.
        _fireBtc();
        _fireEth();

        assertEq(precompile.subscriptionCount(), 2, "venue subscription plus one shared one-shot");
        assertEq(router.scheduleIdAt(DUE_MS), 2, "the one-shot is recorded");

        bytes32[] memory due = router.pendingAt(DUE_MS);
        assertEq(due.length, 2, "both markets queued for upkeep");
        assertEq(due[0], BTC_MARKET_ID, "BTC");
        assertEq(due[1], ETH_MARKET_ID, "ETH");
        assertEq(keeper.keepCalls(), 0, "nothing kept until the window closes");
    }

    /// @dev The whole point of the keeper: it reaches markets this protocol has no stake in.
    function test_keeper_is_called_for_a_market_no_desk_held() public {
        MockKeeperForRouter keeper = _attachKeeper();

        _fireBtc();
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "no desk holds this window");

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(keeper.keepCalls(), 1, "upkeep ran anyway");
        assertEq(keeper.lastMarketId(), BTC_MARKET_ID, "for the venue's market");
        assertEq(keeper.lastMarket(), BTC_MARKET_ADDR, "and it was handed the market contract");
    }

    /// @dev The upkeep is a favour to the venue, and a favour must never cost the desks that paid
    /// for the firing their settlement.
    function test_a_reverting_keeper_does_not_break_settlement() public {
        MockKeeperForRouter keeper = _attachKeeper();
        keeper.setRevertOnKeep(true);
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(router.pendingAt(DUE_MS).length, 1, "a served market is queued exactly once");

        vm.warp(EXPIRY + 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(keeper), BTC_MARKET_ID, "KEEPER_FAILED");
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the desk still settled");
        assertEq(keeper.keepCalls(), 0, "and the keeper recorded nothing it did not do");
    }

    function test_only_owner_can_set_keeper() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setKeeper(address(1));

        assertEq(router.keeper(), address(0), "unchanged");
    }

    // ── pre-signed exits ──────────────────────────────────────────────────────
    //
    // A winning position on DreamDEX does not pay itself out, and the venue's own web app
    // auto-claims only for its own users. The relay holds exits their owners signed in advance and
    // needs somebody awake at settlement to run them; this router already is. It is attached the
    // same way the keeper is, and detaching it must leave the router exactly as it was.

    function test_no_relay_leaves_settlement_unchanged() public {
        assertEq(router.relay(), address(0), "no relay by default");
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the desk settled exactly as it always has");
        assertEq(d.lastSettledMarketId(), BTC_MARKET_ID, "for its market");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "positions closed out");
        assertEq(router.pendingAt(DUE_MS).length, 0, "the queue drained");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "the one-shot slot was freed");
        assertEq(precompile.subscriptionCount(), 2, "and no extra subscription was taken out");
    }

    function test_relay_is_drained_at_settlement() public {
        MockKeeperForRouter keeper = _attachKeeper();
        MockRelayForRouter exits = _attachRelay();
        exits.watch(keeper);
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(exits.relayCalls(), 0, "nothing is redeemed before the window closes");

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(exits.relayCalls(), 1, "the exits were drained for the settled window");
        assertEq(exits.lastMarketId(), BTC_MARKET_ID, "for this market and no other");
        assertEq(exits.lastMax(), router.RELAY_BATCH(), "in a bounded batch, never the whole queue");
        assertEq(exits.keepsWhenRelayed(), 1, "and only after the keeper finalized the market");
        assertEq(d.settlementCalls(), 1, "the desk that paid for the firing still settled");
    }

    /// @dev The relay is a favour to whoever queued an exit, and a favour must never cost the desks
    /// that paid for this firing their settlement.
    function test_a_reverting_relay_does_not_break_settlement() public {
        MockRelayForRouter exits = _attachRelay();
        exits.setRevertOnRelay(true);
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();

        vm.warp(EXPIRY + 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(exits), BTC_MARKET_ID, "RELAY_FAILED");
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the desk still settled");
        assertEq(exits.relayCalls(), 0, "and the relay recorded nothing it did not do");

        // The other half of the guard, and the one `try` cannot cover: an address with no code.
        // The compiler's own `extcodesize` check raises outside the `catch`, so a relay that was
        // never deployed has to be refused before the call rather than caught after it.
        vm.warp(TRADING_START);
        vm.prank(owner);
        router.setRelay(stranger);

        _fireEth();
        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 2, "an EOA relay is passed over and settlement is unharmed");
        assertEq(d.lastSettledMarketId(), ETH_MARKET_ID, "the second window");
    }

    function test_only_owner_can_set_relay() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setRelay(address(1));

        assertEq(router.relay(), address(0), "unchanged");

        vm.expectEmit(false, false, false, true, address(router));
        emit LucidRouter.RelaySet(address(1));
        vm.prank(owner);
        router.setRelay(address(1));
        assertEq(router.relay(), address(1), "the operator may attach one");

        vm.prank(owner);
        router.setRelay(address(0));
        assertEq(router.relay(), address(0), "and detach it again");
    }

    // ── adaptive gas stipends ─────────────────────────────────────────────────
    //
    // The bug these pin was found live on Shannon. The router handed every desk a flat
    // DESK_GAS = 1_000_000, a desk's `onVerdict` needed 1_314_773 against real chain state, and so
    // every call ran out of gas, the `catch` swallowed it, and the router logged "VERDICT_FAILED" —
    // which reads as "the committee failed" when the committee had answered 3/3 with ok = true and
    // the only thing that was wrong was our own budget. Two separate defects: a stipend calibrated
    // for mainnet-Ethereum gas costs on a chain where an SSTORE plus an event measures ~250_000,
    // and a label that pointed at the wrong component.

    /// @dev A fixed stipend is a promise the frame may not be able to keep. Asking for eight
    /// million out of a three million frame does not fail loudly — the 63/64 rule truncates the
    /// request, the callee quietly takes almost everything there is, and whatever the router still
    /// had to do after the call is left with nothing. The cap makes the shortfall explicit, and
    /// the reserve is what the loop finishes on.
    function test_stipend_is_capped_by_remaining_gas() public {
        MockGasWitnessDesk witness = new MockGasWitnessDesk();
        _admitDesk(address(witness), 1 ether);

        _fireBtc();

        uint256 frame = 3_000_000;
        assertLt(frame, router.DESK_GAS(), "the frame really is smaller than the ceiling asks for");

        assertTrue(_callVerdict(frame), "the handler finished rather than running out of gas");

        // Everything above the reserve, less the 64th the EVM keeps back on any call.
        uint256 ceiling = ((frame - router.GAS_RESERVE()) * 63) / 64;
        assertGt(witness.lastVerdictGas(), 0, "the desk was given a real budget");
        assertLe(witness.lastVerdictGas(), ceiling, "sized against the frame, not against DESK_GAS");
        assertLt(witness.lastVerdictGas(), frame - router.GAS_RESERVE(), "and the reserve was held back");
    }

    /// @dev Zero gas is not a budget. Calling with it and then reporting the revert would blame the
    /// desk for a shortfall that was entirely ours, which is exactly the mistake that shipped.
    function test_desk_is_skipped_with_NO_GAS_when_the_budget_is_exhausted() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        _fireBtc();

        // At the reserve there is nothing left to give away, by construction: the frame the router
        // holds back for its own bookkeeping is the whole frame.
        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(d), BTC_MARKET_ID, "NO_GAS");
        assertTrue(_callVerdict(router.GAS_RESERVE()), "the fan-out still reported");

        assertEq(d.verdictCalls(), 0, "and the desk was never called with a budget it could not use");
    }

    /// @dev The reason string is diagnostic output. "VERDICT_FAILED" named the committee; this one
    /// names the contract that actually reverted.
    function test_a_reverting_desk_is_labelled_DESK_REVERTED() public {
        MockDeskForRouter bad = _newDesk(true, 1 ether);
        bad.setRevertModes(false, true, false, false);
        MockDeskForRouter good = _newDesk(true, 1 ether);

        _fireBtc();

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(bad), BTC_MARKET_ID, "DESK_REVERTED");
        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertEq(bad.verdictCalls(), 0, "the broken desk did nothing");
        assertEq(good.verdictCalls(), 1, "and its neighbour was untouched by the label");
    }

    function test_settlement_revert_is_labelled_SETTLEMENT_REVERTED() public {
        MockDeskForRouter bad = _newDesk(true, 1 ether);
        bad.setRevertModes(false, false, true, false);
        MockDeskForRouter good = _newDesk(true, 1 ether);

        _fireBtc();
        vm.warp(EXPIRY + 5);

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(bad), BTC_MARKET_ID, "SETTLEMENT_REVERTED");
        _fireSchedule(DUE_MS);

        assertEq(good.settlementCalls(), 1, "the healthy desk still settled");
    }

    /// @dev The subscription ceiling is billed only when a handler actually runs out of gas, and
    /// then it is billed in full — so headroom is free and a tight limit is not. It still has to
    /// clear the precompile's own cap, which rejects the subscription outright.
    function test_handler_gas_limit_is_within_the_precompile_maximum() public {
        assertLe(
            router.HANDLER_GAS_LIMIT(),
            SomniaExtensions.MAXIMUM_HANDLER_GAS_LIMIT,
            "above this the precompile refuses to subscribe at all"
        );
        assertLe(uint256(router.HANDLER_GAS_LIMIT()), 200_000_000, "the cap, spelled out");

        _newDesk(true, 1 ether);
        _fireBtc();

        assertEq(precompile.subscriptionCount(), 2, "the venue log subscription and the settlement one-shot");
        assertEq(precompile.subscriptionAt(0).gasLimit, router.HANDLER_GAS_LIMIT(), "venue log subscription");
        assertEq(precompile.subscriptionAt(1).gasLimit, router.HANDLER_GAS_LIMIT(), "settlement one-shot");
    }

    /// @dev The property that matters when the budget runs out partway down a list: every desk is
    /// accounted for. Served, or named in a skip. A desk that silently falls off the end is
    /// indistinguishable from a desk that was never armed, and that is the failure mode the live
    /// bug produced.
    function test_the_whole_fanout_still_reports_when_gas_runs_short() public {
        uint256 n = 5;
        MockDeskForRouter[] memory desks = new MockDeskForRouter[](n);
        for (uint256 i; i < n; ++i) {
            desks[i] = _newDesk(true, 1 ether);
            // Every desk asks for everything it is given, so the budget cannot reach the end of
            // the list however it is sliced.
            desks[i].setGasBombs(true, false);
        }

        _fireBtc();
        assertEq(router.interestedIn(BTC_MARKET_ID).length, n, "all five are on the hook");

        vm.recordLogs();
        assertTrue(_callVerdict(4_000_000), "the fan-out finished rather than reverting");

        uint256 skipped = _countSkipped(vm.getRecordedLogs());
        uint256 served;
        for (uint256 i; i < n; ++i) {
            served += desks[i].verdictCalls();
        }
        assertEq(served, 0, "a frame this size serves nobody");
        assertEq(skipped, n, "and every one of them is named rather than dropped");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Delivers a verdict inside a frame of exactly `gasCap`, which is the only way to reach
    /// the branches where the router runs out of budget mid-fan-out.
    function _callVerdict(uint256 gasCap) internal returns (bool ok) {
        bytes memory payload = abi.encodeCall(LucidRouter.onVerdict, (BTC_MARKET_ID, _verdict(6200)));

        vm.prank(address(brain));
        (ok,) = address(router).call{gas: gasCap}(payload);
    }

    /// @dev How many `Skipped` events the router emitted, whatever the reason on each.
    function _countSkipped(Vm.Log[] memory logs) internal view returns (uint256 count) {
        bytes32 topic0 = keccak256("Skipped(address,bytes32,string)");

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic0) continue;
            ++count;
        }
    }

    /// @dev How many `Skipped` events named one desk with one exact reason. The reason is the whole
    /// point of the event — a skip that does not say which component declined sends whoever reads
    /// the log to debug the wrong contract — so a test that only counted skips would not be testing
    /// it.
    function _countReason(Vm.Log[] memory logs, address desk, string memory reason)
        internal
        view
        returns (uint256 count)
    {
        bytes32 topic0 = keccak256("Skipped(address,bytes32,string)");

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic0) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != desk) continue;
            if (keccak256(bytes(abi.decode(logs[i].data, (string)))) != keccak256(bytes(reason))) continue;
            ++count;
        }
    }

    /// @dev How many events of one signature the router emitted.
    function _countTopic(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) ++count;
        }
    }

    function _newDesk(bool wants, uint256 credit) internal returns (MockDeskForRouter d) {
        d = new MockDeskForRouter(deskOwner, address(router));
        d.setWants(wants);

        _admitDesk(address(d), credit);
    }

    /// @dev Registers, arms and funds any desk-shaped contract, so a test can bring its own.
    function _admitDesk(address desk, uint256 credit) internal {
        vm.prank(owner);
        router.registerDesk(desk);

        vm.prank(desk);
        router.setDeskArmed(desk, true);

        if (credit != 0) router.topUp{value: credit}(desk);
    }

    /// @dev Publishes a copy-trade link in the factory, attaching the factory on first use so the
    /// no-factory case stays reachable in the tests that need it.
    function _linkFollower(address leader, address follower, uint16 scaleBps) internal {
        if (address(factory) == address(0)) {
            factory = new MockFactoryView();
            vm.prank(owner);
            router.setFactory(address(factory));
        }
        factory.link(leader, follower, scaleBps);
    }

    /// @dev Attaches the venue-wide upkeep runner, which is what widens the router's scheduling
    /// from "markets a desk holds" to "every market on the venue".
    function _attachKeeper() internal returns (MockKeeperForRouter keeper) {
        keeper = new MockKeeperForRouter();
        vm.prank(owner);
        router.setKeeper(address(keeper));
    }

    /// @dev Attaches the auto-redeem relay woken after a window settles.
    function _attachRelay() internal returns (MockRelayForRouter exits) {
        exits = new MockRelayForRouter();
        vm.prank(owner);
        router.setRelay(address(exits));
    }

    function _verdict(uint16 probUpBps) internal pure returns (LucidTypes.Verdict memory) {
        return LucidTypes.Verdict({probUpBps: probUpBps, responded: 3, agreed: 3, ok: true, requestId: 7});
    }

    function _fireBtc() internal {
        vm.prank(PRECOMPILE);
        router.onEvent(MODULE, _btcTopics(), _btcData());
    }

    function _fireEth() internal {
        vm.prank(PRECOMPILE);
        router.onEvent(MODULE, _ethTopics(), _ethData());
    }

    function _fireSchedule(uint256 tsMillis) internal {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = LucidTypes.TOPIC_SCHEDULE;
        topics[1] = bytes32(tsMillis);

        vm.prank(PRECOMPILE);
        router.onEvent(PRECOMPILE, topics, "");
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    // ── fixtures, verbatim from Shannon ───────────────────────────────────────

    function _btcTopics() internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](4);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;
        topics[1] = 0x0000000000000000000000000000000000000000000000000000000000014898;
        topics[2] = 0x000000000000000000000000c7b7f71513eaf972b9ff6c0ddb6144e322ba63b0;
        topics[3] = 0x000000000000000000000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb308;
    }

    function _ethTopics() internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](4);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;
        topics[1] = 0x0000000000000000000000000000000000000000000000000000000000014899;
        topics[2] = 0x000000000000000000000000e7a6118ebcd087f41b9308abff545f0cdc6bac7c;
        topics[3] = 0x00000000000000000000000056154c18cf0e7e601919b13c7478747398aa5057;
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

    function _ethData() internal pure returns (bytes memory) {
        return hex"830641a37e0be8d9dd46ce6ff2bb8327e913b603966c14190a9cadbba7e00352"
            hex"0000000000000000000000000000000000000000000000000000000000000004"
            hex"1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f"
            hex"000000000000000000000000ee3aff92812a2cb7bf801b500687bc97b55cab34"
            hex"00000000000000000000000070a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e"
            hex"00000056154c18cf0e7e601919b13c7478747398aa5057000000000000034c00"
            hex"00000056154c18cf0e7e601919b13c7478747398aa5057000000000000034c01"
            hex"000000000000000000000000000000000000000000000000000000000000034c"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000006a9c96bc"
            hex"000000000000000000000000000000000000000000000000000000006a9c96f8"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000220"
            hex"000000000000000000000000000000000000000000000000000000000003ca54"
            hex"0000000000000000000000000000000000000000000000000000000000000260"
            hex"00000000000000000000000000000000000000000000000000000000000002e0"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"4554480000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000055"
            hex"50726963656665656420746573743a2077696c6c204554482f55534443277320"
            hex"7072696365206265206174206f722061626f766520323438342e303420617420"
            hex"756e69782074696d6520313738383634373136303f0000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000";
    }
}
