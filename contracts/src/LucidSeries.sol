// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LucidTypes} from "./types/LucidTypes.sol";

/// @notice The slice of a DreamDEX `MarketCreator` this contract drives: one call, and nothing else.
///
/// @dev Declared here rather than imported because the creator is a separate deployment on the
/// venue's own contracts, and the operator may re-point this contract at a new one without either
/// side knowing anything about the other's implementation. `triggerRoll` is deliberately *not*
/// owner-gated on the creator — anyone may close the current window and open the next — which is
/// the entire reason a contract like this one can exist at all.
interface IMarketCreator {
    /// @notice Close the series' current window and open the next.
    /// @param seriesId The series to roll.
    function triggerRoll(uint32 seriesId) external;
}

/// @title LucidSeries
/// @notice Keeps a short-cadence window open when DreamDEX's own scheduler stops opening them.
///
/// @dev On 4 September short-cadence market creation on this venue stopped for hours and a team
/// building on it lost their product for the duration. The cause was not permissions and not a bug
/// in the venue: the `MarketCreator` the SDK advertises for testnet has rolled over six thousand
/// markets and its float is now zero. A creator with no float schedules no oracle questions, and a
/// series with no oracle questions does not roll. Every protocol pointed at that creator stops at
/// the same instant, and none of them can do anything about it.
///
/// @dev The way out was proved on Shannon end to end: an ordinary account can deploy its own
/// `MarketCreator`, run its own series, and the venue's oracle resolves it exactly as it resolves
/// the venue's own. A rolled 300-second window was answered one second after expiry with
/// `payoutNumerators = [10000000, 0]` against a pulled numeric answer of 7971864.
///
/// @dev Two facts from that run shape everything below.
///
/// First, the creator's own reactivity auto-roll does not work. Its callback burned 197.8M gas and
/// reverted: the roll itself fully succeeded and then the final re-subscribe to the precompile
/// reverted `PRECOMPILE_REVERTED` and unwound the lot. The team behind the neighbouring operator hit
/// the identical failure and moved to calling `triggerRoll` by hand. So the roll has to be driven
/// from outside the creator, which is what this contract is.
///
/// Second, a roll is expensive in both currencies. It measured 61.6M gas — it fits inside the
/// router's 100M handler limit, but only with a stipend sized for it — and it costs the creator
/// about 2.8 SOMI of float, being two oracle questions at 1.296 each plus the 0.2 resolve reserve.
/// Money that large cannot be spent on a code path that merely hopes to be right, so every refusal
/// below is a checked condition with its own event, and the float is guarded by a floor and a
/// daily cap that this contract cannot talk itself past.
///
/// @dev Like `LucidKeeper`, this contract owns no subscription. Somnia's precompile requires the
/// *subscribing* contract to hold 32 SOMI, and that bond is scarce, so the router's existing bond
/// is reused: `LucidRouter` calls the two hooks from inside its handlers and this contract is a
/// plain callee. The corollary is the hard rule of this file — past the router check, nothing here
/// may revert. A revert inside a handler does not fail one roll, it discards the entire firing for
/// every desk woken with it, and the router is charged for the gas regardless.
contract LucidSeries is Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Ceiling on the gas stipend handed to one `triggerRoll`.
    /// @dev A roll measured 61.6M on Shannon. The ceiling is above that rather than at it because
    /// the billing is asymmetric: headroom that is never touched costs nothing, and a roll cut off
    /// mid-flight is charged for in full and rolls nothing.
    uint256 public constant ROLL_GAS = 65_000_000;

    /// @notice The stipend below which a roll is refused rather than attempted.
    ///
    /// @dev Sized just above the 61.6M measurement. Without this floor a thin frame would hand
    /// `triggerRoll` less gas than it needs, the call would revert out of gas, and the log would
    /// blame the creator for a shortfall that was ours — sending whoever reads it to debug a
    /// contract that was working. `NO_GAS` says plainly whose fault it was.
    uint256 public constant MIN_ROLL_GAS = 62_000_000;

    /// @notice The gas this contract keeps for itself, never offered to the creator.
    /// @dev Held back so the counters can be written and the outcome emitted after the call
    /// returns. A roll nobody can see in the log is indistinguishable from one that never happened.
    uint256 public constant GAS_RESERVE = 100_000;

    /// @notice Multiple of the watched cadence used as the default staleness threshold.
    /// @dev Three missed windows, not one. A single late window is ordinary on a public testnet;
    /// three in a row is a scheduler that has stopped.
    uint32 public constant STALENESS_MULTIPLE = 3;

    /// @notice Floor under the default staleness threshold, in seconds.
    /// @dev A 60-second cadence would otherwise declare an outage after three minutes' worth of
    /// jitter. Below three minutes there is no evidence, only noise.
    uint32 public constant MIN_STALENESS = 180;

    /// @notice Rolls per UTC day allowed before the budget refuses, unless the owner changes it.
    /// @dev Twelve rolls is roughly one hour of a 300-second cadence, or about 34 SOMI. It is a
    /// deliberately small number: the cap exists so that a stuck loop or a misread outage costs an
    /// hour of float rather than the whole treasury.
    uint256 public constant DEFAULT_MAX_ROLLS_PER_DAY = 12;

    /// @notice Creator float below which rolling is refused, unless the owner changes it.
    /// @dev Thirty-five SOMI is the level below which `armFirstRoll` was observed to fail outright
    /// on Shannon. Rolling towards that line rather than stopping at it would leave the series in
    /// the exact state this contract exists to prevent: a creator that cannot schedule its oracle.
    uint256 public constant DEFAULT_MIN_CREATOR_FLOAT = 35 ether;

    /// @notice Reasons carried by `RollSkipped`, one per way of declining to spend the float.
    /// @dev Tags rather than seven event types, so one filter counts every refusal and adding a
    /// reason later does not change the log schema. Every path that declines to roll emits exactly
    /// one of these: "we decided not to" and "nothing happened" must never look the same from
    /// outside.
    bytes32 public constant REASON_OFF = "OFF";
    /// @notice The venue's own scheduler is alive, so `Failover` stands down. See {REASON_OFF}.
    bytes32 public constant REASON_VENUE_HEALTHY = "VENUE_HEALTHY";
    /// @notice The creator holds less than `minCreatorFloat`. See {REASON_OFF}.
    bytes32 public constant REASON_LOW_FLOAT = "LOW_FLOAT";
    /// @notice `rollsToday` has reached `maxRollsPerDay`. See {REASON_OFF}.
    bytes32 public constant REASON_DAILY_CAP = "DAILY_CAP";
    /// @notice Less than `intervalSec` has passed since the last roll. See {REASON_OFF}.
    bytes32 public constant REASON_TOO_SOON = "TOO_SOON";
    /// @notice No creator is configured, or the configured one has no code. See {REASON_OFF}.
    bytes32 public constant REASON_NO_SERIES = "NO_SERIES";
    /// @notice The frame could not spare `MIN_ROLL_GAS`. See {REASON_OFF}.
    bytes32 public constant REASON_NO_GAS = "NO_GAS";

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice How hard this contract tries to keep a window open.
    ///
    /// @dev `Failover` is the operating default, and the reason is arithmetic rather than taste.
    /// Each rolled window costs the creator about 2.8 SOMI, so a 300-second cadence run
    /// continuously is 12 windows an hour and **roughly 34 SOMI per hour**, 816 a day, which is not
    /// a rate any testnet float survives. `Failover` spends nothing at all while DreamDEX's own
    /// scheduler is rolling, and starts spending only once no venue market of the watched cadence
    /// has been seen for `stalenessSeconds` — the signature of the 4 September outage. It buys
    /// exactly the property that matters, which is that this protocol does not stop when the
    /// venue's creator runs dry, and it buys it for nothing on every day the venue is healthy.
    ///
    /// @dev `Continuous` is implemented properly because full independence from the venue's
    /// scheduler is a real thing to want — a desk that must have a window every interval regardless
    /// of who else is trading. It is simply not the mode this protocol operates in, at 34 SOMI an
    /// hour.
    ///
    /// @dev `Off` is the state to leave this contract in when it is deployed but not yet funded:
    /// the router may call the hooks, and nothing is ever spent.
    enum Mode {
        Off,
        Failover,
        Continuous
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The only address allowed to drive the two hooks.
    address public router;

    /// @notice How hard this contract currently tries to keep a window open.
    Mode public mode;

    /// @notice The `MarketCreator` that owns the series, and whose float pays for every roll.
    address public creator;

    /// @notice The series to roll on that creator.
    uint32 public seriesId;

    /// @notice The series' window length in seconds, and the cadence watched on the venue.
    uint32 public intervalSec;

    /// @notice Owner override for the staleness threshold, or zero to derive it from the cadence.
    /// @dev Zero rather than a written-out default so that changing the cadence moves the threshold
    /// with it. A 300-second series whose threshold was frozen at a 60-second series' 180 would
    /// declare an outage in the middle of an ordinary window. Read {stalenessSeconds} for the value
    /// actually in force.
    uint32 public stalenessOverride;

    /// @notice When a venue market of the watched cadence was last seen.
    /// @dev Seeded at deployment. A watcher that has never seen a market knows nothing about the
    /// venue, and treating ignorance as an outage would roll on the first tick after every deploy;
    /// seeding gives the venue one full staleness window to show itself.
    uint64 public lastVenueMarketAt;

    /// @notice When this contract last rolled a window, or zero if it never has.
    uint64 public lastRollAt;

    /// @notice UTC day index the `rollsToday` counter belongs to.
    uint64 public dayKey;

    /// @notice Rolls performed in the day `dayKey` names.
    uint32 public rollsToday;

    /// @notice Rolls allowed per UTC day.
    uint256 public maxRollsPerDay;

    /// @notice Creator float below which rolling is refused.
    uint256 public minCreatorFloat;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Only the router may drive the hooks.
    error NotRouter();
    /// @notice A series with a creator must have a non-zero window length.
    error BadInterval();
    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice The withdrawal recipient rejected the transfer.
    error WithdrawFailed();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A window was rolled, and the creator's float actually paid for it.
    /// @dev Emitted only when `triggerRoll` returned. Nothing here is an intention.
    /// @param seriesId The series rolled.
    /// @param gasUsed What the roll cost this frame, so the 61.6M measurement can be re-checked
    /// against live state rather than trusted.
    event Rolled(uint32 indexed seriesId, uint256 gasUsed);

    /// @notice A roll was declined, and why.
    /// @dev Indexed so an operator can count one reason across a day without reading the rest. The
    /// ordinary steady state of this contract is a stream of `VENUE_HEALTHY`, which is the venue
    /// working and this contract costing nothing.
    /// @param reason One of the `REASON_*` tags.
    event RollSkipped(bytes32 indexed reason);

    /// @notice A roll was attempted and the creator reverted.
    /// @dev Neither a refusal nor a roll, so it is neither `RollSkipped` nor `Rolled`. The revert
    /// is caught rather than propagated because this runs inside a reactivity handler.
    /// @param seriesId The series that was being rolled.
    /// @param reason The raw revert data from the creator.
    event RollFailed(uint32 indexed seriesId, bytes reason);

    /// @notice The operating mode changed.
    /// @param mode The mode now in force.
    event ModeSet(Mode mode);

    /// @notice The series this contract rolls changed.
    /// @param creator The creator holding the float.
    /// @param seriesId The series on it.
    /// @param intervalSec The window length, and the venue cadence now watched.
    event SeriesSet(address creator, uint32 seriesId, uint32 intervalSec);

    /// @notice The staleness threshold changed.
    /// @param stalenessSeconds The override now stored; zero means the cadence-derived default.
    event StalenessSet(uint32 stalenessSeconds);

    /// @notice The spending guards changed.
    /// @param maxRollsPerDay Rolls allowed per UTC day.
    /// @param minCreatorFloat Creator float below which rolling is refused.
    event BudgetSet(uint256 maxRollsPerDay, uint256 minCreatorFloat);

    /// @notice The router allowed to drive the hooks changed.
    /// @param router The new router.
    event RouterSet(address router);

    /// @notice The operator added to this contract's reserve.
    /// @param from Who sent it.
    /// @param amount How much, in wei.
    event Funded(address indexed from, uint256 amount);

    /// @notice Native balance left this contract.
    /// @param to Where it went.
    /// @param amount How much, in wei.
    event Withdrawn(address indexed to, uint256 amount);

    /// @param owner_ The operator that sets the mode, the series and the budget.
    /// @param router_ The router that drives the hooks, or zero to attach one later.
    constructor(address owner_, address router_) Ownable(owner_) {
        router = router_;

        // Failover, not Off: a contract deployed to cover an outage that has to be switched on by
        // hand is a contract that will be off during the outage. It still cannot spend anything
        // until a series is set, so the safe default and the useful default are the same one here.
        mode = Mode.Failover;

        maxRollsPerDay = DEFAULT_MAX_ROLLS_PER_DAY;
        minCreatorFloat = DEFAULT_MIN_CREATOR_FLOAT;

        // See {lastVenueMarketAt}: one staleness window of grace before ignorance becomes an alarm.
        lastVenueMarketAt = uint64(block.timestamp);
        dayKey = uint64(block.timestamp / 1 days);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Router hooks
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Record that the venue created a market, which is the only evidence its scheduler is
    /// alive.
    ///
    /// @dev Only a market of the watched cadence counts. An hourly window says nothing about
    /// whether the five-minute roller is running, and treating it as a heartbeat would mask exactly
    /// the outage this contract watches for.
    ///
    /// @dev This hook never rolls. In `Failover` a market that just arrived is proof there is
    /// nothing to stand in for, and in `Continuous` the roll is driven by the settlement tick
    /// instead, so that rolling stays one-per-window rather than one-per-venue-market.
    ///
    /// @dev The router forwards only markets of the venue it is armed on, and this contract's own
    /// series runs on its own venue, so this protocol's rolls are not seen here and cannot pass
    /// themselves off as the venue's heartbeat. Were a router ever armed on our own venue, the
    /// worst case is that `Failover` degrades to rolling once per staleness window instead of once
    /// per interval — still under the same cap, still under the same float floor.
    ///
    /// @dev Past the router check this cannot revert: it is reached from the router's
    /// `MarketCreated` handler, where a revert discards the whole firing.
    ///
    /// @param m The window the venue just created, as the router decoded it from the venue's log.
    function onVenueMarket(LucidTypes.MarketInfo calldata m) external {
        if (msg.sender != router) revert NotRouter();

        uint32 watched = intervalSec;
        if (watched != 0 && m.intervalSec == watched) lastVenueMarketAt = uint64(block.timestamp);
    }

    /// @notice Consider rolling a window, from the router's settlement schedule.
    ///
    /// @dev The settled window itself is deliberately unread. This hook is a clock, not
    /// information: during the outage it defends against there are no markets of the watched
    /// cadence settling at all, so a tick that only fired for the watched cadence would go silent
    /// exactly when it was needed. Any settlement the router wakes up for will do.
    ///
    /// @dev Past the router check this cannot revert, for the same reason as {onVenueMarket}.
    function onTick(LucidTypes.MarketInfo calldata) external {
        if (msg.sender != router) revert NotRouter();

        _maybeRoll();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Permissionless drive
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Consider rolling a window, from anywhere.
    ///
    /// @dev Permissionless on purpose, and it is the backstop for the worst version of the outage.
    /// The router's hooks only fire when the venue is doing something; if the venue goes quiet
    /// enough that no handler runs at all, the settlement tick stops arriving and `Failover` would
    /// never get the chance to take over. Anyone — an operator's cron, a desk owner, a bystander —
    /// can then drive it from here.
    ///
    /// @dev Permissionless costs nothing to allow, because the caller decides nothing: the mode,
    /// the cadence, the daily cap and the float floor are all checked on chain and a caller who
    /// disagrees with them gets a `RollSkipped` and their own gas back.
    function rollNow() external {
        _maybeRoll();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wiring
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set how hard this contract tries to keep a window open.
    /// @param m The new mode. See {Mode} for what `Continuous` costs per hour.
    function setMode(Mode m) external onlyOwner {
        mode = m;
        emit ModeSet(m);
    }

    /// @notice Point this contract at the series it rolls.
    ///
    /// @dev Neither `lastRollAt` nor `rollsToday` is reset here, deliberately. Both are guards on
    /// spending rather than facts about a particular series, and clearing them on a re-point would
    /// turn `setSeries` into a way for the owner to spend past the cadence guard and the daily cap
    /// by calling it in a loop.
    ///
    /// @param creator_ The creator holding the float, or zero to detach and roll nothing.
    /// @param seriesId_ The series on that creator.
    /// @param intervalSec_ The window length in seconds, and the venue cadence to watch.
    function setSeries(address creator_, uint32 seriesId_, uint32 intervalSec_) external onlyOwner {
        // A zero interval would make the cadence guard vacuous and the derived staleness threshold
        // meaningless, which is a configuration that can only spend money by accident.
        if (creator_ != address(0) && intervalSec_ == 0) revert BadInterval();

        creator = creator_;
        seriesId = seriesId_;
        intervalSec = intervalSec_;
        emit SeriesSet(creator_, seriesId_, intervalSec_);
    }

    /// @notice Set how long the venue may go without a watched-cadence market before it is
    /// considered down.
    /// @param seconds_ The threshold in seconds, or zero to go back to the cadence-derived default.
    function setStaleness(uint32 seconds_) external onlyOwner {
        stalenessOverride = seconds_;
        emit StalenessSet(seconds_);
    }

    /// @notice Set the two guards that stand between this contract and the creator's float.
    /// @param maxRollsPerDay_ Rolls allowed per UTC day. Zero stops rolling entirely.
    /// @param minCreatorFloat_ Creator float below which rolling is refused.
    function setBudget(uint256 maxRollsPerDay_, uint256 minCreatorFloat_) external onlyOwner {
        maxRollsPerDay = maxRollsPerDay_;
        minCreatorFloat = minCreatorFloat_;
        emit BudgetSet(maxRollsPerDay_, minCreatorFloat_);
    }

    /// @notice Set the router allowed to drive the hooks.
    /// @dev The router is a separate deployment that can be replaced; without this a new router
    /// would mean a new series contract, and the series is the thing holding the reserve.
    /// @param router_ The new router, or zero to stop accepting hook calls entirely.
    function setRouter(address router_) external onlyOwner {
        router = router_;
        emit RouterSet(router_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reserve
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add to the operator's reserve held here.
    /// @dev There is no `receive()`. A plain transfer into a contract whose whole job is to guard a
    /// large balance is indistinguishable from an accident, and this reserve is the operator's own
    /// money rather than anyone else's.
    function fund() external payable onlyOwner {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Move native balance out of this contract.
    ///
    /// @dev The reserve here is a large locked balance and it must never be one-way: a series that
    /// could take SOMI and not give it back would be a worse counterparty than the empty creator
    /// this contract exists to route around. It is also how the creator gets topped up — `to` is
    /// any address, and the creator's float is the address that usually needs it.
    ///
    /// @param to Recipient.
    /// @param amount How much to send, in wei.
    function withdrawNative(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Everything an operator needs to answer "why did it not roll".
    ///
    /// @dev `rollsToday` is reported against the current UTC day rather than against whichever day
    /// the counter was last written in, so a stale counter never reads as a spent budget.
    ///
    /// @return The mode in force.
    /// @return Whether a venue market of the watched cadence has been seen recently enough.
    /// @return When such a market was last seen, seeded at deployment.
    /// @return When this contract last rolled, or zero.
    /// @return Rolls already performed today.
    /// @return The creator's float, in wei. This is the number that ran out on 4 September.
    function status() external view returns (Mode, bool, uint64, uint64, uint32, uint256) {
        uint32 today = uint64(block.timestamp / 1 days) == dayKey ? rollsToday : 0;
        return (mode, _venueHealthy(), lastVenueMarketAt, lastRollAt, today, creator.balance);
    }

    /// @notice How long the venue may go without a watched-cadence market before it is considered
    /// down.
    /// @return The override if the owner set one, otherwise three cadences with a 180-second floor.
    function stalenessSeconds() public view returns (uint32) {
        uint32 override_ = stalenessOverride;
        if (override_ != 0) return override_;

        // Widened before the multiply, then clamped at both ends. A cadence near the top of a
        // uint32 is nonsense rather than a threat, but a silent wrap there would produce a tiny
        // staleness threshold and turn a nonsense cadence into continuous spending.
        uint256 derived = uint256(STALENESS_MULTIPLE) * intervalSec;
        if (derived < MIN_STALENESS) return MIN_STALENESS;
        if (derived > type(uint32).max) return type(uint32).max;

        // casting to 'uint32' is safe because the clamp above proved the value fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(derived);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Every reason to decline, in the order they are cheapest to be sure of, and then the
    /// roll. Nothing past the mode check can revert.
    ///
    /// The order is not arbitrary. `OFF` and `NO_SERIES` are facts about our own configuration and
    /// settle the question outright. `VENUE_HEALTHY` and `TOO_SOON` are facts about whether a roll
    /// is wanted at all. Only then do the two money guards run, so that a log line naming
    /// `DAILY_CAP` or `LOW_FLOAT` always means we would otherwise have spent — a budget refusal
    /// that fired for a window nobody wanted would be noise in the one place noise is expensive.
    function _maybeRoll() private {
        if (mode == Mode.Off) {
            emit RollSkipped(REASON_OFF);
            return;
        }

        address c = creator;
        // `code.length` as well as the zero check, and not only for tidiness: `triggerRoll` returns
        // nothing, so a call into an empty address would report success having executed nothing,
        // and this contract would emit `Rolled` for a window that does not exist. The same guard is
        // what keeps a codeless creator from escaping the `catch` below on any call that ever does
        // return data.
        if (c == address(0) || c.code.length == 0 || intervalSec == 0) {
            emit RollSkipped(REASON_NO_SERIES);
            return;
        }

        if (mode == Mode.Failover && _venueHealthy()) {
            emit RollSkipped(REASON_VENUE_HEALTHY);
            return;
        }

        // One window at a time. Without this the settlement tick would roll again for every market
        // in the same firing, and each of those is 2.8 SOMI.
        if (block.timestamp < uint256(lastRollAt) + intervalSec) {
            emit RollSkipped(REASON_TOO_SOON);
            return;
        }

        _rollDay();
        if (rollsToday >= maxRollsPerDay) {
            emit RollSkipped(REASON_DAILY_CAP);
            return;
        }

        // Read straight off the chain rather than from anything this contract was told. The float
        // is spent by the creator, outside this protocol's accounting, so a local mirror of it
        // would be wrong within one window.
        if (c.balance < minCreatorFloat) {
            emit RollSkipped(REASON_LOW_FLOAT);
            return;
        }

        uint256 gasFor = _stipend();
        if (gasFor == 0) {
            emit RollSkipped(REASON_NO_GAS);
            return;
        }

        _roll(c, gasFor);
    }

    /// @dev The call, and the bookkeeping around it.
    ///
    /// The clock and the counter are written *before* `triggerRoll`, not after. The creator is a
    /// contract this protocol does not own on the venue's side, and a re-entrant `rollNow` from
    /// inside it would otherwise find `lastRollAt` unmoved and `rollsToday` unincremented — which
    /// would make the daily cap not a cap. Both are restored when the call reverts, because a
    /// reverted roll spends nothing: that is precisely what the creator's own auto-roll did when it
    /// burned 197.8M gas and unwound the roll it had already completed.
    function _roll(address c, uint256 gasFor) private {
        uint32 sid = seriesId;

        uint64 previousRollAt = lastRollAt;
        lastRollAt = uint64(block.timestamp);
        ++rollsToday;

        uint256 before = gasleft();
        try IMarketCreator(c).triggerRoll{gas: gasFor}(sid) {
            emit Rolled(sid, before - gasleft());
        } catch (bytes memory reason) {
            lastRollAt = previousRollAt;
            --rollsToday;
            emit RollFailed(sid, reason);
        }
    }

    /// @dev Whether the venue's own scheduler has produced a watched-cadence market recently enough
    /// to be considered alive.
    function _venueHealthy() private view returns (bool) {
        return block.timestamp <= uint256(lastVenueMarketAt) + stalenessSeconds();
    }

    /// @dev Moves the daily budget onto today before it is read, on the UTC boundary the rest of
    /// this codebase uses. A counter left on yesterday's day would charge yesterday's rolls against
    /// today's cap and silently halve the budget.
    function _rollDay() private {
        // Casting to `uint64` is safe: a day index derived from a block timestamp needs about 20
        // bits, and a value that overflowed would already be far beyond the life of any chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 today = uint64(block.timestamp / 1 days);
        if (today == dayKey) return;

        dayKey = today;
        rollsToday = 0;
    }

    /// @dev What the creator can actually be given right now, or zero when that is less than a roll
    /// needs.
    ///
    /// The 63/64 rule means a callee never receives everything that is left, so asking for more
    /// than that silently truncates and the roll dies mid-flight having spent the frame. Sizing the
    /// stipend against what the frame can really give, and refusing outright below `MIN_ROLL_GAS`,
    /// is what keeps `NO_GAS` and `RollFailed` from being confused for one another.
    function _stipend() private view returns (uint256) {
        uint256 left = gasleft();
        if (left <= GAS_RESERVE) return 0;

        uint256 available = ((left - GAS_RESERVE) * 63) / 64;
        if (available < MIN_ROLL_GAS) return 0;

        return ROLL_GAS < available ? ROLL_GAS : available;
    }
}
