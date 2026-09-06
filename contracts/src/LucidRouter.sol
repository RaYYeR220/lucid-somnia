// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SomniaEventHandler} from "@somnia/reactivity/SomniaEventHandler.sol";
import {SomniaExtensions} from "@somnia/reactivity/interfaces/SomniaExtensions.sol";

import {ILucidDesk, ILucidBrain} from "./interfaces/ILucid.sol";
import {IBinaryPool, IBinaryMarket} from "./interfaces/IDreamDex.sol";
import {LucidTypes} from "./types/LucidTypes.sol";
import {MarketDecoder} from "./lib/MarketDecoder.sol";

/// @notice The slice of `LucidFactory` this contract reads: the copy-trade graph, and nothing else.
/// @dev Declared locally rather than imported so the router never depends on the factory's
/// implementation. The router holds the protocol's entire reactivity bond; a change to how leaders
/// are published must not be able to reach it.
interface IFactoryView {
    function followersOf(address leader) external view returns (address[] memory);
    function scaleOf(address leader, address follower) external view returns (uint16);
}

/// @notice The slice of `LucidKeeper` this contract drives: one call, and nothing else.
/// @dev Declared locally rather than imported for the same reason as `IFactoryView`. The keeper
/// runs upkeep on behalf of the entire venue, including markets this protocol has no stake in; the
/// router must be able to call it without taking on a dependency it would then have to trust.
interface ILucidKeeper {
    function keep(LucidTypes.MarketInfo calldata m) external;
}

/// @notice The slice of `LucidRelay` this contract drives: one call, and nothing else.
/// @dev Declared locally rather than imported for the same reason as `ILucidKeeper`. The relay is
/// an ownerless public good that serves any address on any venue, so the router must be able to
/// nudge it without taking on its implementation — including the EIP-712 machinery it carries,
/// which this contract has no business knowing about.
interface ILucidRelay {
    function relayUpTo(bytes32 marketId, uint256 max) external;
}

/// @notice The slice of `LucidSeries` this contract drives: two hooks, and nothing else.
/// @dev Declared locally rather than imported for the same reason as `ILucidKeeper`. The series
/// contract rolls this protocol's own short-cadence windows when the venue's creator runs out of
/// float and stops rolling its own — it spends money on an external venue deployment, and the
/// router must be able to wake it without taking on one line of that decision.
interface ILucidSeries {
    function onVenueMarket(LucidTypes.MarketInfo calldata m) external;
    function onTick(LucidTypes.MarketInfo calldata m) external;
}

