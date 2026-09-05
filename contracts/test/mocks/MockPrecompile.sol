// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISomniaReactivityPrecompile} from "@somnia/reactivity/interfaces/ISomniaReactivityPrecompile.sol";

/// @title MockPrecompile
/// @notice Stand-in for Somnia's reactivity precompile, meant to be `vm.etch`ed at `0x0100`.
/// @dev The point of this mock is not to simulate reactivity — the chain does that, and it was
/// verified live. The point is to capture the exact `SubscriptionData` a contract asks for, so a
/// test can assert the gas limit, the topic filter and the emitter that will actually be committed
/// on-chain. A silent mistake in any of those fields costs a real subscription that never fires,
/// which is the single most expensive failure mode in this protocol.
contract MockPrecompile is ISomniaReactivityPrecompile {
    /// @dev Every subscription ever requested, in call order. Index `i` has id `i + 1`.
    SubscriptionData[] internal _subs;
    address[] internal _owners;

    /// @dev Every id passed to `unsubscribe`, in call order.
    uint256[] internal _unsubscribed;

    /// @notice A caller asked about a subscription that was never created here.
    error NoSuchSubscription(uint256 subscriptionId);

    /// @inheritdoc ISomniaReactivityPrecompile
    function subscribe(SubscriptionData calldata subscriptionData) external returns (uint256 subscriptionId) {
        _subs.push(subscriptionData);
        _owners.push(msg.sender);
        // Ids start at 1 so that a stored zero unambiguously means "no subscription".
        subscriptionId = _subs.length;
        emit SubscriptionCreated(subscriptionId, msg.sender, subscriptionData);
    }

    /// @inheritdoc ISomniaReactivityPrecompile
    function unsubscribe(uint256 subscriptionId) external {
        _unsubscribed.push(subscriptionId);
        emit SubscriptionRemoved(subscriptionId, msg.sender);
    }

    /// @inheritdoc ISomniaReactivityPrecompile
    function getSubscriptionInfo(uint256 subscriptionId)
        external
        view
        returns (SubscriptionData memory subscriptionData, address owner)
    {
        if (subscriptionId == 0 || subscriptionId > _subs.length) revert NoSuchSubscription(subscriptionId);
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
}
