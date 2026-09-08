// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISomniaEventHandler} from "@somnia/reactivity/interfaces/ISomniaEventHandler.sol";
import {ISomniaReactivityPrecompile} from "@somnia/reactivity/interfaces/ISomniaReactivityPrecompile.sol";

/// @title MockPrecompile
/// @notice Stand-in for Somnia's reactivity precompile, meant to be `vm.etch`ed at `0x0100`.
/// @dev The point of this mock is not to simulate reactivity — the chain does that, and it was
/// verified live. The point is to capture the exact `SubscriptionData` a contract asks for, so a
/// test can assert the gas limit, the topic filter and the emitter that will actually be committed
/// on-chain. A silent mistake in any of those fields costs a real subscription that never fires,
/// which is the single most expensive failure mode in this protocol.
///
/// @dev It also *fires* one-shots, and it fires them the way the chain does rather than the way a
/// caller would like. That distinction is not a detail: a mock that echoed a requested timestamp
/// back would let a subscriber key its work by that timestamp, pass every test, and then do
/// precisely nothing on chain — which is what happened. See `SCHEDULE_SKEW_MS`.
contract MockPrecompile is ISomniaReactivityPrecompile {
    /// @dev `Schedule(uint256)`, the system event a one-shot subscription fires. Spelled out rather
    /// than imported so this mock stays a model of the chain and not of any protocol on it.
    bytes32 internal constant TOPIC_SCHEDULE = keccak256("Schedule(uint256)");

    /// @notice How far behind the requested instant the chain's own `Schedule` actually lands.
    ///
    /// @dev Measured, not invented. A one-shot's filter matches "at or after `eventTopics[1]`", and
    /// what the chain delivers in that topic is the instant it really emitted at. Every timestamp
    /// this protocol books is a whole second times 1000, so every request ends in `000` — and the
    /// `Schedule` decoded from a live Shannon handler transaction
    /// (0x5775871466afcd7f10e9e7fb2037404f4ced0906f74585856788bc4bd09998ad) carried
    /// `1788719250073`. Seventy-three milliseconds is that measurement, and it is the default here
    /// so that every test taking the scheduled path exercises the real behaviour rather than a
    /// convenient one.
    uint256 public constant SCHEDULE_SKEW_MS = 73;
    /// @dev Every subscription ever requested, in call order. Index `i` has id `i + 1`.
    SubscriptionData[] internal _subs;
    address[] internal _owners;

    /// @dev Which ids the precompile still holds. An id leaves this set when it is cancelled and
    /// when it is reaped, and it never comes back: the chain does not resurrect a subscription.
    mapping(uint256 => bool) internal _live;

    /// @dev Every id passed to `unsubscribe`, in call order. Only accepted cancels are recorded,
    /// because a refused one cancelled nothing.
    uint256[] internal _unsubscribed;

    /// @notice A caller asked about, or tried to cancel, a subscription this contract does not hold.
    /// @dev Shared by both, because from a caller's side they are the same fact: the id names
    /// nothing. **This mock used to accept any id at all in `unsubscribe`**, and that leniency is
    /// exactly what let `LucidRouter.armVenue` ship with a re-arm path that reverts forever once
    /// the chain has reaped the subscription it still holds an id for. A mock that is kinder than
    /// the chain does not make a contract safer; it makes the test suite stop mentioning the way
    /// it breaks. See `LucidWatch`.
    error NoSuchSubscription(uint256 subscriptionId);

    /// @inheritdoc ISomniaReactivityPrecompile
    function subscribe(SubscriptionData calldata subscriptionData) external returns (uint256 subscriptionId) {
        _subs.push(subscriptionData);
        _owners.push(msg.sender);
        // Ids start at 1 so that a stored zero unambiguously means "no subscription".
        subscriptionId = _subs.length;
        _live[subscriptionId] = true;
        emit SubscriptionCreated(subscriptionId, msg.sender, subscriptionData);
    }

    /// @inheritdoc ISomniaReactivityPrecompile
    /// @dev Reverts on an id this contract does not hold, which is what Shannon does. The failure
    /// is not hypothetical: a subscription whose owner drops below the 32 SOMI floor is reaped by
    /// the chain, its owner goes on holding the id, and the cancel that id was for is refused from
    /// then on.
    function unsubscribe(uint256 subscriptionId) external {
        if (!_live[subscriptionId]) revert NoSuchSubscription(subscriptionId);

        _live[subscriptionId] = false;
        _unsubscribed.push(subscriptionId);
        emit SubscriptionRemoved(subscriptionId, msg.sender);
    }

    /// @notice Take a subscription away from its owner the way the chain does when the owner's
    /// balance falls through `SUBSCRIPTION_OWNER_MINIMUM_BALANCE`.
    /// @dev Deliberately not `unsubscribe`: the owner never asked, learns nothing, and is left
    /// holding an id that now names nothing. That gap is the whole failure mode, and a test cannot
    /// reach it through a cancel the owner performed on purpose.
    /// @param subscriptionId The id the chain drops.
    function reap(uint256 subscriptionId) external {
        if (!_live[subscriptionId]) revert NoSuchSubscription(subscriptionId);

        _live[subscriptionId] = false;
        emit SubscriptionRemoved(subscriptionId, _owners[subscriptionId - 1]);
    }

    /// @notice Whether this contract still holds `subscriptionId`.
    function isLive(uint256 subscriptionId) external view returns (bool) {
        return _live[subscriptionId];
    }

    /// @inheritdoc ISomniaReactivityPrecompile
    function getSubscriptionInfo(uint256 subscriptionId)
        external
        view
        returns (SubscriptionData memory subscriptionData, address owner)
    {
        if (!_live[subscriptionId]) revert NoSuchSubscription(subscriptionId);
        return (_subs[subscriptionId - 1], _owners[subscriptionId - 1]);
    }

    /// @notice How many subscriptions have been created.
    function subscriptionCount() external view returns (uint256) {
        return _subs.length;
    }

    /// @notice The `index`-th subscription request, in call order.
    function subscriptionAt(uint256 index) external view returns (SubscriptionData memory) {
        return _subs[index];
    }

    /// @notice The owner recorded for the `index`-th subscription request.
    function ownerAt(uint256 index) external view returns (address) {
        return _owners[index];
    }

    /// @notice How many `unsubscribe` calls have been made.
    function unsubscribeCount() external view returns (uint256) {
        return _unsubscribed.length;
    }

    /// @notice The `index`-th id passed to `unsubscribe`.
    function unsubscribedAt(uint256 index) external view returns (uint256) {
        return _unsubscribed[index];
    }

    /// @notice Fire the wake-up booked for `requestedMs`, carrying the timestamp the chain would
    /// really deliver: `requestedMs + SCHEDULE_SKEW_MS`, which is never the key it was booked under.
    /// @param handler The subscribing contract.
    /// @param requestedMs The absolute millisecond a one-shot was booked for.
    function fireSchedule(address handler, uint256 requestedMs) external {
        _fire(handler, requestedMs + SCHEDULE_SKEW_MS);
    }

    /// @notice Fire a `Schedule` carrying exactly `tsMillis`, whatever anybody requested.
    /// @dev The escape hatch for what a fixed skew cannot express: a wake-up that arrives before
    /// the work is due, one that arrives an hour late because the chain paused, one firing that
    /// stands for two instants at once. A subscriber that survives all of those is a subscriber
    /// that does not depend on any single firing arriving on time.
    /// @param handler The subscribing contract.
    /// @param tsMillis The absolute millisecond to put in `eventTopics[1]`.
    function fireScheduleAt(address handler, uint256 tsMillis) external {
        _fire(handler, tsMillis);
    }

    /// @dev Delivered from this contract's own address, because that is the only sender and the
    /// only emitter a handler will accept for a system event.
    function _fire(address handler, uint256 tsMillis) private {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = TOPIC_SCHEDULE;
        topics[1] = bytes32(tsMillis);

        ISomniaEventHandler(handler).onEvent(address(this), topics, "");
    }
}