/// @title LucidRouter
/// @notice The protocol's single subscriber to Somnia's on-chain reactivity, and the only contract
/// that ever talks to the precompile at `0x0100`.
///
/// @dev Why one router instead of a subscription per desk: `SomniaExtensions._subscribe` checks
/// `address(this).balance >= 32 ether` on the contract that calls it. Per-desk subscriptions would
/// therefore lock 32 SOMI per user, which is not a product. Concentrating every subscription here
/// means one bond serves everybody and desks never need to hold the chain's gas token at all.
///
/// @dev The hard rule in this file: **nothing reached from a handler may revert**. The chain
/// executes handlers as synthetic transactions, so a revert does not merely fail one desk's
/// action — it discards the whole fan-out for every other desk in the same firing, and the router
/// is still charged for the gas. Every external call below is therefore wrapped in `try`/`catch`
/// and given its own gas stipend, and every skipped desk is named in an event. A silent success is
/// worse than a loud refusal: a desk owner who cannot tell the difference between "nothing
/// happened" and "we decided not to" has no way to run this.
///
/// @dev The corollary, learned the expensive way: a skip reason has to name the component that
/// actually failed. A stipend too small for the callee produces a caught revert that is
/// indistinguishable from a broken callee, and a label that blames the callee sends whoever is
/// reading the log to debug the wrong contract. Hence `_stipend`, which sizes every budget against
/// what the frame can really give, and `"NO_GAS"`, which says plainly that the shortfall was ours.
contract LucidRouter is SomniaEventHandler, Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice How many armed desks one market firing may consider.
    /// @dev A handler runs inside a fixed gas limit, so the fan-out has to be bounded by
    /// construction rather than by hope. Thirty-two desks fit inside `HANDLER_GAS_LIMIT` even when
    /// several of them place orders — and where they do not, `_stipend` degrades the tail of the
    /// list into named skips rather than into a lost firing.
    uint256 public constant MAX_FANOUT = 32;

    /// @notice Callback gas provisioned for every subscription this router creates.
    ///
    /// @dev Measured on Shannon, not guessed: at 2_000_000 the chain charged for the handler and
    /// never executed it — no revert, no logs, no state change, indistinguishable from a market
    /// nobody wanted. 3M and 5M both worked. 8M was then shipped, and 8M was still too tight: one
    /// desk's `onVerdict` alone estimated at 1_314_773 on live state, because Somnia's gas schedule
    /// is nothing like mainnet's — a single SSTORE plus an event measures around 250_000 there.
    ///
    /// @dev The ceiling is deliberately generous rather than tight, because the billing is
    /// asymmetric. The subscription owner is charged for the gas a handler actually burns, so
    /// headroom that is never touched costs nothing; but a handler that runs out of gas is billed
    /// for the whole limit *and* loses the firing. An over-tight ceiling is therefore the expensive
    /// mistake and an over-wide one is free. Half of `MAXIMUM_HANDLER_GAS_LIMIT`, which is the hard
    /// cap `SomniaExtensions` enforces at subscribe time.
    uint64 public constant HANDLER_GAS_LIMIT = 100_000_000;

    /// @notice Priority fee offered to validators for handler execution.
    uint64 public constant HANDLER_PRIORITY_FEE = 1 gwei;

    /// @notice Fee ceiling for handler execution. Must clear the protocol's 6 gwei base floor.
    uint64 public constant HANDLER_MAX_FEE = 20 gwei;

    /// @notice The balance the precompile requires of a subscription owner.
    uint256 public constant SUBSCRIPTION_FLOOR = SomniaExtensions.SUBSCRIPTION_OWNER_MINIMUM_BALANCE;

    /// @notice What each served desk pre-pays towards its settlement wake-up.
    /// @dev A handler firing cost 0.003–0.01 SOMI in the live spikes; this is the top of that range.
    uint256 public constant SETTLEMENT_BUDGET = 0.01 ether;

    /// @notice Seconds after expiry at which the settlement one-shot fires.
    /// @dev The venue needs a moment to resolve the oracle question after a window closes, so the
    /// desks are woken slightly late rather than exactly on time.
    uint256 public constant SETTLEMENT_DELAY = 5;

    /// @notice How far into a window the committee is asked, as a fraction of the window in bps.
    ///
    /// @dev Halfway, and this is the whole point of asking at all. For these markets the strike IS
    /// the window's opening price, so at `tradingStart` spot equals strike exactly and "will it
    /// close above the strike" is a coin flip with no content. That is not a broken committee; it
    /// is an empty question, and a committee asked an empty question answers 50 — which is what
    /// every live verdict did, from three sources that agreed, on a 96ms-old spot of 7971580 for
    /// market 0x…1530a. The desk then correctly refused `LowEdge` against a 50/50 book. Everything
    /// worked. Nothing was worth asking.
    ///
    /// @dev Waiting lets the price move away from the strike, so by the time the committee is asked
    /// there is a real distance to reason about. It costs one extra wake-up per market, which the
    /// router pays for — hence the guard in `_onMarketCreated` that books one only when some desk
    /// has already said it wants the window.
    uint256 public constant DECISION_POINT_BPS = 5_000;

    /// @notice The earliest point in a window the operator may move the decision to.
    /// @dev Below a tenth of the window, spot has barely left the strike and the question is the
    /// empty one again.
    uint16 public constant MIN_DECISION_POINT_BPS = 1_000;

    /// @notice The latest point in a window the operator may move the decision to.
    /// @dev Above four fifths, the brain's own `requiredSlack()` refuses almost every window and the
    /// router would be buying wake-ups to be told no.
    uint16 public constant MAX_DECISION_POINT_BPS = 8_000;

    /// @notice The gas this contract keeps for itself, never offered to a callee.
    /// @dev Held back so the loop can finish and still emit what happened. A handler that runs out
    /// of gas mid-fan-out reports nothing at all, which is the one outcome worse than a skipped desk.
    uint256 public constant GAS_RESERVE = 2_000_000;

    /// @notice Ceiling on the gas stipend for a desk's `preCheck`.
    /// @dev It is a view over the desk's own policy; anything that needs more than this is either
    /// broken or hostile, and either way must not be allowed to spend the fan-out's budget.
    uint256 public constant PRECHECK_GAS = 1_500_000;

    /// @notice Ceiling on the gas stipend for a desk call that trades or settles.
    /// @dev The stipend, not `try`/`catch`, is what actually contains a runaway desk: a reverting
    /// call returns its gas, but a looping one would otherwise consume 63/64 of everything left.
    /// @dev Eight million, not one, because one was measured wrong: a live `onVerdict` estimated at
    /// 1_314_773 against real chain state and every call in that window was cut off mid-flight.
    uint256 public constant DESK_GAS = 8_000_000;

    /// @notice Ceiling on the gas stipend for reading one side of a pool's book.
    uint256 public constant BOOK_GAS = 1_000_000;

    /// @notice A follower may mirror at most the leader's own size.
    uint16 public constant MAX_SCALE_BPS = 10_000;

    /// @notice Ceiling on the gas stipend for the venue-wide upkeep pass over one settled market.
    /// @dev The keeper makes up to five external calls into contracts this protocol does not own.
    /// It is a public good, not a priority: it runs after every desk in the firing has been
    /// settled, and it is capped so it can never spend what those desks paid for.
    uint256 public constant KEEPER_GAS = 8_000_000;

    /// @notice Ceiling on the gas stipend for draining one market's pre-signed exits after it settles.
    /// @dev Redemption is a token transfer per entry on a venue contract this protocol does not
    /// own, so the batch below is the expensive tenant of a settlement firing. It is still capped:
    /// the desks paid for this firing, and an auto-redeem that starved them would be a worse deal
    /// than no auto-redeem at all.
    uint256 public constant RELAY_GAS = 12_000_000;

    /// @notice How many pre-signed exits one settlement firing redeems.
    /// @dev The relay's own queue holds up to 64, which was measured at roughly 16.5M gas — twice
    /// what a handler is given. Sixteen fits inside `RELAY_GAS`, and the remainder stays queued for
    /// anyone to finish, because relaying is permissionless.
    uint256 public constant RELAY_BATCH = 16;

    /// @notice Ceiling on the gas stipend for the own-series roll considered after a window settles.
    /// @dev A live `triggerRoll` measured 61.6M gas on Shannon — by far the largest single call this
    /// router makes, and the reason `HANDLER_GAS_LIMIT` is 100M rather than something tighter. The
    /// ceiling sits above the measurement because a roll cut off mid-flight is charged for in full
    /// and rolls nothing, while headroom that is never touched costs nothing at all.
    uint256 public constant SERIES_GAS = 70_000_000;

    /// @dev How many settled windows of per-asset history are kept as committee evidence.
    /// Matches `PromptLib.MAX_OUTCOMES`; older windows stop being informative quickly.
    uint256 internal constant MAX_RECENT = 5;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev What a desk says it did, so followers can mirror it. Written by the desk during its own
    /// `onVerdict` and consumed by the copy fan-out immediately afterwards.
    struct Trade {
        uint8 kind;
        uint256 stake;
    }

    /// @dev A per-asset ring of settled window outcomes, newest written at `next`.
    struct History {
        uint16[MAX_RECENT] slots;
        uint8 filled;
        uint8 next;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The venue this router serves. Markets from any other venue are ignored.
    bytes32 public venue;

    /// @notice The DreamDEX module whose `MarketCreated` logs are subscribed to.
    address public venueModule;

    /// @notice The live log-subscription id, or zero before the first `armVenue`.
    uint256 public venueSubscriptionId;

    /// @notice The agent-committee wrapper that prices markets.
    address public brain;

    /// @notice The desk factory, and the source of truth for the copy-trade graph.
    address public factory;

    /// @notice The venue-wide upkeep runner, or zero to serve only this protocol's own desks.
    /// @dev Attaching a keeper widens what the router pays for: with one set, every market on the
    /// venue gets a settlement wake-up, not just the ones a desk took a position in. That is the
    /// point — DreamDEX's upkeep calls are permissionless and effectively nobody runs them, and
    /// this router is already awake for every market the venue creates.
    address public keeper;

    /// @notice The auto-redeem relay woken after a window settles, or zero to leave exits alone.
    /// @dev A winning position on DreamDEX does not pay itself out, and only the venue's own web app
    /// auto-claims — for its own users. The relay holds exits their owners signed in advance, and it
    /// needs somebody awake at settlement to run them. This router already is.
    address public relay;

    /// @notice The own-series roller woken on venue markets and at settlement, or zero to depend
    /// entirely on the venue's own scheduler.
    /// @dev DreamDEX's short-cadence market creation stops when the creator the SDK advertises runs
    /// out of float, and it has. With a series attached this router feeds that contract the two
    /// facts it needs — that the venue is still creating markets, and that a window just closed —
    /// and it decides for itself whether to roll one of ours. Detaching it restores the previous
    /// behaviour immediately.
    address public series;

    /// @notice How far into a window the committee is asked, in bps of the window length.
    /// @dev Settable so the operator can retune it against what the venue's price series actually
    /// does without redeploying the contract that holds the bond. Bounded on both sides, because a
    /// value near either end reproduces one of the two failures this parameter exists to avoid.
    // casting to 'uint16' is safe because `DECISION_POINT_BPS` is a literal 5000, and every value
    // this field can later take is bounded by `setDecisionPoint` to at most 8000.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint16 public decisionPointBps = uint16(DECISION_POINT_BPS);

    /// @notice Prepaid desk credit held by this contract. Not the operator's money.
    uint256 public totalGasCredit;

    /// @notice Whether an address was registered as a desk.
    mapping(address desk => bool) public isDesk;

    /// @notice Whether a registered desk currently wants to be considered for new markets.
    mapping(address desk => bool) public deskArmed;

    /// @notice The one-shot subscription id serving a wake-up millisecond, or zero.
    /// @dev Shared by decision and settlement wake-ups on purpose: the chain fires one `Schedule`
    /// event per millisecond whatever the router queued for it, so a second subscription at the
    /// same instant would be a second bill for the same wake-up.
    mapping(uint256 tsMillis => uint256) public scheduleIdAt;

    address[] internal _deskList;
    mapping(address desk => uint256) internal _gasCredit;
    mapping(bytes32 marketId => LucidTypes.MarketInfo) internal _markets;
    mapping(bytes32 marketId => address[]) internal _interested;
    /// @dev Windows to settle at a millisecond. Kept in its own mapping from `_decisionAt` rather
    /// than tagged into one list, because the two wake-ups do opposite things to a desk's position
    /// — one opens it, one closes it — and a settlement mistaken for a decision would ask a
    /// committee to price a window that has already resolved.
    mapping(uint256 tsMillis => bytes32[]) internal _dueAt;
    /// @dev Windows to ask the committee about at a millisecond. See `_dueAt`.
    mapping(uint256 tsMillis => bytes32[]) internal _decisionAt;
    /// @dev Whether a window's settlement wake-up is already booked. A market can reach
    /// `_scheduleSettlement` twice — once from the keeper's venue-wide pass at creation, once from
    /// the desks' own path at the decision point — and a second queue entry would settle every
    /// holder twice in the same firing.
    mapping(bytes32 marketId => bool) internal _settlementBooked;
    /// @dev Whether a window's decision wake-up is already booked. The venue emits one
    /// `MarketCreated` per market, but a redelivered log must not buy a second wake-up and then
    /// charge every desk a second committee fee for the same window.
    mapping(bytes32 marketId => bool) internal _decisionBooked;
    mapping(address desk => mapping(bytes32 marketId => Trade)) internal _lastTrade;
    mapping(bytes32 assetKey => History) internal _history;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The router holds less than the bond the precompile requires of a subscriber.
    /// @dev Raised in place of the library's opaque `InsufficientBalance()` so an operator arming
    /// the venue is told the exact shortfall rather than left to guess at it.
    error RouterUnderfunded(uint256 have, uint256 need);
    /// @notice Only the configured brain may deliver a verdict.
    error NotBrain();
    /// @notice Only the factory or the owner may register desks.
    error NotFactory();
    /// @notice A desk's armed flag may only be set by that desk.
    error NotDesk();
    /// @notice The address is not a registered desk.
    error UnknownDesk(address desk);
    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice A desk must be a contract; an account with no code cannot be driven.
    error NotAContract(address account);
    /// @notice The requested sweep would dip into desks' prepaid credit.
    error CreditsLocked(uint256 available, uint256 requested);
    /// @notice The sweep recipient rejected the transfer.
    error SweepFailed();
    /// @notice A self-call entry point was reached from outside.
    error NotSelf();
    /// @notice The requested decision point falls outside the band the router will schedule in.
    error BadDecisionPoint(uint16 bps);

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event VenueArmed(bytes32 venueId, uint256 subscriptionId);
    event MarketSeen(bytes32 indexed marketId, uint32 intervalSec, bytes32 assetKey);
    event VerdictRequested(bytes32 indexed marketId, uint256 fee, uint256 deskCount);
    event SettlementScheduled(bytes32 indexed marketId, uint256 tsMillis, uint256 subscriptionId);
    /// @notice When this router will ask the committee about a window, published so the timing is
    /// auditable on chain rather than inferred from when a verdict happened to arrive.
    event DecisionScheduled(bytes32 indexed marketId, uint256 tsMillis, uint256 subscriptionId);
    event DecisionPointSet(uint16 bps);
    /// @notice Work that was not done, and why.
    /// @dev A zero `desk` means the whole fan-out for that market was skipped rather than one
    /// participant. This event is the protocol's answer to "why did nothing happen", and there is
    /// no path in this contract that declines to act without emitting it.
    event Skipped(address indexed desk, bytes32 indexed marketId, string reason);
    event DeskRegistered(address indexed desk);
    event DeskArmed(address indexed desk, bool on);
    event ToppedUp(address indexed desk, uint256 amount, uint256 balance);
    event Debited(address indexed desk, bytes32 indexed marketId, uint256 amount);
    event TradeReported(address indexed desk, bytes32 indexed marketId, uint8 kind, uint256 stake);
    event BrainUpdated(address brain);
    event FactoryUpdated(address factory);
    event KeeperSet(address keeper);
    event RelaySet(address relay);
    event SeriesSet(address series);
    event Swept(address indexed to, uint256 amount);

    /// @param owner_ The operator that arms the venue and tunes the wiring.
    /// @param brain_ The agent-committee wrapper, or zero to attach one later.
    constructor(address owner_, address brain_) Ownable(owner_) {
        brain = brain_;
    }

    /// @notice Accepts the bond and float that keep every subscription alive.
    /// @dev The precompile debits handler execution straight from this balance, so it is topped up
    /// by plain transfer rather than through a bookkeeping function.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    // Operator wiring
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Subscribe to a venue's `MarketCreated` logs, replacing any previous subscription.
    /// @param module The DreamDEX module that emits the logs.
    /// @param venueId_ The venue whose markets this router serves.
    function armVenue(address module, bytes32 venueId_) external onlyOwner {
        if (module == address(0)) revert ZeroAddress();

        uint256 have = address(this).balance;
        if (have < SUBSCRIPTION_FLOOR) revert RouterUnderfunded(have, SUBSCRIPTION_FLOOR);

        // Cancelling first means re-arming cannot leave a second live subscription firing into a
        // router that has already moved on to another venue.
        uint256 previous = venueSubscriptionId;
        if (previous != 0) SomniaExtensions.unsubscribe(previous);

        venue = venueId_;
        venueModule = module;

        uint256 id = SomniaExtensions.subscribe(
            address(this),
            SomniaExtensions.SubscriptionFilter({
                // Only topic0 is pinned: the indexed fields are marketId, market and pool, all of
                // which are unknown until the market exists.
                eventTopics: [LucidTypes.TOPIC_MARKET_CREATED, bytes32(0), bytes32(0), bytes32(0)],
                origin: address(0),
                emitter: module
            }),
            _options()
        );

        venueSubscriptionId = id;
        emit VenueArmed(venueId_, id);
    }

    /// @notice Point the router at the agent-committee wrapper.
    /// @param brain_ The brain address, or zero to detach.
    function setBrain(address brain_) external onlyOwner {
        brain = brain_;
        emit BrainUpdated(brain_);
    }

    /// @notice Point the router at the desk factory that publishes the copy-trade graph.
    /// @param factory_ The factory address, or zero to disable copy trading.
    function setFactory(address factory_) external onlyOwner {
        factory = factory_;
        emit FactoryUpdated(factory_);
    }

    /// @notice Attach the venue-wide upkeep runner, or detach it.
    /// @dev With a keeper attached the router schedules a settlement wake-up for every market on
    /// the venue rather than only for markets a desk holds, and pays for those wake-ups out of the
    /// operator's own float. Detaching it restores the narrower behaviour immediately.
    /// @param keeper_ The keeper address, or zero to stop running upkeep for the venue.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Attach the auto-redeem relay woken at settlement, or detach it.
    /// @dev The relay is ownerless and permissionless, so attaching one takes on no counterparty:
    /// the worst it can do is spend `RELAY_GAS` of a firing the router was making anyway. Detaching
    /// it restores the previous behaviour immediately, and leaves the queued exits for anyone else
    /// to drain.
    /// @param relay_ The relay address, or zero to stop redeeming exits for the venue.
    function setRelay(address relay_) external onlyOwner {
        relay = relay_;
        emit RelaySet(relay_);
    }

    /// @notice Attach the own-series roller, or detach it.
    /// @dev Attaching one does not by itself spend anything: the series contract ships in failover,
    /// where it rolls only once the venue has stopped producing windows of the cadence it watches,
    /// and it holds its own daily cap and float floor. The router's exposure is bounded by
    /// `SERIES_GAS` of a firing it was making anyway.
    /// @param series_ The series address, or zero to depend entirely on the venue's scheduler.
    function setSeries(address series_) external onlyOwner {
        series = series_;
        emit SeriesSet(series_);
    }

    /// @notice Move the point in a window at which the committee is asked.
    /// @dev Bounded rather than free, because both ends of the range are the failure this parameter
    /// exists to prevent: too early and spot has not left the strike, so the committee is asked the
    /// empty question again; too late and the brain's own `requiredSlack()` refuses, so the router
    /// buys a wake-up in order to be told no.
    /// @param bps Fraction of the window, between `MIN_DECISION_POINT_BPS` and
    /// `MAX_DECISION_POINT_BPS`.
    function setDecisionPoint(uint16 bps) external onlyOwner {
        if (bps < MIN_DECISION_POINT_BPS || bps > MAX_DECISION_POINT_BPS) revert BadDecisionPoint(bps);

        decisionPointBps = bps;
        emit DecisionPointSet(bps);
    }

    /// @notice Recover the operator's own float.
    /// @dev Desks' prepaid credit is deliberately out of reach. The operator funds the bond and the
    /// AI float, but a desk's top-up is that desk's money until it is spent on that desk's behalf.
    /// @param to Recipient of the swept balance.
    /// @param amount How much to sweep, capped at the unlocked float.
    function sweep(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = address(this).balance;
        uint256 locked = totalGasCredit;
        // The chain debits handler gas straight from this balance, outside EVM accounting, so the
        // balance can in principle sit below the credit book. Clamp rather than underflow.
        uint256 free = balance > locked ? balance - locked : 0;
        if (amount > free) revert CreditsLocked(free, amount);

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SweepFailed();
        emit Swept(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Desk registry and credit
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Admit a desk to the fan-out. Idempotent.
    /// @param desk The desk contract.
    function registerDesk(address desk) external {
        if (msg.sender != factory && msg.sender != owner()) revert NotFactory();
        if (desk == address(0)) revert ZeroAddress();
        // `preCheck` returns a value, and a call that expects return data reverts uncatchably when
        // the callee has no code. Refusing an EOA here is what keeps that out of the handler.
        if (desk.code.length == 0) revert NotAContract(desk);
        if (isDesk[desk]) return;

        isDesk[desk] = true;
        _deskList.push(desk);
        emit DeskRegistered(desk);
    }

    /// @notice Set whether a desk is considered for new markets.
    /// @dev Only the desk itself may flip this, so arming follows the desk's own owner check rather
    /// than duplicating it here.
    /// @param desk The desk contract.
    /// @param on True to be considered, false to be passed over.
    function setDeskArmed(address desk, bool on) external {
        if (!isDesk[desk]) revert UnknownDesk(desk);
        if (msg.sender != desk) revert NotDesk();

        deskArmed[desk] = on;
        emit DeskArmed(desk, on);
    }

    /// @notice Prepay a desk's share of the router's on-chain costs.
    /// @dev Permissionless: anyone may fund anyone's desk, which is what lets a front end or a
    /// sponsor cover a new user's first windows.
    /// @param desk The desk to credit.
    function topUp(address desk) external payable {
        if (!isDesk[desk]) revert UnknownDesk(desk);

        _gasCredit[desk] += msg.value;
        totalGasCredit += msg.value;
        emit ToppedUp(desk, msg.value, _gasCredit[desk]);
    }

    /// @notice A desk records what it just traded so its followers can mirror it.
    /// @dev Called by the desk from inside its own `onVerdict`, and consumed by the copy fan-out in
    /// the same transaction. Restricting it to registered desks is what stops an outsider from
    /// injecting a fake leader trade.
    /// @param marketId The window traded.
    /// @param kind The venue order kind, as in `LucidTypes.BUY_YES` and friends.
    /// @param stake The raw 6-decimal notional committed.
    function reportTrade(bytes32 marketId, uint8 kind, uint256 stake) external {
        if (!isDesk[msg.sender]) revert UnknownDesk(msg.sender);

        _lastTrade[msg.sender][marketId] = Trade({kind: kind, stake: stake});
        emit TradeReported(msg.sender, marketId, kind, stake);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reactivity handler
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc SomniaEventHandler
    /// @dev Reached only from `0x0100`; the base contract enforces that. Every branch below returns
    /// rather than reverts, including the branch for a topic this router does not serve.
    function _onEvent(address emitter, bytes32[] calldata eventTopics, bytes calldata data) internal override {
        if (eventTopics.length == 0) return;
        bytes32 topic0 = eventTopics[0];

        if (topic0 == LucidTypes.TOPIC_MARKET_CREATED) {
            // The filter already pins the emitter, but a stale subscription from a previous
            // `armVenue` could still be in flight for one more block.
            if (emitter != venueModule) return;
            _onMarketCreated(eventTopics, data);
        } else if (topic0 == LucidTypes.TOPIC_SCHEDULE) {
            if (emitter != SomniaExtensions.SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS) return;
            if (eventTopics.length < 2) return;
            _onSchedule(uint256(eventTopics[1]));
        }
    }

    /// @notice Decode a raw `MarketCreated` log.
    /// @dev Public and pure so the handler can reach it through `try this.decodeMarket(...)`. The
    /// decoder reverts on a malformed log by design, and an internal call would carry that revert
    /// into the handler and take the firing down with it.
    /// @param topics The log's topic array.
    /// @param data The log's non-indexed body.
    /// @return The decoded window.
    function decodeMarket(bytes32[] calldata topics, bytes calldata data)
        external
        pure
        returns (LucidTypes.MarketInfo memory)
    {
        return MarketDecoder.decode(topics, data);
    }

    /// @notice Create the one-shot wake-up for a millisecond timestamp.
    /// @dev Self-call only. It exists purely as a revert boundary: the subscription helper reverts
    /// on a past timestamp or a thin balance, and a handler must absorb that rather than propagate it.
    ///
    /// @dev Kind-agnostic despite the historical name, which is kept because it is the selector the
    /// deployed ABI publishes. A one-shot is a millisecond and nothing else: the same subscription
    /// serves a decision wake-up, a settlement wake-up, or both at once when two windows happen to
    /// land on the same instant. What each firing means is decided by which list the market was
    /// queued on — `_decisionAt` or `_dueAt` — never by the subscription itself.
    /// @param tsMillis Absolute unix timestamp in milliseconds.
    /// @return subscriptionId The new one-shot's id.
    function scheduleSettlement(uint256 tsMillis) external returns (uint256 subscriptionId) {
        if (msg.sender != address(this)) revert NotSelf();
        return SomniaExtensions.scheduleSubscriptionAtTimestamp(address(this), tsMillis, _options());
    }

    /// @notice Deliver a committee verdict to every desk holding the market, then to their followers.
    /// @param marketId The window that was priced.
    /// @param v The committee's answer.
    function onVerdict(bytes32 marketId, LucidTypes.Verdict calldata v) external {
        if (msg.sender != brain) revert NotBrain();

        LucidTypes.MarketInfo memory m = _markets[marketId];
        // A verdict for a market this router never saw. Nothing to fan out to.
        if (m.marketId == bytes32(0)) return;

        (uint256 pBookBps, bool bookObserved) = _pBookBps(m.pool);

        // A memory copy, because desks re-enter through `reportTrade` while this loop runs and the
        // copy fan-out appends followers to the same list.
        address[] memory leaders = _interested[marketId];
        for (uint256 i; i < leaders.length; ++i) {
            address desk = leaders[i];

            // A registered desk had code when it was admitted; this covers the case where it no
            // longer does, which `try` cannot, and keeps a codeless address from reading as a
            // silent success.
            if (desk.code.length == 0) {
                emit Skipped(desk, marketId, "NO_CODE");
                continue;
            }

            uint256 gasFor = _stipend(DESK_GAS);
            if (gasFor == 0) {
                emit Skipped(desk, marketId, "NO_GAS");
                continue;
            }

            try ILucidDesk(desk).onVerdict{gas: gasFor}(m, v, pBookBps, bookObserved) {}
            catch {
                emit Skipped(desk, marketId, "DESK_REVERTED");
            }
        }

        _copyToFollowers(m, leaders);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A desk's remaining prepaid credit.
    /// @param desk The desk contract.
    /// @return The credit left, in wei.
    function gasCreditOf(address desk) external view returns (uint256) {
        return _gasCredit[desk];
    }

    /// @notice Everything the router knows about a window.
    /// @param marketId The window's venue id.
    /// @return The decoded market, or a zeroed struct if this router never saw it.
    function marketOf(bytes32 marketId) external view returns (LucidTypes.MarketInfo memory) {
        return _markets[marketId];
    }

    /// @notice The desks that will be driven for a window, in fan-out order.
    /// @param marketId The window's venue id.
    /// @return The desks that paid to be served, followed by any that copied into it.
    function interestedIn(bytes32 marketId) external view returns (address[] memory) {
        return _interested[marketId];
    }

    /// @notice The markets queued to settle at a millisecond timestamp.
    /// @param tsMillis Absolute unix timestamp in milliseconds.
    /// @return The windows a firing at that timestamp will settle.
    function pendingAt(uint256 tsMillis) external view returns (bytes32[] memory) {
        return _dueAt[tsMillis];
    }

    /// @notice The markets queued to be priced at a millisecond timestamp.
    /// @dev Deliberately separate from `pendingAt`. A settlement closes a position and a decision
    /// opens one, and a caller that could not tell them apart would read a window about to be
    /// traded as a window about to be booked.
    /// @param tsMillis Absolute unix timestamp in milliseconds.
    /// @return The windows a firing at that timestamp will ask the committee about.
    function decisionsAt(uint256 tsMillis) external view returns (bytes32[] memory) {
        return _decisionAt[tsMillis];
    }

    /// @notice Whether a window's settlement wake-up has already been booked.
    /// @param marketId The window's venue id.
    /// @return True once the window is queued to settle, whoever booked it.
    function settlementBooked(bytes32 marketId) external view returns (bool) {
        return _settlementBooked[marketId];
    }

    /// @notice The instant this router will ask the committee about a window.
    /// @dev Derived rather than stored, so it always describes the current `decisionPointBps`.
    /// @param m The window.
    /// @return Absolute unix timestamp in milliseconds.
    function decisionPointOf(LucidTypes.MarketInfo calldata m) external view returns (uint256) {
        return _decisionMillis(m);
    }

    /// @notice Every registered desk currently asking to be considered.
    /// @dev Unbounded by design; the fan-out that spends gas is capped at `MAX_FANOUT`, this is not.
    /// @return out The armed desks, in registration order.
    function armedDesks() external view returns (address[] memory out) {
        uint256 len = _deskList.length;
        address[] memory buffer = new address[](len);
        uint256 count;

        for (uint256 i; i < len; ++i) {
            address desk = _deskList[i];
            if (deskArmed[desk]) buffer[count++] = desk;
        }

        out = new address[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buffer[i];
        }
    }

    /// @notice Every registered desk, armed or not.
    /// @return Every desk ever registered, in registration order.
    function allDesks() external view returns (address[] memory) {
        return _deskList;
    }

    /// @notice Settled window outcomes for an asset, oldest first, at most `MAX_RECENT` of them.
    /// @dev Read off the venue's own resolved markets at settlement time, so the evidence the
    /// committee is shown is chain state rather than anything this protocol asserts.
    /// @param assetKey `keccak256(bytes(asset))`, as in `LucidTypes.ASSET_BTC`.
    /// @return out One entry per remembered window; non-zero means the window settled UP.
    function recentOf(bytes32 assetKey) public view returns (uint16[] memory out) {
        History storage h = _history[assetKey];
        uint256 n = h.filled;
        out = new uint16[](n);

        // Once the ring is full the oldest entry is the one about to be overwritten.
        uint256 start = n == MAX_RECENT ? h.next : 0;
        for (uint256 i; i < n; ++i) {
            out[i] = h.slots[(start + i) % MAX_RECENT];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MarketCreated branch
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The order of operations here is deliberate: every reason to decline is checked before a
    /// single wei of credit moves, so a market that cannot be served costs nobody anything.
    function _onMarketCreated(bytes32[] calldata topics, bytes calldata data) private {
        LucidTypes.MarketInfo memory m;
        try this.decodeMarket(topics, data) returns (LucidTypes.MarketInfo memory decoded) {
            m = decoded;
        } catch {
            emit Skipped(address(0), bytes32(0), "UNDECODABLE");
            return;
        }

        // The venue is shared by several operators. Theirs is not our business, and saying so
        // loudly would spam the log on every foreign market.
        if (m.venueId != venue) return;

        _markets[m.marketId] = m;
        emit MarketSeen(m.marketId, m.intervalSec, m.assetKey);

        // Before the expiry check, deliberately. A window this router is too late to serve is still
        // proof that the venue's own scheduler is alive, and that is the single fact the series
        // contract needs in order to keep standing down.
        _seriesSaw(m);

        // Scheduling a wake-up is only possible strictly in the future, and a window we cannot wake
        // up for is a window we must not pay a committee to price.
        uint256 tsMillis = (uint256(m.expiry) + SETTLEMENT_DELAY) * 1000;
        if (tsMillis < ((block.timestamp + 1) * 1000) + 1) {
            emit Skipped(address(0), m.marketId, "EXPIRED");
            return;
        }

        // Nothing is asked of the committee here any more. At this instant the strike IS the spot
        // price, so the question has no content and the answer is 50 every time. All that happens
        // now is a promise to come back later, and only if somebody wants the window.
        _scheduleDecision(m);

        // Venue-wide upkeep needs the router to be awake after this window closes, and nothing else
        // — so every market on the venue gets a settlement one-shot, but only when a keeper is
        // attached to make use of it. With no keeper the router books settlement at the decision
        // point instead, for exactly the desks that paid to be there.
        if (keeper != address(0)) _scheduleSettlement(m.marketId, tsMillis);
    }

    /// @dev Books the wake-up at which this window will actually be priced, if anyone wants it.
    ///
    /// The `preCheck` pass is run here rather than only at the decision point because the router
    /// pays for its own wake-ups, and this change roughly doubles how many there are. A market no
    /// armed desk would touch must cost nothing — no subscription, no float, no firing. The pass is
    /// run again when the wake-up lands, because a desk's answer can have changed by then: it is a
    /// filter, not a reservation.
    function _scheduleDecision(LucidTypes.MarketInfo memory m) private {
        if (_decisionBooked[m.marketId]) return;

        // Silent when nobody wants the window: on a venue that rolls two assets a minute, saying so
        // every time would bury every log line that matters.
        if (_candidates(m).length == 0) return;

        uint256 tsMillis = _decisionMillis(m);

        // A window whose decision point has already passed cannot be woken for. Rather than fall
        // back to asking now — which is the behaviour this whole change exists to remove — it is
        // declined out loud, so a router that is chronically late is visible rather than quietly
        // trading on the empty question again.
        if (tsMillis < ((block.timestamp + 1) * 1000) + 1) {
            emit Skipped(address(0), m.marketId, "DECISION_PAST");
            return;
        }

        uint256 subscriptionId = scheduleIdAt[tsMillis];
        if (subscriptionId == 0) {
            try this.scheduleSettlement(tsMillis) returns (uint256 newId) {
                subscriptionId = newId;
                scheduleIdAt[tsMillis] = newId;
            } catch {
                // No wake-up means no verdict for this window at all. Nobody has been charged and
                // nobody holds a position, so this is a missed opportunity rather than a broken
                // state — but it is still the reason nothing happened, and it is named.
                emit Skipped(address(0), m.marketId, "DECISION_SCHEDULE_FAILED");
                return;
            }
        }

        _decisionBooked[m.marketId] = true;
        _decisionAt[tsMillis].push(m.marketId);
        emit DecisionScheduled(m.marketId, tsMillis, subscriptionId);
    }

    /// @dev The desks' half of a window that has reached its decision point: who still wants it, who
    /// pays for the committee, and the settlement wake-up their positions oblige the router to book.
    function _serveDesks(LucidTypes.MarketInfo memory m, uint256 tsMillis) private {
        address[] memory candidates = _candidates(m);
        if (candidates.length == 0) return;

        // The brain refuses a window with less than `requiredSlack()` left — both of its stages
        // have to finish and the desk still needs room to trade. Asking anyway would spend a
        // request in order to be told no, so the question is not put. Every desk that would have
        // paid is named, because "nobody wanted it" and "we ran out of window" are different facts.
        if (_tooLateToAsk(m)) {
            for (uint256 i; i < candidates.length; ++i) {
                emit Skipped(candidates[i], m.marketId, "TOO_LATE");
            }
            return;
        }

        // Checked before `_quote` rather than inside it, because a quote that never happened for
        // want of gas is not the same fact as a brain that is missing or broken, and "NO_BRAIN"
        // would send whoever reads this log to inspect a contract that was fine.
        if (_stipend(BOOK_GAS) == 0) {
            emit Skipped(address(0), m.marketId, "NO_GAS");
            return;
        }

        (bool quoted, uint256 fee) = _quote();
        if (!quoted) {
            emit Skipped(address(0), m.marketId, "NO_BRAIN");
            return;
        }
        // The bond is not spendable float. Dipping below it would silently disarm every
        // subscription this router owns, including the settlement wake-ups already promised.
        if (address(this).balance < SUBSCRIPTION_FLOOR + fee) {
            emit Skipped(address(0), m.marketId, "ROUTER_FLOAT");
            return;
        }

        (address[] memory payers, uint256 share) = _resolvePayers(m.marketId, candidates, fee);
        if (payers.length == 0) return;

        // The committee is shown the same two pieces of evidence a desk will later be judged
        // against: what the book thinks right now, and how this asset's recent windows resolved.
        uint256 pBookBps = _pBookForPrompt(m.pool);
        uint16[] memory recent = recentOf(m.assetKey);

        // Paid before anyone is charged: if the committee cannot be reached, no desk is on the hook
        // and no credit has moved.
        uint256 requestId;
        try ILucidBrain(brain).requestVerdict{value: fee}(m.marketId, m, pBookBps, recent) returns (uint256 id) {
            requestId = id;
        } catch {
            emit Skipped(address(0), m.marketId, "VERDICT_REQUEST_FAILED");
            return;
        }

        // Zero is the brain refusing, not the brain failing. It declines a window it cannot price
        // honestly — too little of it left, no feed for the asset, no float for the second stage —
        // by storing a refusal and returning zero rather than by reverting, precisely so the desk
        // gets told why instead of waiting on silence. The `try` above therefore succeeds, and a
        // router that read only "it did not revert" would debit every desk for a committee call
        // that was never made and then wake them for a position none of them hold. Charging for
        // work that did not happen is the same class of error as blaming a callee for a shortfall
        // that was ours: the log has to name what actually occurred.
        if (requestId == 0) {
            for (uint256 i; i < payers.length; ++i) {
                emit Skipped(payers[i], m.marketId, "NO_VERDICT");
            }
            return;
        }

        emit VerdictRequested(m.marketId, fee, payers.length);

        // The list is rebuilt rather than appended to, so it always describes this firing's fan-out
        // and nothing left over from an earlier one.
        delete _interested[m.marketId];
        for (uint256 i; i < payers.length; ++i) {
            _debit(payers[i], m.marketId, share);
            _interested[m.marketId].push(payers[i]);
        }

        _scheduleSettlement(m.marketId, tsMillis);
    }

    /// @dev Armed desks that want this market, capped at `MAX_FANOUT` considered. A desk whose
    /// `preCheck` reverts or runs away is treated as a decline: its own breakage is not everyone's.
    /// A desk this router could not afford to ask is also treated as a decline, but it is named:
    /// "did not want it" and "we never asked" look the same from outside, and they are not the same.
    function _candidates(LucidTypes.MarketInfo memory m) private returns (address[] memory out) {
        uint256 len = _deskList.length;
        address[] memory buffer = new address[](MAX_FANOUT);
        uint256 count;
        uint256 considered;

        for (uint256 i; i < len && considered < MAX_FANOUT; ++i) {
            address desk = _deskList[i];
            if (!deskArmed[desk]) continue;
            ++considered;

            // `preCheck` returns a value, so the compiler checks `extcodesize` before the call and
            // raises outside the `catch`. A desk with no code has to be refused here or it takes
            // the whole firing down.
            if (desk.code.length == 0) {
                emit Skipped(desk, m.marketId, "NO_CODE");
                continue;
            }

            uint256 gasFor = _stipend(PRECHECK_GAS);
            if (gasFor == 0) {
                emit Skipped(desk, m.marketId, "NO_GAS");
                continue;
            }

            try ILucidDesk(desk).preCheck{gas: gasFor}(m) returns (bool want) {
                if (want) buffer[count++] = desk;
            } catch {}
        }

        out = new address[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buffer[i];
        }
    }

    /// @dev Splits one committee fee across the desks that will actually pay it.
    ///
    /// The split is circular by nature: dropping a desk that cannot afford its share raises the
    /// share for everyone left, which may make another desk unaffordable in turn. Charging the
    /// first-pass share would either over-collect from a set that shrank or leave the router paying
    /// the difference out of the bond. So the set is iterated to a fixed point — removals only ever
    /// raise the share, so it converges, and it is bounded by `MAX_FANOUT` rounds.
    ///
    /// The share also covers the settlement wake-up, because a desk that trades a window has
    /// committed the router to waking it again after expiry.
    function _resolvePayers(bytes32 marketId, address[] memory candidates, uint256 fee)
        private
        returns (address[] memory payers, uint256 share)
    {
        uint256 n = candidates.length;
        bool[] memory dropped = new bool[](n);
        uint256 alive = n;

        while (alive != 0) {
            share = _ceilDiv(fee, alive) + SETTLEMENT_BUDGET;

            uint256 removed;
            for (uint256 i; i < n; ++i) {
                if (dropped[i]) continue;
                if (_gasCredit[candidates[i]] >= share) continue;

                dropped[i] = true;
                ++removed;
                emit Skipped(candidates[i], marketId, "NO_CREDIT");
            }

            if (removed == 0) break;
            alive -= removed;
        }

        payers = new address[](alive);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (dropped[i]) continue;
            payers[k++] = candidates[i];
        }
    }

    /// @dev One one-shot serves every market ending at the same millisecond, which on a venue that
    /// rolls BTC and ETH on the same 60-second grid halves the subscriptions outright.
    ///
    /// A market reaches here at most once. With a keeper attached it is booked at creation for the
    /// whole venue; the desks' own path reaches it again at the decision point, and a second entry
    /// in the same queue would call `onSettlement` twice on every holder in one firing — booking
    /// the same window's result against the desk's loss streak and open-market count twice over.
    function _scheduleSettlement(bytes32 marketId, uint256 tsMillis) private {
        if (_settlementBooked[marketId]) return;

        uint256 subscriptionId = scheduleIdAt[tsMillis];

        if (subscriptionId == 0) {
            try this.scheduleSettlement(tsMillis) returns (uint256 newId) {
                subscriptionId = newId;
                scheduleIdAt[tsMillis] = newId;
            } catch {
                // The desks are already positioned, so this is a degraded state rather than a
                // failed one: they must be settled by hand. Saying so is the whole point.
                emit Skipped(address(0), marketId, "SCHEDULE_FAILED");
                return;
            }
        }

        _settlementBooked[marketId] = true;
        _dueAt[tsMillis].push(marketId);
        emit SettlementScheduled(marketId, tsMillis, subscriptionId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Schedule branch
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Everything this router promised to do at this millisecond: price the windows that have
    /// reached their decision point, then settle the windows that have closed.
    ///
    /// Both kinds of work can land on the same instant — one market's halfway point is another's
    /// expiry — and the chain fires exactly one `Schedule` event for a millisecond however much was
    /// queued against it. Which list a market is on is the only thing that says what happens to it,
    /// which is why they are separate lists and not one tagged one.
    function _onSchedule(uint256 tsMillis) private {
        bytes32[] storage decisions = _decisionAt[tsMillis];
        uint256 decisionCount = decisions.length;
        for (uint256 i; i < decisionCount; ++i) {
            _onDecision(decisions[i]);
        }
        // Cleared before the settlement pass, so a market that somehow appears on both lists at the
        // same millisecond cannot be priced twice.
        delete _decisionAt[tsMillis];

        bytes32[] storage due = _dueAt[tsMillis];
        uint256 marketCount = due.length;

        for (uint256 i; i < marketCount; ++i) {
            bytes32 marketId = due[i];
            LucidTypes.MarketInfo memory m = _markets[marketId];

            address[] storage holders = _interested[marketId];
            uint256 holderCount = holders.length;
            for (uint256 j; j < holderCount; ++j) {
                address desk = holders[j];

                if (desk.code.length == 0) {
                    emit Skipped(desk, marketId, "NO_CODE");
                    continue;
                }

                uint256 gasFor = _stipend(DESK_GAS);
                if (gasFor == 0) {
                    emit Skipped(desk, marketId, "NO_GAS");
                    continue;
                }

                try ILucidDesk(desk).onSettlement{gas: gasFor}(m) {}
                catch {
                    emit Skipped(desk, marketId, "SETTLEMENT_REVERTED");
                }
            }

            delete _interested[marketId];
            _keep(m);
            _relayExits(marketId);
            _recordOutcome(m);
            // Last, because it is the most expensive tenant of a settlement firing by an order of
            // magnitude and the firing was not paid for by it. The desks that paid, the venue-wide
            // upkeep and the pre-signed exits all get their gas first.
            _tickSeries(m);
        }

        delete _dueAt[tsMillis];
        // The chain removes a one-shot once it has fired, so the slot must be freed rather than
        // left pointing at a dead id: a later window closing at the same millisecond needs a new one.
        delete scheduleIdAt[tsMillis];
    }

    /// @dev A window has reached the point in its life where the question is worth asking. This is
    /// what the `MarketCreated` branch used to do at the open, run now that spot has had half the
    /// window to move away from the strike and there is a real disagreement to price.
    function _onDecision(bytes32 marketId) private {
        LucidTypes.MarketInfo memory m = _markets[marketId];
        // A decision for a market this router never stored. Nothing to serve.
        if (m.marketId == bytes32(0)) return;

        // The desks that trade this window will have to be woken again when it closes, and a wake-up
        // can only be booked in the future — so a window already past its settlement instant must
        // not be traded, exactly as at creation.
        uint256 tsMillis = (uint256(m.expiry) + SETTLEMENT_DELAY) * 1000;
        if (tsMillis < ((block.timestamp + 1) * 1000) + 1) {
            emit Skipped(address(0), marketId, "EXPIRED");
            return;
        }

        _serveDesks(m, tsMillis);
    }

    /// @dev Runs DreamDEX's permissionless upkeep for a settled window, for the good of the whole
    /// venue rather than of this protocol.
    ///
    /// It comes after the desks have been settled, because the desks paid for this firing and the
    /// upkeep did not, and before the outcome is recorded, because finalizing a market is what
    /// makes its payout numerators readable in the first place. Both the `code.length` guard and
    /// the `try` are needed: the keeper is a separate deployment that an operator can re-point, and
    /// a handler that reverts loses every desk's settlement, not just the upkeep.
    function _keep(LucidTypes.MarketInfo memory m) private {
        address k = keeper;
        if (k == address(0) || k.code.length == 0) return;

        uint256 gasFor = _stipend(KEEPER_GAS);
        if (gasFor == 0) {
            emit Skipped(k, m.marketId, "NO_GAS");
            return;
        }

        try ILucidKeeper(k).keep{gas: gasFor}(m) {}
        catch {
            emit Skipped(k, m.marketId, "KEEPER_FAILED");
        }
    }

    /// @dev Redeems the exits their owners signed in advance for a window that has just closed.
    ///
    /// It runs after `_keep`, and that ordering is the whole thing: a redemption reverts until the
    /// market is finalized, and finalizing it is the first call the keeper makes. Running the relay
    /// first would produce a queue of `RelayFailed` events and redeem nothing.
    ///
    /// Guarded and wrapped for the same two reasons as the keeper. The relay is a separate
    /// deployment an operator can re-point, and `try` alone does not survive an address with no
    /// code — the `extcodesize` check runs outside the `catch` and would take the whole firing,
    /// including every desk's settlement, down with it.
    function _relayExits(bytes32 marketId) private {
        address r = relay;
        if (r == address(0) || r.code.length == 0) return;

        uint256 gasFor = _stipend(RELAY_GAS);
        if (gasFor == 0) {
            emit Skipped(r, marketId, "NO_GAS");
            return;
        }

        try ILucidRelay(r).relayUpTo{gas: gasFor}(marketId, RELAY_BATCH) {}
        catch {
            emit Skipped(r, marketId, "RELAY_FAILED");
        }
    }

    /// @dev Tells the own-series roller that the venue created a market, which is the only evidence
    /// its scheduler is still running.
    ///
    /// Guarded and wrapped for the same two reasons as the keeper and the relay: the series is a
    /// separate deployment an operator can re-point, and `try` alone does not survive an address
    /// with no code — the `extcodesize` check runs outside the `catch` and would take the whole
    /// firing down with it.
    function _seriesSaw(LucidTypes.MarketInfo memory m) private {
        address s = series;
        if (s == address(0) || s.code.length == 0) return;

        uint256 gasFor = _stipend(SERIES_GAS);
        if (gasFor == 0) {
            emit Skipped(s, m.marketId, "NO_GAS");
            return;
        }

        try ILucidSeries(s).onVenueMarket{gas: gasFor}(m) {}
        catch {
            emit Skipped(s, m.marketId, "SERIES_FAILED");
        }
    }

    /// @dev Gives the own-series roller the chance to roll one of this protocol's own windows.
    ///
    /// The stipend is the largest this router hands out, because a live `triggerRoll` measured
    /// 61.6M gas. It is still a stipend and not the whole frame: the series is the last thing
    /// considered in a settlement firing, and it may not take the gas the desks paid for.
    function _tickSeries(LucidTypes.MarketInfo memory m) private {
        address s = series;
        if (s == address(0) || s.code.length == 0) return;

        uint256 gasFor = _stipend(SERIES_GAS);
        if (gasFor == 0) {
            emit Skipped(s, m.marketId, "NO_GAS");
            return;
        }

        try ILucidSeries(s).onTick{gas: gasFor}(m) {}
        catch {
            emit Skipped(s, m.marketId, "SERIES_FAILED");
        }
    }

    /// @dev Remembers how a window actually resolved, as evidence for the next committee prompt.
    /// Outcome index 0 is the YES leg, so a payout weighted towards it means the window settled UP.
    function _recordOutcome(LucidTypes.MarketInfo memory m) private {
        // `try` does not catch this one. When a call is expected to return data, the compiler
        // checks `extcodesize` on the success path, and that revert is raised outside the handler
        // rather than inside it. Every call below that returns something is guarded the same way.
        if (m.market.code.length == 0) return;

        // Evidence for the next prompt, not work anybody paid for: if the frame is spent, the ring
        // simply keeps one window less of history.
        uint256 gasFor = _stipend(BOOK_GAS);
        if (gasFor == 0) return;

        try IBinaryMarket(m.market).payoutNumerators{gas: gasFor}() returns (uint256[] memory payouts) {
            if (payouts.length < 2) return;

            History storage h = _history[m.assetKey];
            h.slots[h.next] = payouts[0] > payouts[1] ? uint16(1) : uint16(0);
            h.next = uint8((h.next + 1) % MAX_RECENT);
            if (h.filled < MAX_RECENT) ++h.filled;
        } catch {}
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Copy trading
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Mirrors each leader's reported trade to its followers, scaled down. The graph is read
    /// from the factory rather than held here, so a follower list can grow without touching the
    /// contract that holds the bond.
    function _copyToFollowers(LucidTypes.MarketInfo memory m, address[] memory leaders) private {
        address registry = factory;
        if (registry.code.length == 0) return;

        for (uint256 i; i < leaders.length; ++i) {
            address leader = leaders[i];

            Trade memory t = _lastTrade[leader][m.marketId];
            if (t.stake == 0) continue;
            // One report, one mirror. Leaving it behind would let a stale trade be copied again on
            // a replayed verdict.
            delete _lastTrade[leader][m.marketId];

            uint256 gasFor = _stipend(DESK_GAS);
            if (gasFor == 0) {
                emit Skipped(leader, m.marketId, "NO_GAS");
                continue;
            }

            address[] memory followers;
            try IFactoryView(registry).followersOf{gas: gasFor}(leader) returns (address[] memory list) {
                followers = list;
            } catch {
                continue;
            }

            uint256 n = followers.length > MAX_FANOUT ? MAX_FANOUT : followers.length;
            for (uint256 j; j < n; ++j) {
                _copyOne(m, leader, followers[j], t);
            }
        }
    }

    /// @dev One leader-to-follower mirror, with every reason to decline named in an event.
    function _copyOne(LucidTypes.MarketInfo memory m, address leader, address follower, Trade memory t) private {
        if (follower == leader || !isDesk[follower]) return;

        uint256 readGas = _stipend(BOOK_GAS);
        if (readGas == 0) {
            emit Skipped(follower, m.marketId, "NO_GAS");
            return;
        }

        uint16 scaleBps;
        try IFactoryView(factory).scaleOf{gas: readGas}(leader, follower) returns (uint16 s) {
            scaleBps = s;
        } catch {
            return;
        }

        if (scaleBps == 0) return;
        // A follower is never levered above the desk it follows, whatever the registry says.
        if (scaleBps > MAX_SCALE_BPS) {
            emit Skipped(follower, m.marketId, "BAD_SCALE");
            return;
        }

        // Copying is work, and the follower will also need a settlement wake-up for the position.
        if (_gasCredit[follower] < SETTLEMENT_BUDGET) {
            emit Skipped(follower, m.marketId, "NO_CREDIT");
            return;
        }

        if (follower.code.length == 0) {
            emit Skipped(follower, m.marketId, "NO_CODE");
            return;
        }

        uint256 copyGas = _stipend(DESK_GAS);
        if (copyGas == 0) {
            emit Skipped(follower, m.marketId, "NO_GAS");
            return;
        }

        uint256 stake = (t.stake * scaleBps) / LucidTypes.BPS;
        try ILucidDesk(follower).onLeaderTrade{gas: copyGas}(m, t.kind, stake) {
            _debit(follower, m.marketId, SETTLEMENT_BUDGET);
            // A desk that took a position must be settled, so copying puts it on the list.
            _addInterested(m.marketId, follower);
        } catch {
            emit Skipped(follower, m.marketId, "COPY_FAILED");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev What a callee can actually be given right now, capped at what it is allowed to ask for.
    ///
    /// A fixed stipend cannot be right at both ends of a fan-out: sized for the first desk it
    /// starves the last, and sized for the last it is too small for anybody. So the ceiling is a
    /// ceiling, and this is the floor of what the frame can honour.
    ///
    /// The 63/64 rule means a callee can never receive everything that is left, so asking for
    /// more than that silently truncates. Capping explicitly keeps the shortfall visible instead.
    function _stipend(uint256 want) private view returns (uint256) {
        uint256 left = gasleft();
        if (left <= GAS_RESERVE) return 0;
        uint256 available = ((left - GAS_RESERVE) * 63) / 64;
        return want < available ? want : available;
    }

    /// @dev Fee and gas controls shared by every subscription this router creates.
    function _options() private pure returns (SomniaExtensions.SubscriptionOptions memory) {
        return SomniaExtensions.SubscriptionOptions({
            priorityFeePerGas: HANDLER_PRIORITY_FEE, maxFeePerGas: HANDLER_MAX_FEE, gasLimit: HANDLER_GAS_LIMIT
        });
    }

    /// @dev The instant a window is priced: `tradingStart` plus a fraction of its own length, in
    /// milliseconds. Scaled off `intervalSec` rather than off a fixed number of seconds so a
    /// one-hour window is asked about an hour in and a five-minute one five minutes in — the point
    /// is a fraction of the price's travel, not a wall-clock delay.
    function _decisionMillis(LucidTypes.MarketInfo memory m) private view returns (uint256) {
        uint256 offset = (uint256(m.intervalSec) * uint256(decisionPointBps)) / LucidTypes.BPS;
        return (uint256(m.tradingStart) + offset) * 1000;
    }

    /// @dev Whether the window has less left than the brain needs to answer at all.
    ///
    /// The threshold is read from the brain rather than kept here as a constant, because it is
    /// self-calibrating on the brain's own measured round-trip latency and a copy in this contract
    /// would drift out of agreement with it silently — the router would either stop asking for
    /// windows the brain would happily have priced, or keep paying for ones it will refuse.
    ///
    /// An unreadable brain reads as "not too late", deliberately. This function's only job is to
    /// avoid spending on a refusal that is already certain; a brain it cannot read makes nothing
    /// certain, and the paths downstream already name a missing brain (`NO_BRAIN`) or a refused
    /// request (`NO_VERDICT`) accurately. Guessing `TOO_LATE` here would blame the window for a
    /// failure that belongs to the brain.
    function _tooLateToAsk(LucidTypes.MarketInfo memory m) private view returns (bool) {
        address b = brain;
        // `requiredSlack` returns a value, so the compiler's `extcodesize` check raises outside the
        // `catch`. A brain with no code has to be refused here or it takes the whole firing down.
        if (b.code.length == 0) return false;

        uint256 gasFor = _stipend(BOOK_GAS);
        if (gasFor == 0) return false;

        try ILucidBrain(b).requiredSlack{gas: gasFor}() returns (uint256 slack) {
            // A window closes on wall-clock time, so block time is the only clock this contract
            // has. A validator nudging it by seconds cannot manufacture anything here: it can only
            // move a window a few seconds either side of a threshold the brain would apply itself
            // a moment later anyway.
            // forge-lint: disable-next-line(block-timestamp)
            uint256 secondsLeft = m.expiry > block.timestamp ? uint256(m.expiry) - block.timestamp : 0;
            return secondsLeft < slack;
        } catch {
            return false;
        }
    }

    /// @dev The committee's price, or a clear "no" when the brain is missing or broken.
    function _quote() private view returns (bool ok, uint256 fee) {
        address b = brain;
        if (b.code.length == 0) return (false, 0);

        uint256 gasFor = _stipend(BOOK_GAS);
        if (gasFor == 0) return (false, 0);

        try ILucidBrain(b).quote{gas: gasFor}() returns (uint256 q) {
            return (true, q);
        } catch {
            return (false, 0);
        }
    }

    /// @dev The book-implied UP probability in bps, and whether there was a book at all.
    ///
    /// A binary window's YES price is the market's own probability, so the mid of the best bid and
    /// best ask is the number the committee's answer has to beat. One side is still an observation
    /// — a resting bid is somebody's real opinion — so it is used on its own rather than discarded.
    ///
    /// No side is not an observation, and this function used to report it as 5000 anyway. That is
    /// the one place in this codebase where a value nobody produced was passed off as a reading, and
    /// it was not harmless: a desk comparing an 8800 verdict against the fallback measures a
    /// 38-point edge against a price that does not exist, and stakes 38% of its equity on it. The
    /// caller is now told the difference and can refuse, which is what every other read in this
    /// contract already does.
    ///
    /// @return pBookBps The book mid in bps, meaningful only when `observed` is true.
    /// @return observed Whether any side of the book quoted.
    function _pBookBps(address pool) private view returns (uint256 pBookBps, bool observed) {
        (bool haveBid, uint256 bestBid) = _bestLevel(pool, true);
        (bool haveAsk, uint256 bestAsk) = _bestLevel(pool, false);

        if (haveBid && haveAsk) return (((bestBid + bestAsk) * LucidTypes.BPS) / (2 * LucidTypes.ONE), true);
        if (haveBid) return ((bestBid * LucidTypes.BPS) / LucidTypes.ONE, true);
        if (haveAsk) return ((bestAsk * LucidTypes.BPS) / LucidTypes.ONE, true);
        // Zero, not a coin flip. There is no number to report, and every value inside the
        // probability range would be read as one.
        return (0, false);
    }

    /// @dev The book number the committee is given: the real mid, or the sentinel that says there
    /// was no book at all.
    ///
    /// This used to substitute 5000 for an empty book, and that substitution is what broke the
    /// committee. The prompt printed "Book-implied UP probability: 50.00%" as a fact, and the model
    /// anchored on it and handed back 50 — every time, from validators that agreed, which is
    /// precisely why every production verdict was exactly 50.00%. Measured on the live committee
    /// with the same window and the book line deleted, the same question answered 95 on a +776 bps
    /// distance to strike and 0 on the bearish case. The number was not weak evidence; it was our
    /// own invention fed back to us.
    ///
    /// `LucidTypes.BOOK_UNOBSERVED` sits outside the probability range, so the brain's prompt
    /// builder can drop the sentence entirely rather than print an impossible percentage. Asking
    /// the committee to disagree with a price nobody quoted is the same error as letting a desk
    /// measure an edge against one — this is that error, one step earlier.
    function _pBookForPrompt(address pool) private view returns (uint256) {
        (uint256 bps, bool observed) = _pBookBps(pool);
        return observed ? bps : uint256(LucidTypes.BOOK_UNOBSERVED);
    }

    /// @dev Top of one side of a pool's book. Pools are recycled by the venue, so a dead or
    /// re-pointed pool must read as "no book" rather than take the fan-out down.
    function _bestLevel(address pool, bool isBid) private view returns (bool, uint256) {
        if (pool.code.length == 0) return (false, 0);

        uint256 gasFor = _stipend(BOOK_GAS);
        if (gasFor == 0) return (false, 0);

        try IBinaryPool(pool).getBookLevels{gas: gasFor}(isBid, 1) returns (IBinaryPool.Level[] memory levels) {
            if (levels.length != 0 && levels[0].price != 0) return (true, levels[0].price);
        } catch {}
        return (false, 0);
    }

    /// @dev Charges a desk for work the router is about to do on its behalf.
    function _debit(address desk, bytes32 marketId, uint256 amount) private {
        _gasCredit[desk] -= amount;
        totalGasCredit -= amount;
        emit Debited(desk, marketId, amount);
    }

    /// @dev Appends a desk to a market's settlement list unless it is already there.
    function _addInterested(bytes32 marketId, address desk) private {
        address[] storage list = _interested[marketId];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == desk) return;
        }
        list.push(desk);
    }

    /// @dev Rounds up, so a split never under-collects and leaves the bond covering the shortfall.
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
