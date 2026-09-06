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

/// @notice The slice of `LucidSeries` the router drives: two hooks, and nothing else.
/// @dev Kept here for the same reason as `MockKeeperForRouter`. The series contract rolls this
/// protocol's own windows when the venue's creator runs out of float and stops rolling its own; the
/// router only feeds it two facts, so it must be able to do that without being able to break when
/// the series misbehaves.
contract MockSeriesForRouter {
    error SeriesIsDown();

    uint256 public venueMarketCalls;
    uint256 public tickCalls;
    bytes32 public lastVenueMarketId;
    uint32 public lastVenueInterval;
    bytes32 public lastTickMarketId;

    /// @dev Sampled inside the callee's frame. A live `triggerRoll` measured 61.6M gas, so whether
    /// the router actually hands over that much is a property rather than a detail.
    uint256 public lastTickGas;

    bool public revertOnCall;

    function setRevertOnCall(bool on) external {
        revertOnCall = on;
    }

    function onVenueMarket(LucidTypes.MarketInfo calldata m) external {
        if (revertOnCall) revert SeriesIsDown();
        ++venueMarketCalls;
        lastVenueMarketId = m.marketId;
        lastVenueInterval = m.intervalSec;
    }

    function onTick(LucidTypes.MarketInfo calldata m) external {
        if (revertOnCall) revert SeriesIsDown();
        lastTickGas = gasleft();
        ++tickCalls;
        lastTickMarketId = m.marketId;
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

    /// @dev Zero, so this mock's refusal is the one the test is looking at. A non-zero slack would
    /// make the router decline before it ever asked, and the property under test would go untested.
    function requiredSlack() external pure returns (uint256) {
        return 0;
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

    function onVerdict(LucidTypes.MarketInfo calldata, LucidTypes.Verdict calldata, uint256, bool) external {
        lastVerdictGas = gasleft();
    }

    function onSettlement(LucidTypes.MarketInfo calldata) external {
        lastSettlementGas = gasleft();
    }

    function onLeaderTrade(LucidTypes.MarketInfo calldata, uint8, uint256) external {}
}

/// @notice A subscriber that records nothing but the timestamp a wake-up actually carried.
/// @dev Kept here rather than in `test/mocks/` because it exists for exactly one property, and that
/// property is about the chain rather than about this protocol: what arrives in `eventTopics[1]` is
/// the instant the precompile emitted at, not the instant somebody asked for. A router cannot
/// observe this about itself — it can only fail to find its own work — so the observation is made
/// from outside.
contract MockScheduleRecorder {
    uint256 public calls;
    uint256 public lastTsMillis;

    function onEvent(address, bytes32[] calldata topics, bytes calldata) external {
        ++calls;
        lastTsMillis = uint256(topics[1]);
    }
}

/// @notice A keeper that remembers every window it was handed, in order.
/// @dev Kept here for the same reason as `MockKeeperForRouter`, and separate from it because it
/// answers a different question: not "was upkeep run" but "which windows, and how many times". A
/// bounded drain is only correct if the entries one firing declines are exactly the entries the
/// next firing takes, each of them once.
contract MockRecordingKeeper {
    bytes32[] internal _seen;

    function keep(LucidTypes.MarketInfo calldata m) external {
        _seen.push(m.marketId);
    }

    function seen() external view returns (bytes32[] memory) {
        return _seen;
    }

    function seenCount() external view returns (uint256) {
        return _seen.length;
    }
}

/// @notice A desk that says in the log exactly when it was settled.
/// @dev Kept here because the only observable that distinguishes "decisions are drained before
/// settlements" from "both happened" is the order the two appear in one transaction's logs, and
/// that needs an emitter the router does not control.
contract MockOrderedDesk {
    event Settled(bytes32 marketId);

    uint256 public settlementCalls;

    function preCheck(LucidTypes.MarketInfo calldata) external pure returns (bool) {
        return true;
    }

    function onVerdict(LucidTypes.MarketInfo calldata, LucidTypes.Verdict calldata, uint256, bool) external {}

    function onSettlement(LucidTypes.MarketInfo calldata m) external {
        ++settlementCalls;
        emit Settled(m.marketId);
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

    /// @dev Where `tradingStart` and `expiry` sit in the captured log body, counted in 32-byte
    /// words from the start of the non-indexed data. Rewriting those two words is what turns the
    /// fixture into a window of any cadence without inventing an encoding the decoder has never
    /// seen — `intervalSec` is derived from their difference.
    uint256 internal constant TRADING_START_WORD = 10;
    uint256 internal constant EXPIRY_WORD = 11;

    /// @dev The router schedules settlement five seconds after expiry, in milliseconds.
    uint256 internal constant DUE_MS = (uint256(EXPIRY) + 5) * 1000;

    /// @dev Halfway through the fixture's 60-second window, which is where the committee is asked.
    /// At `TRADING_START` the strike IS the spot price, so the question has no answer but a coin
    /// flip; thirty seconds later the price has moved and there is something to reason about.
    uint256 internal constant DECISION_TS = uint256(TRADING_START) + 30;
    uint256 internal constant DECISION_MS = DECISION_TS * 1000;

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

    function test_the_decision_requests_exactly_one_verdict_for_many_desks() public {
        MockDeskForRouter a = _newDesk(true, 1 ether);
        MockDeskForRouter b = _newDesk(true, 1 ether);
        MockDeskForRouter c = _newDesk(true, 1 ether);

        uint256 fee = brain.fee();

        _fireBtc();
        assertEq(brain.requestCount(), 0, "nothing is asked at the open");

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.VerdictRequested(BTC_MARKET_ID, fee, 3);
        _decide();

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
        _decide();

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

        _fireBtc();
        // Recorded around the decision alone: the creation firing has its own `DecisionScheduled`
        // and its own skips, and the property here is about what the refusal did or did not charge.
        vm.recordLogs();
        _decide();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(refusing.requestCount(), 1, "the brain was asked, and it declined");

        assertEq(router.gasCreditOf(address(a)), 1 ether, "not charged for a request that never went out");
        assertEq(router.gasCreditOf(address(b)), 1 ether, "not charged either");
        assertEq(router.totalGasCredit(), 2 ether, "and the credit book agrees");

        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "nobody is on the hook for a verdict nobody bought");
        assertEq(precompile.subscriptionCount(), 2, "the venue subscription and the decision wake-up, and nothing more");
        assertEq(router.settlementQueueLength(), 0, "no settlement one-shot was booked for them");

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

        _fireBtc();
        vm.recordLogs();
        _decide();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(brain.requestCount(), 1, "the mock brain answers with a non-zero id");
        assertEq(router.gasCreditOf(address(a)), 1 ether - share, "desk a debited its share");
        assertEq(router.gasCreditOf(address(b)), 1 ether - share, "desk b debited its share");
        assertEq(router.totalGasCredit(), 2 ether - 2 * share, "and the credit book agrees");

        assertEq(router.interestedIn(BTC_MARKET_ID).length, 2, "both desks are on the hook");
        assertEq(precompile.subscriptionCount(), 3, "the venue subscription, the decision wake-up, and the settlement one");

        assertEq(_countTopic(logs, keccak256("VerdictRequested(bytes32,uint256,uint256)")), 1, "one request");
        assertEq(_countReason(logs, address(a), "NO_VERDICT"), 0, "and nobody was told it was refused");
        assertEq(_countReason(logs, address(b), "NO_VERDICT"), 0);
    }

    // ── settlement scheduling ─────────────────────────────────────────────────

    function test_settlement_oneshot_is_scheduled_after_expiry() public {
        _newDesk(true, 1 ether);

        // The window's own two wake-ups, in the order they are booked: the decision at creation,
        // the settlement once a desk has actually taken a position.
        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.DecisionScheduled(BTC_MARKET_ID, DECISION_MS, 2);
        _fireBtc();

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.SettlementScheduled(BTC_MARKET_ID, DUE_MS, 3);
        _decide();

        assertEq(precompile.subscriptionCount(), 3, "venue subscription, decision one-shot, settlement one-shot");

        ISomniaReactivityPrecompile.SubscriptionData memory s = precompile.subscriptionAt(2);
        assertEq(s.eventTopics[0], LucidTypes.TOPIC_SCHEDULE, "Schedule(uint256)");
        assertEq(s.eventTopics[1], bytes32(DUE_MS), "absolute millisecond timestamp");
        assertEq(s.eventTopics[2], bytes32(0), "wildcard");
        assertEq(s.eventTopics[3], bytes32(0), "wildcard");
        assertEq(s.emitter, PRECOMPILE, "system events come from the precompile");
        assertEq(s.handlerContractAddress, address(router), "the router handles it");
        assertGe(s.gasLimit, 5_000_000, "the same 5M floor applies to one-shots");

        LucidRouter.Pending[] memory due = router.pendingSettlements();
        assertEq(due.length, 1, "one market due");
        assertEq(due[0].marketId, BTC_MARKET_ID, "the BTC window");
        assertEq(uint256(due[0].dueAtSec), uint256(EXPIRY) + 5, "filed under its own due second, not under a wake-up key");
        assertEq(router.scheduleIdAt(DUE_MS), 3, "the one-shot id is remembered, purely so the instant is not booked twice");
    }

    function test_one_schedule_subscription_per_timestamp() public {
        _newDesk(true, 1 ether);

        _fireBtc();
        _fireEth();

        // Both fixtures are the same 60-second window, so they share a decision instant too.
        assertEq(precompile.subscriptionCount(), 2, "the second market reuses the decision one-shot");
        assertEq(router.decisionQueueLength(), 2, "both markets queued against the same instant");

        _decide();

        assertEq(precompile.subscriptionCount(), 3, "and one settlement one-shot serves both of them");
        assertEq(router.settlementQueueLength(), 2, "both markets queued against the same instant");
    }

    function test_schedule_fires_settlement_for_all_markets_due_at_that_timestamp() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _fireEth();
        _decide();

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 2, "settled in both markets");
        assertEq(router.settlementQueueLength(), 0, "the queue is drained");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "and the dedupe slot for that instant is freed with the work");
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

    // ── the decision point ────────────────────────────────────────────────────
    //
    // Observed live: every verdict came back exactly 50, from three validators that agreed, on a
    // 96ms-old spot of 7971580 for market 0x…1530a — and the desk correctly refused `LowEdge`
    // against it. The committee was not broken. For these markets the strike IS the window's
    // opening price, so at `tradingStart` spot equals strike and "will it close above the strike"
    // has no answer but a coin flip. Everything worked; the question was empty. It is now asked
    // partway through the window instead, once the price has had time to move away from the strike.

    function test_nothing_is_asked_at_creation_and_the_decision_is_booked_halfway_in() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.DecisionScheduled(BTC_MARKET_ID, DECISION_MS, 2);
        _fireBtc();

        assertEq(brain.requestCount(), 0, "no verdict is bought at the open any more");
        assertEq(router.gasCreditOf(address(d)), 1 ether, "and nobody is charged for one");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "nobody is on the hook yet");

        // tradingStart + 60s * 5000bps: halfway through the fixture's one-minute window.
        assertEq(DECISION_MS, (uint256(TRADING_START) + 30) * 1000, "halfway, in milliseconds");
        assertEq(router.decisionQueueLength(), 1, "one window is queued for it");
        assertEq(router.pendingDecisions()[0].marketId, BTC_MARKET_ID, "this one");
        assertEq(uint256(router.pendingDecisions()[0].dueAtSec), DECISION_TS, "due at the halfway second");
        assertEq(router.scheduleIdAt(DECISION_MS), 2, "and the one-shot id is remembered");

        ISomniaReactivityPrecompile.SubscriptionData memory sub = precompile.subscriptionAt(1);
        assertEq(sub.eventTopics[0], LucidTypes.TOPIC_SCHEDULE, "Schedule(uint256)");
        assertEq(sub.eventTopics[1], bytes32(DECISION_MS), "at the halfway millisecond");
        assertEq(sub.emitter, PRECOMPILE, "system events come from the precompile");
        assertEq(sub.handlerContractAddress, address(router), "the router handles it");
        assertGe(sub.gasLimit, 5_000_000, "the same 5M floor applies to a decision one-shot");

        _decide();

        assertEq(brain.requestCount(), 1, "the question is put when there is something to reason about");
        assertEq(brain.lastMarketId(), BTC_MARKET_ID, "for this window");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 1, "and only then is the desk on the hook");
        assertEq(router.decisionQueueLength(), 0, "the decision queue is drained");
        assertEq(router.scheduleIdAt(DECISION_MS), 0, "and the dedupe slot for that instant is freed with the work");
    }

    /// @dev The decision point is a fraction of the window rather than a fixed delay, because what
    /// matters is how far the price has travelled, not how many seconds have passed. An hour-long
    /// window is asked about half an hour in; a five-minute one, two and a half minutes in.
    function test_the_decision_point_is_a_fraction_of_the_window() public {
        LucidTypes.MarketInfo memory m;
        m.tradingStart = 1_000_000;

        m.intervalSec = 3600;
        assertEq(router.decisionPointOf(m), (1_000_000 + 1800) * 1000, "half of an hour");

        m.intervalSec = 300;
        assertEq(router.decisionPointOf(m), (1_000_000 + 150) * 1000, "half of five minutes");

        vm.prank(owner);
        router.setDecisionPoint(2_500);
        assertEq(router.decisionPointOf(m), (1_000_000 + 75) * 1000, "a quarter of five minutes");
    }

    /// @dev The router pays for its own wake-ups, and asking mid-window roughly doubles how many
    /// there are per market. A window no armed desk would touch must therefore cost nothing at all:
    /// no subscription, no float, no firing.
    function test_no_decision_is_booked_when_every_desk_declines_at_creation() public {
        MockDeskForRouter a = _newDesk(false, 1 ether);
        MockDeskForRouter b = _newDesk(false, 1 ether);

        _fireBtc();

        assertEq(precompile.subscriptionCount(), 1, "only the venue subscription: no wake-up was bought");
        assertEq(router.decisionQueueLength(), 0, "nothing queued to be priced");
        assertEq(router.scheduleIdAt(DECISION_MS), 0, "and no one-shot recorded");
        assertEq(router.gasCreditOf(address(a)), 1 ether, "nobody charged");
        assertEq(router.gasCreditOf(address(b)), 1 ether, "nobody charged");

        _decide();
        assertEq(brain.requestCount(), 0, "and there was nothing to wake up for");
    }

    /// @dev The brain refuses a window with less than `requiredSlack()` left — both of its stages
    /// have to finish and the desk still needs room to trade — so asking would spend a request in
    /// order to be told no. Every desk that would have paid is named instead, because "nobody
    /// wanted it" and "we ran out of window" are different facts.
    function test_a_decision_that_arrives_too_late_says_so_and_spends_nothing() public {
        MockDeskForRouter a = _newDesk(true, 1 ether);
        MockDeskForRouter b = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(router.decisionQueueLength(), 1, "the wake-up was booked at creation");

        // Thirty seconds of window remain at the decision point; the brain now wants six hundred.
        brain.setSlack(600);

        vm.recordLogs();
        _decide();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countReason(logs, address(a), "TOO_LATE"), 1, "desk a is told why");
        assertEq(_countReason(logs, address(b), "TOO_LATE"), 1, "desk b is told why");

        assertEq(brain.requestCount(), 0, "the committee was never asked");
        assertEq(router.gasCreditOf(address(a)), 1 ether, "and nothing was spent finding out");
        assertEq(router.gasCreditOf(address(b)), 1 ether, "nor by the other desk");
        assertEq(router.totalGasCredit(), 2 ether, "the credit book agrees");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "nobody holds this window");
        assertEq(router.settlementQueueLength(), 0, "so no settlement was booked for it either");
        assertEq(_countTopic(logs, keccak256("Debited(address,bytes32,uint256)")), 0, "nothing was debited");
        assertEq(_countTopic(logs, keccak256("VerdictRequested(bytes32,uint256,uint256)")), 0, "nothing requested");
    }

    /// @dev A brain this router cannot read makes nothing certain, so the window must not be blamed
    /// for it. `TOO_LATE` says the window ran out; the paths downstream name a missing or refusing
    /// brain accurately, and a guess here would send whoever reads the log to the wrong contract.
    function test_an_unreadable_slack_is_not_reported_as_TOO_LATE() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        _fireBtc();

        brain.setRevertOnSlack(true);

        vm.recordLogs();
        _decide();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countReason(logs, address(d), "TOO_LATE"), 0, "the window was not the problem");
        assertEq(brain.requestCount(), 1, "so the question was still put");
    }

    /// @dev The one confusion that must be impossible. A settlement mistaken for a decision would
    /// ask a committee to price a window that has already resolved; a decision mistaken for a
    /// settlement would close a position nobody has opened yet.
    function test_a_settlement_wakeup_is_never_mistaken_for_a_decision() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(router.decisionQueueLength(), 1, "queued to be priced");
        assertEq(router.settlementQueueLength(), 0, "and not to be settled");

        _decide();
        assertEq(d.settlementCalls(), 0, "a decision must not settle anybody");
        assertEq(router.settlementQueueLength(), 1, "queued to be settled");
        assertEq(router.decisionQueueLength(), 0, "and not to be priced");

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));
        assertEq(d.verdictCalls(), 1, "the desk took its position");

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "settled exactly once");
        assertEq(brain.requestCount(), 1, "and the settlement firing bought no second verdict");
    }

    function test_setDecisionPoint_is_owner_only_and_bounded() public {
        assertEq(router.decisionPointBps(), router.DECISION_POINT_BPS(), "halfway by default");
        assertEq(router.DECISION_POINT_BPS(), 5_000, "the value this protocol ships");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setDecisionPoint(4_000);
        assertEq(router.decisionPointBps(), 5_000, "unchanged");

        uint16 low = router.MIN_DECISION_POINT_BPS();
        uint16 high = router.MAX_DECISION_POINT_BPS();
        assertEq(low, 1_000, "a tenth of the window");
        assertEq(high, 8_000, "four fifths of it");

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(LucidRouter.BadDecisionPoint.selector, uint16(0)));
        router.setDecisionPoint(0);
        vm.expectRevert(abi.encodeWithSelector(LucidRouter.BadDecisionPoint.selector, low - 1));
        router.setDecisionPoint(low - 1);
        vm.expectRevert(abi.encodeWithSelector(LucidRouter.BadDecisionPoint.selector, high + 1));
        router.setDecisionPoint(high + 1);

        // Both ends of the band are themselves allowed; the bounds are inclusive.
        router.setDecisionPoint(low);
        assertEq(router.decisionPointBps(), low, "the earliest the operator may ask");
        router.setDecisionPoint(high);
        assertEq(router.decisionPointBps(), high, "and the latest");

        vm.expectEmit(false, false, false, true, address(router));
        emit LucidRouter.DecisionPointSet(6_000);
        router.setDecisionPoint(6_000);
        vm.stopPrank();

        assertEq(router.decisionPointBps(), 6_000, "and anything in between");
    }

    /// @dev A moved decision point has to move the wake-up that is actually booked, not merely the
    /// number in storage.
    function test_a_moved_decision_point_moves_the_wakeup() public {
        vm.prank(owner);
        router.setDecisionPoint(2_500);
        _newDesk(true, 1 ether);

        uint256 quarterMs = (uint256(TRADING_START) + 15) * 1000;

        vm.expectEmit(true, false, false, true, address(router));
        emit LucidRouter.DecisionScheduled(BTC_MARKET_ID, quarterMs, 2);
        _fireBtc();

        assertEq(router.decisionQueueLength(), 1, "one window queued");
        assertEq(
            uint256(router.pendingDecisions()[0].dueAtSec) * 1000, quarterMs, "due a quarter of the way in"
        );
        assertEq(router.scheduleIdAt(quarterMs), 2, "and the one-shot was booked for that instant");
        assertEq(router.scheduleIdAt(DECISION_MS), 0, "not for the halfway one");
    }

    // ── what the committee is told about the book ─────────────────────────────
    //
    // The book line was anchoring the committee. With an empty book the router substituted 50%,
    // the prompt printed it as a fact, and the committee was then asked to disagree with a number
    // this protocol had invented. It obediently repeated it — which is the other reason every
    // production verdict came back exactly 50.00%. Measured on the live committee with the same
    // window and the book line deleted, the identical question answered 95 on a +776 bps distance
    // to strike and 0 on the bearish case.

    function test_the_brain_is_told_when_there_was_no_book() public {
        _newDesk(true, 1 ether);
        MockPool(BTC_POOL).clearBook();

        _fireBtc();
        _decide();

        assertEq(brain.requestCount(), 1, "the committee was asked");
        assertEq(brain.lastPBookBps(), LucidTypes.BOOK_UNOBSERVED, "and no invented probability reached it");
        assertEq(uint256(LucidTypes.BOOK_UNOBSERVED), 65_535, "the sentinel, spelled out");
        assertGt(uint256(LucidTypes.BOOK_UNOBSERVED), uint256(LucidTypes.BPS), "outside the probability range");
    }

    function test_the_brain_is_given_the_real_mid_when_the_book_quotes() public {
        _newDesk(true, 1 ether);
        MockPool(BTC_POOL).setLevel(true, 870_000, 200);
        MockPool(BTC_POOL).setLevel(false, 890_000, 200);

        _fireBtc();
        _decide();

        assertEq(brain.lastPBookBps(), 8_800, "an observed book is reported exactly as observed");
    }

    // ── fan-out bounds and isolation ──────────────────────────────────────────

    function test_fanout_is_bounded_at_max() public {
        uint256 max = router.MAX_FANOUT();
        for (uint256 i; i < max + 8; ++i) {
            _newDesk(true, 1 ether);
        }

        _fireBtc();
        _decide();

        assertEq(router.armedDesks().length, max + 8, "all desks are armed");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, max, "but only MAX_FANOUT are served");
        assertEq(brain.requestCount(), 1, "still one verdict");
    }

    function test_a_reverting_desk_does_not_break_the_others() public {
        MockDeskForRouter bad = _newDesk(true, 1 ether);
        MockDeskForRouter good = _newDesk(true, 1 ether);
        bad.setRevertModes(false, true, true, false);

        _fireBtc();
        _decide();

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
        _decide();

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

        _fireBtc();

        // Credit is only spent when the committee is actually asked, which is now the decision
        // wake-up rather than the open.
        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(broke), BTC_MARKET_ID, "NO_CREDIT");
        _decide();

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
        _decide();

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
        _decide();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        // (0.87 + 0.89) / 2 = 0.88 of one collateral unit.
        assertEq(d.lastPBookBps(), 8_800, "book mid in bps");
        assertTrue(d.lastBookObserved(), "both sides quoted, so the mid was observed");
        assertEq(d.lastProbUpBps(), 6_200, "the committee's number is passed through");
        assertEq(d.lastVerdictMarketId(), BTC_MARKET_ID, "for this market");
    }

    function test_pBook_uses_the_one_side_that_exists() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).setLevel(true, 640_000, 100);

        _fireBtc();
        _decide();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(5000));

        assertEq(d.lastPBookBps(), 6_400, "a one-sided book is still information");
        assertTrue(d.lastBookObserved(), "a resting bid is somebody's real opinion");
    }

    /// @dev The correction. This used to report 5000, and a desk comparing an 8800 verdict against
    /// that fallback measures a 38-point edge against a price nobody quoted -- then stakes 38% of
    /// its equity on it. An empty book is the absence of a price, not a price of 50%, and the desk
    /// is now told which of the two it has.
    function test_pBook_reports_unobserved_when_the_book_is_empty() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).clearBook();

        _fireBtc();
        _decide();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertFalse(d.lastBookObserved(), "nobody quoted, so nothing was observed");
        assertEq(d.lastPBookBps(), 0, "and no number is invented to stand in for the one that is missing");
    }

    function test_pBook_reports_unobserved_when_the_pool_reverts() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);
        MockPool(BTC_POOL).setRevertOnBook(true);

        _fireBtc();
        _decide();

        vm.prank(address(brain));
        router.onVerdict(BTC_MARKET_ID, _verdict(6200));

        assertFalse(d.lastBookObserved(), "a broken pool is not a book, and must not take the fan-out down");
        assertEq(d.lastPBookBps(), 0, "nor does it produce a reading");
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
        _decide();

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
        _decide();
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
        _decide();
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
        _decide();

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
        _decide();

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
        assertEq(router.settlementQueueLength(), 0, "nothing queued");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "no one-shot recorded");
    }

    function test_with_a_keeper_every_venue_market_gets_a_oneshot() public {
        MockKeeperForRouter keeper = _attachKeeper();

        // No desks at all: these two windows are pure public good.
        _fireBtc();
        _fireEth();

        assertEq(precompile.subscriptionCount(), 2, "venue subscription plus one shared one-shot");
        assertEq(router.scheduleIdAt(DUE_MS), 2, "the one-shot is recorded");

        LucidRouter.Pending[] memory due = router.pendingSettlements();
        assertEq(due.length, 2, "both markets queued for upkeep");
        assertEq(due[0].marketId, BTC_MARKET_ID, "BTC");
        assertEq(due[1].marketId, ETH_MARKET_ID, "ETH");
        assertEq(uint256(due[0].dueAtSec), uint256(EXPIRY) + 5, "both due at the same second");
        assertEq(uint256(due[1].dueAtSec), uint256(EXPIRY) + 5, "which is why they share one wake-up");
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
        _decide();
        // With a keeper attached the settlement is booked at creation for the whole venue, and the
        // desks reach it again at the decision point. Once, not twice: a second queue entry would
        // settle every holder twice in the same firing.
        assertEq(router.settlementQueueLength(), 1, "a served market is queued exactly once");

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
        _decide();
        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the desk settled exactly as it always has");
        assertEq(d.lastSettledMarketId(), BTC_MARKET_ID, "for its market");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "positions closed out");
        assertEq(router.settlementQueueLength(), 0, "the queue drained");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "the one-shot slot was freed with it");
        assertEq(precompile.subscriptionCount(), 3, "the venue subscription and this window's two wake-ups");
    }

    function test_relay_is_drained_at_settlement() public {
        MockKeeperForRouter keeper = _attachKeeper();
        MockRelayForRouter exits = _attachRelay();
        exits.watch(keeper);
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _decide();
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
        _decide();

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
        _decide();
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

    // -- own-series rolling ---------------------------------------------------
    //
    // DreamDEX's short-cadence market creation stops when the creator the SDK advertises runs out
    // of float, and it has. The series contract rolls a window of this protocol's own when that
    // happens; the router's whole part in it is to hand over two facts -- the venue created a
    // market, and a window just closed -- and to survive whatever the series does with them.

    function test_no_series_leaves_scheduling_and_settlement_unchanged() public {
        assertEq(router.series(), address(0), "no series by default");
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(precompile.subscriptionCount(), 2, "the venue subscription and one decision one-shot");

        _decide();
        assertEq(precompile.subscriptionCount(), 3, "and the settlement one-shot the position obliges");
        assertEq(router.settlementQueueLength(), 1, "queued exactly as before");

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the desk settled exactly as it always has");
        assertEq(d.lastSettledMarketId(), BTC_MARKET_ID, "for its market");
        assertEq(router.settlementQueueLength(), 0, "the queue drained");
        assertEq(router.scheduleIdAt(DUE_MS), 0, "the one-shot slot was freed with it");
        assertEq(precompile.subscriptionCount(), 3, "and no extra subscription was taken out");
    }

    function test_both_series_hooks_are_driven() public {
        MockSeriesForRouter s = _attachSeries();
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(s.venueMarketCalls(), 1, "a venue market is the only evidence its scheduler is alive");
        assertEq(s.lastVenueMarketId(), BTC_MARKET_ID, "for the window the venue created");
        assertEq(s.lastVenueInterval(), 60, "carrying the cadence it was rolled at");
        assertEq(s.tickCalls(), 0, "and nothing ticks before the window closes");

        _decide();
        assertEq(s.venueMarketCalls(), 1, "a decision wake-up is not a venue market, and is not reported as one");
        assertEq(s.tickCalls(), 0, "nor is it a settlement");

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(s.tickCalls(), 1, "the settlement schedule is the roll's clock");
        assertEq(s.lastTickMarketId(), BTC_MARKET_ID, "for the settled window");
        assertEq(d.settlementCalls(), 1, "and the desk that paid for the firing still settled");
        assertGe(s.lastTickGas(), 61_600_000, "handed enough gas for the 61.6M a live roll measured");
    }

    /// @dev Pins where the heartbeat is taken. A window this router is too late to serve is still
    /// proof that the venue's own scheduler is running, and the series must be told so -- otherwise
    /// a venue that is healthy but slightly ahead of us would read as an outage.
    function test_series_sees_a_market_the_router_is_too_late_to_serve() public {
        MockSeriesForRouter s = _attachSeries();
        _newDesk(true, 1 ether);

        vm.warp(EXPIRY + 60);

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(0), BTC_MARKET_ID, "EXPIRED");
        _fireBtc();

        assertEq(s.venueMarketCalls(), 1, "the heartbeat is taken before the window is judged");
        assertEq(router.settlementQueueLength(), 0, "and the window itself is still declined");
    }

    /// @dev The series spends real money on a venue deployment this router does not own, so it is
    /// the collaborator most likely to break -- and it must never cost the desks that paid for this
    /// firing their settlement.
    function test_a_reverting_series_does_not_break_settlement() public {
        MockSeriesForRouter s = _attachSeries();
        s.setRevertOnCall(true);
        MockDeskForRouter d = _newDesk(true, 1 ether);

        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(s), BTC_MARKET_ID, "SERIES_FAILED");
        _fireBtc();
        assertEq(router.decisionQueueLength(), 1, "the market was served regardless");

        _decide();
        assertEq(router.settlementQueueLength(), 1, "and its settlement was booked");

        vm.warp(EXPIRY + 5);
        vm.expectEmit(true, true, false, true, address(router));
        emit LucidRouter.Skipped(address(s), BTC_MARKET_ID, "SERIES_FAILED");
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the desk still settled");
        assertEq(s.tickCalls(), 0, "and the series recorded nothing it did not do");

        // The other half of the guard, and the one `try` cannot cover: an address with no code.
        vm.warp(TRADING_START);
        vm.prank(owner);
        router.setSeries(stranger);

        _fireEth();
        _decide();
        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 2, "an EOA series is passed over and settlement is unharmed");
        assertEq(d.lastSettledMarketId(), ETH_MARKET_ID, "the second window");
    }

    function test_only_owner_can_set_series() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setSeries(address(1));

        assertEq(router.series(), address(0), "unchanged");

        vm.expectEmit(false, false, false, true, address(router));
        emit LucidRouter.SeriesSet(address(1));
        vm.prank(owner);
        router.setSeries(address(1));
        assertEq(router.series(), address(1), "the operator may attach one");

        vm.prank(owner);
        router.setSeries(address(0));
        assertEq(router.series(), address(0), "and detach it again");
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
        _decide();

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
        _decide();

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
        _decide();

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
        _decide();
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
        _decide();

        assertEq(precompile.subscriptionCount(), 3, "the venue log subscription and this window's two wake-ups");
        assertEq(precompile.subscriptionAt(0).gasLimit, router.HANDLER_GAS_LIMIT(), "venue log subscription");
        assertEq(precompile.subscriptionAt(1).gasLimit, router.HANDLER_GAS_LIMIT(), "decision one-shot");
        assertEq(precompile.subscriptionAt(2).gasLimit, router.HANDLER_GAS_LIMIT(), "settlement one-shot");
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
        _decide();
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

    // ── wake-ups are nudges, not keys ─────────────────────────────────────────
    //
    // Measured on chain, not reasoned about. The router booked one-shots with
    // `scheduleSubscriptionAtTimestamp` and filed the work under the exact millisecond it asked
    // for. The chain does not fire `Schedule` with that millisecond: a one-shot matches "at or
    // after `eventTopics[1]`", and what it delivers is the instant it really emitted at. Decoded
    // from a live Shannon handler transaction
    // (0x5775871466afcd7f10e9e7fb2037404f4ced0906f74585856788bc4bd09998ad) a wake-up booked for a
    // whole second came back carrying 1788719250073. Every lookup missed. Over twenty-five minutes
    // the deployed router logged 56 `MarketSeen`, 56 `SettlementScheduled` and 10
    // `DecisionScheduled` — and zero verdicts, zero skips, zero settlements, at 72_254 gas per
    // firing, which is the early-return path. Settlement had never run once since first deploy.
    //
    // Work is drained by the clock now. What follows fires wake-ups that do not match, that arrive
    // before anything is due, that arrive an hour after everything is, and that arrive with more
    // work behind them than one handler can hold.

    /// @dev The fixture for the whole section. If this ever passes with the two timestamps equal,
    /// every other test here is testing a chain that does not exist.
    function test_the_default_firing_delivers_a_timestamp_that_was_never_requested() public {
        MockScheduleRecorder recorder = new MockScheduleRecorder();

        precompile.fireSchedule(address(recorder), DUE_MS);

        assertEq(recorder.calls(), 1, "delivered");
        assertEq(DUE_MS % 1000, 0, "every instant this router books is a whole second times 1000");
        assertTrue(recorder.lastTsMillis() != DUE_MS, "and the chain does not echo the request back");
        assertEq(recorder.lastTsMillis(), DUE_MS + 73, "it delivers the instant it actually emitted at");
        assertEq(recorder.lastTsMillis() % 1000, 73, "which is why a keyed lookup missed every single time");
        assertEq(precompile.SCHEDULE_SKEW_MS(), 73, "the offset decoded from the Shannon transaction");

        // The literal topic1 from that transaction, so the fixture is the measurement rather than a
        // rounding of it.
        precompile.fireScheduleAt(address(recorder), 1_788_719_250_073);
        assertEq(recorder.lastTsMillis(), 1_788_719_250_073, "and an exact instant passes through untouched");
    }

    function test_a_decision_fires_when_the_wakeup_carries_a_later_timestamp() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        assertEq(router.decisionQueueLength(), 1, "queued at creation");
        assertEq(router.scheduleIdAt(DECISION_MS), 2, "against a one-shot booked for the halfway instant");

        vm.warp(DECISION_TS);
        // Deliberately not DECISION_MS. Nothing here may depend on that value coming back.
        _fireScheduleAt(DECISION_MS + 73);

        assertEq(brain.requestCount(), 1, "the committee was asked anyway");
        assertEq(brain.lastMarketId(), BTC_MARKET_ID, "about the right window");
        assertEq(router.decisionQueueLength(), 0, "and the entry left the queue");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 1, "the desk is on the hook");
        assertEq(
            router.gasCreditOf(address(d)),
            1 ether - (brain.fee() + router.SETTLEMENT_BUDGET()),
            "and it paid its share of the committee the wake-up went and bought"
        );
    }

    function test_a_settlement_fires_when_the_wakeup_carries_a_later_timestamp() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _decide();
        assertEq(router.settlementQueueLength(), 1, "queued at the decision point");

        vm.warp(EXPIRY + 5);
        _fireScheduleAt(DUE_MS + 73);

        assertEq(d.settlementCalls(), 1, "settled anyway");
        assertEq(d.lastSettledMarketId(), BTC_MARKET_ID, "the right window");
        assertEq(router.settlementQueueLength(), 0, "and the entry left the queue");
        assertEq(router.interestedIn(BTC_MARKET_ID).length, 0, "the position is closed out");
    }

    /// @dev The general form: the topic is not merely offset, it is irrelevant. A firing that
    /// claims to be from another day still drains whatever the clock says is due, because that is
    /// what makes a missed or coalesced wake-up survivable rather than fatal.
    function test_a_wakeup_carrying_an_unrelated_timestamp_still_drains_what_is_due() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _decide();

        vm.warp(EXPIRY + 3600);
        _fireScheduleAt(1);

        assertEq(d.settlementCalls(), 1, "the work was found by its own due second, not by the topic");
    }

    function test_an_early_wakeup_drains_nothing_and_leaves_the_work_queued() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _decide();
        assertEq(router.settlementQueueLength(), 1, "one settlement owed");

        // One second short of due, and carrying the settlement instant exactly — the strongest form
        // of the wrong answer, a matching key with the clock not there yet. The clock wins.
        vm.warp(EXPIRY + 4);
        vm.recordLogs();
        _fireScheduleAt(DUE_MS);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(d.settlementCalls(), 0, "nothing was settled early");
        assertEq(router.settlementQueueLength(), 1, "and the entry is still queued");
        assertEq(
            _countTopic(logs, keccak256("DrainStopped(bool,uint256,uint256,string)")),
            0,
            "a queue with nothing due in it is not a backlog and must not be reported as one"
        );

        vm.warp(EXPIRY + 5);
        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "the next firing takes it, which is the self-healing part");
        assertEq(router.settlementQueueLength(), 0, "and the queue empties");
    }

    /// @dev A handler runs inside a fixed frame, so a backlog has to be bounded by construction.
    /// The bound is only correct if what one firing declines is exactly what the next one takes —
    /// once each, nothing lost, nothing done twice.
    function test_a_backlog_larger_than_MAX_DRAIN_is_drained_across_firings() public {
        assertEq(router.MAX_DRAIN(), 8, "the per-firing cap this protocol ships");

        MockRecordingKeeper keeper = new MockRecordingKeeper();
        vm.prank(owner);
        router.setKeeper(address(keeper));

        uint256 n = 12;
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = bytes32(0x20000 + i);
            _fireMarket(uint256(ids[i]), TRADING_START, 60);
        }

        assertEq(router.settlementQueueLength(), n, "every window is queued for upkeep");
        assertEq(uint256(router.marketOf(ids[0]).intervalSec), 60, "and the synthetic log decodes as a 60s window");
        assertEq(uint256(router.marketOf(ids[0]).expiry), uint256(EXPIRY), "closing when the fixture closes");

        vm.warp(EXPIRY + 5);

        vm.expectEmit(false, false, false, true, address(router));
        emit LucidRouter.DrainStopped(false, 8, 4, "MAX_DRAIN");
        _fireSchedule(DUE_MS);

        assertEq(keeper.seenCount(), 8, "one firing takes the cap and no more");
        assertEq(router.settlementQueueLength(), 4, "and the remainder stays queued rather than being dropped");

        _fireSchedule(DUE_MS);

        assertEq(keeper.seenCount(), n, "the next firing finishes the backlog");
        assertEq(router.settlementQueueLength(), 0, "with nothing left");

        bytes32[] memory seen = keeper.seen();
        for (uint256 i; i < n; ++i) {
            assertEq(_countIn(seen, ids[i]), 1, "every window was settled exactly once across the two firings");
        }
    }

    /// @dev The queues are appended in due order within one cadence and are not globally ordered
    /// across four of them. A drain that stopped at the first entry not yet due would strand a
    /// minute-long window behind an hour-long one for the whole hour.
    function test_mixed_cadences_queued_out_of_order_are_all_drained() public {
        assertEq(router.MAX_SCAN(), 16, "the scan window this protocol ships");

        MockRecordingKeeper keeper = new MockRecordingKeeper();
        vm.prank(owner);
        router.setKeeper(address(keeper));

        bytes32 slow = bytes32(uint256(0x31000));
        bytes32 fastA = bytes32(uint256(0x31001));
        bytes32 fastB = bytes32(uint256(0x31002));

        // The hour-long window is created first, so it sits at the front of the queue while coming
        // due an hour after the two behind it.
        _fireMarket(uint256(slow), TRADING_START, 3600);
        _fireMarket(uint256(fastA), TRADING_START, 60);
        _fireMarket(uint256(fastB), TRADING_START, 60);

        assertEq(router.settlementQueueLength(), 3, "all three queued");
        assertEq(router.pendingSettlements()[0].marketId, slow, "the slow one is at the front");
        assertEq(uint256(router.marketOf(slow).intervalSec), 3600, "and it really is an hour long");

        vm.warp(TRADING_START + 65);
        _fireSchedule((uint256(TRADING_START) + 65) * 1000);

        assertEq(keeper.seenCount(), 2, "both short windows were reached past the long one");
        assertEq(_countIn(keeper.seen(), fastA), 1, "the first");
        assertEq(_countIn(keeper.seen(), fastB), 1, "the second");
        assertEq(router.settlementQueueLength(), 1, "and the long one is left exactly where it was");
        assertEq(router.pendingSettlements()[0].marketId, slow, "untouched");

        vm.warp(TRADING_START + 3605);
        _fireSchedule((uint256(TRADING_START) + 3605) * 1000);

        assertEq(keeper.seenCount(), 3, "and it is taken when its own second arrives");
        assertEq(_countIn(keeper.seen(), slow), 1, "once");
        assertEq(router.settlementQueueLength(), 0, "with nothing left over");
    }

    /// @dev One market's halfway point is another's expiry, so both kinds of work land on the same
    /// firing. Decisions go first — the order the timestamp-keyed version ran them in, and the
    /// order that keeps a settlement from ever reaching the committee.
    function test_one_firing_drains_due_decisions_before_due_settlements() public {
        MockOrderedDesk desk = new MockOrderedDesk();
        _admitDesk(address(desk), 1 ether);

        _fireBtc();
        _decide();
        assertEq(router.settlementQueueLength(), 1, "the fixture window owes a settlement");

        // A second window whose decision point lands on exactly the second the first one settles.
        bytes32 late = bytes32(uint256(0x41000));
        _fireMarket(uint256(late), uint64(uint256(EXPIRY) + 5 - 30), 60);
        assertEq(router.decisionQueueLength(), 1, "and a decision comes due on that same second");

        vm.warp(EXPIRY + 5);
        vm.recordLogs();
        _fireSchedule(DUE_MS);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 priced = _indexOf(logs, address(router), keccak256("VerdictRequested(bytes32,uint256,uint256)"));
        uint256 settled = _indexOf(logs, address(desk), keccak256("Settled(bytes32)"));

        assertTrue(priced != type(uint256).max, "the due decision was taken");
        assertTrue(settled != type(uint256).max, "and the due settlement was taken");
        assertLt(priced, settled, "decisions before settlements, in one firing");

        assertEq(brain.lastMarketId(), late, "the committee was asked about the new window");
        assertEq(desk.settlementCalls(), 1, "and the desk was settled in the old one");
        assertEq(router.decisionQueueLength(), 0, "the decision queue drained");
        assertEq(router.settlementQueueLength(), 1, "and the new window's own settlement is queued behind it");
    }

    /// @dev A frame with nothing left to give must end the pass *before* the entry is consumed.
    /// Taking it and then failing to do it is the one outcome a bounded drain may not produce.
    function test_a_drain_that_runs_out_of_gas_stops_before_taking_the_work_and_says_so() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _decide();

        vm.warp(EXPIRY + 5);
        assertEq(router.settlementQueueLength(), 1, "one settlement due");

        // At the reserve there is nothing left to hand a callee, by construction.
        vm.expectEmit(false, false, false, true, address(router));
        emit LucidRouter.DrainStopped(false, 0, 1, "NO_GAS");
        assertTrue(_callSchedule(router.GAS_RESERVE()), "the handler reported rather than running out");

        assertEq(d.settlementCalls(), 0, "nothing was half-done");
        assertEq(router.settlementQueueLength(), 1, "and the entry is still queued rather than consumed and lost");

        _fireSchedule(DUE_MS);

        assertEq(d.settlementCalls(), 1, "a firing with a real frame finishes it");
        assertEq(router.settlementQueueLength(), 0, "and the queue empties");
    }

    /// @dev The confusion that must stay impossible now that both kinds of work are found by the
    /// same clock rather than by two different keys.
    function test_a_settlement_is_never_drained_as_a_decision() public {
        MockDeskForRouter d = _newDesk(true, 1 ether);

        _fireBtc();
        _decide();

        assertEq(brain.requestCount(), 1, "the window was priced once, at its decision point");
        assertEq(router.decisionQueueLength(), 0, "and its decision entry is gone");
        assertEq(router.settlementQueueLength(), 1, "only a settlement is owed now");

        vm.warp(EXPIRY + 5);
        vm.recordLogs();
        _fireSchedule(DUE_MS);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(d.settlementCalls(), 1, "the window was settled");
        assertEq(brain.requestCount(), 1, "and no second verdict was bought for a window that had resolved");
        assertEq(_countTopic(logs, keccak256("VerdictRequested(bytes32,uint256,uint256)")), 0, "nothing was priced");
        assertEq(
            _countTopic(logs, keccak256("DecisionScheduled(bytes32,uint256,uint256)")),
            0,
            "and nothing was queued to be"
        );
        assertEq(
            _countTopic(logs, keccak256("Debited(address,bytes32,uint256)")),
            0,
            "nobody paid a committee fee at settlement"
        );
    }

    /// @dev The self-healing case end to end: nothing fires until long after both instants have
    /// passed. Both entries come due together, the settlement runs, and the decision — for a window
    /// that has already resolved — is refused out loud rather than paid for.
    function test_a_late_firing_settles_a_window_without_pricing_the_decision_it_missed() public {
        MockKeeperForRouter keeper = _attachKeeper();
        MockDeskForRouter d = _newDesk(true, 1 ether);

        // With a keeper attached both wake-ups are booked at creation, so both entries are on the
        // queues before anything fires at all.
        _fireBtc();
        assertEq(router.decisionQueueLength(), 1, "a decision is owed");
        assertEq(router.settlementQueueLength(), 1, "and a settlement");

        vm.warp(EXPIRY + 5);
        vm.recordLogs();
        _fireScheduleAt(DUE_MS + 73);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(brain.requestCount(), 0, "an expired window is never priced");
        assertEq(_countReason(logs, address(0), "EXPIRED"), 1, "and the refusal is named");
        assertEq(d.settlementCalls(), 0, "no desk ever held it, so no desk is settled");
        assertEq(keeper.keepCalls(), 1, "but the venue-wide upkeep still ran");
        assertEq(router.decisionQueueLength(), 0, "the decision queue drained");
        assertEq(router.settlementQueueLength(), 0, "and so did the settlement queue");
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

    /// @dev Attaches the own-series roller fed on venue markets and at settlement.
    function _attachSeries() internal returns (MockSeriesForRouter s) {
        s = new MockSeriesForRouter();
        vm.prank(owner);
        router.setSeries(address(s));
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

    /// @dev Delivers the decision wake-up the router booked at creation: warps to the halfway
    /// point of the fixture window and fires the precompile's `Schedule` event for that instant.
    /// Nothing is asked of the committee before this runs.
    function _decide() internal {
        vm.warp(DECISION_TS);
        _fireSchedule(DECISION_MS);
    }

    /// @dev Delivers a wake-up the way the chain delivers one. The timestamp that arrives is the
    /// instant the precompile actually emitted at — `requestedMs + MockPrecompile.SCHEDULE_SKEW_MS`
    /// — and so is never the instant anything was booked for. Every scheduled-path test in this file
    /// runs through here, which is the point: the polite version of this helper is what let a
    /// timestamp-keyed router pass a full suite and then no-op on chain for its entire life.
    function _fireSchedule(uint256 requestedMs) internal {
        precompile.fireSchedule(address(router), requestedMs);
    }

    /// @dev Delivers a wake-up carrying exactly `tsMillis`, for what a fixed skew cannot express:
    /// one that arrives before the work is due, one that arrives an hour after the chain unpaused,
    /// one firing standing in for two instants.
    function _fireScheduleAt(uint256 tsMillis) internal {
        precompile.fireScheduleAt(address(router), tsMillis);
    }

    /// @dev Delivers a wake-up inside a frame of exactly `gasCap`, which is the only way to reach
    /// the branch where a drain runs out of budget with entries still due.
    function _callSchedule(uint256 gasCap) internal returns (bool ok) {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = LucidTypes.TOPIC_SCHEDULE;
        topics[1] = bytes32(block.timestamp * 1000 + precompile.SCHEDULE_SKEW_MS());

        bytes memory payload = abi.encodeWithSelector(ISomniaEventHandler.onEvent.selector, PRECOMPILE, topics, bytes(""));

        vm.prank(PRECOMPILE);
        (ok,) = address(router).call{gas: gasCap}(payload);
    }

    /// @dev A synthetic window, made by rewriting the clock inside a real captured log so the bytes
    /// still travel through `MarketDecoder` exactly as a chain log would. The venue, the pool and
    /// the asset stay the fixture's; only the id and the window move. `intervalSec` is derived by
    /// the decoder from `expiry - tradingStart`, which is why both words are rewritten.
    function _fireMarket(uint256 marketId, uint64 tradingStart, uint32 intervalSec) internal {
        bytes32[] memory topics = _btcTopics();
        topics[1] = bytes32(marketId);

        bytes memory data = _btcData();
        _setWord(data, TRADING_START_WORD, tradingStart);
        _setWord(data, EXPIRY_WORD, uint256(tradingStart) + intervalSec);

        vm.prank(PRECOMPILE);
        router.onEvent(MODULE, topics, data);
    }

    /// @dev Overwrite one 32-byte word of a captured log body in place.
    function _setWord(bytes memory data, uint256 index, uint256 value) internal pure {
        uint256 offset = 32 + index * 32;
        assembly {
            mstore(add(data, offset), value)
        }
    }

    /// @dev The position of the first log with this signature from this emitter, or `type(uint256).max`.
    /// @dev Ordering between two different emitters is the only way to observe that decisions are
    /// drained before settlements, which is what keeps the two from ever being confused.
    function _indexOf(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) return i;
        }
        return type(uint256).max;
    }

    /// @dev Exactly one occurrence of `value` in `list`. The witness for "nothing was lost": a
    /// bounded drain is only correct if what it left behind is what the next firing takes, once.
    function _countIn(bytes32[] memory list, bytes32 value) internal pure returns (uint256 count) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == value) ++count;
        }
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
