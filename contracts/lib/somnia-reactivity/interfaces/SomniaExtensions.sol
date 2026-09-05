// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Somnia Foundation

pragma solidity 0.8.30;

import {ISomniaReactivityPrecompile} from "./ISomniaReactivityPrecompile.sol";
import {ISomniaEventHandler} from "./ISomniaEventHandler.sol";

/// @notice The Somnia Reactivity Precompile is a privileged contract at a fixed address
/// @title SomniaExtensions
/// @author Somnia Foundation
library SomniaExtensions {
    /// @notice Topic/origin/emitter matching criteria for a subscription.
    struct SubscriptionFilter {
        bytes32[4] eventTopics;
        address origin;
        address emitter;
    }

    /// @notice Gas and fee controls for subscription callback execution.
    struct SubscriptionOptions {
        uint64 priorityFeePerGas;
        uint64 maxFeePerGas;
        uint64 gasLimit;
    }

    /// @notice Fixed address for the Somnia Reactivity Precompile.
    address public constant SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS =
        address(0x0100);
    /// @notice Minimum balance required by a subscription owner.
    uint256 public constant SUBSCRIPTION_OWNER_MINIMUM_BALANCE = 32 ether;
    /// @notice Minimum protocol base fee per gas used in fee validation.
    uint256 public constant MINIMUM_BASE_FEE_PER_GAS = 6 gwei;
    /// @notice Maximum callback gas limit allowed for a single subscription.
    uint64 public constant MAXIMUM_HANDLER_GAS_LIMIT = 200_000_000;
    /// @notice Default priority fee per gas used when callers opt into defaults.
    uint64 public constant DEFAULT_PRIORITY_FEE_PER_GAS = 0;
    /// @notice Default max fee per gas used when callers opt into defaults.
    uint64 public constant DEFAULT_MAX_FEE_PER_GAS = 20 gwei;
    /// @notice Default callback gas limit used when callers opt into defaults.
    uint64 public constant DEFAULT_HANDLER_GAS_LIMIT = 10_000_000;

    error HandlerZeroAddress();
    error EmptyFilter();
    error GasLimitZero();
    error GasLimitExceeded();
    error InvalidMaxFeePerGas();
    error InsufficientBalance();
    error TimestampInPast();
    error BlockInPast();
    error UnsubscribeFailed();

    /// @notice Creates a subscription owned by the caller using filter and gas options.
    /// @param handler Address of the handler contract that receives callbacks.
    /// @param filter Filter criteria for matching logs.
    /// @param options Fee and gas options for callback execution.
    /// @return subscriptionId Newly created subscription identifier.
    function subscribe(
        address handler,
        SubscriptionFilter memory filter,
        SubscriptionOptions memory options
    ) internal returns (uint256 subscriptionId) {
        return _subscribe(handler, filter, options);
    }

    /// @notice Creates a schedule subscription for an absolute millisecond timestamp.
    /// @param handler Address of the handler contract that receives callbacks.
    /// @param timestampMillis Absolute unix timestamp in milliseconds.
    /// @param options Fee and gas options for callback execution.
    /// @return subscriptionId Newly created subscription identifier.
    function scheduleSubscriptionAtTimestamp(
        address handler,
        uint256 timestampMillis,
        SubscriptionOptions memory options
    ) internal returns (uint256 subscriptionId) {
        if (timestampMillis < ((block.timestamp + 1) * 1000) + 1) {
            revert TimestampInPast();
        }

        SubscriptionFilter memory filter = SubscriptionFilter({
            eventTopics: [
                ISomniaReactivityPrecompile.Schedule.selector,
                bytes32(timestampMillis),
                bytes32(0),
                bytes32(0)
            ],
            origin: address(0),
            emitter: SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS
        });

        return _subscribe(handler, filter, options);
    }

    /// @notice Creates a subscription triggered at a specific future block.
    /// @param handler Address of the handler contract that receives callbacks.
    /// @param blockNumber Future block number to trigger on.
    /// @param options Fee and gas options for callback execution.
    /// @return subscriptionId Newly created subscription identifier.
    function scheduleSubscriptionAtBlock(
        address handler,
        uint64 blockNumber,
        SubscriptionOptions memory options
    ) internal returns (uint256 subscriptionId) {
        if (blockNumber < block.number + 1) {
            revert BlockInPast();
        }

        SubscriptionFilter memory filter = SubscriptionFilter({
            eventTopics: [
                ISomniaReactivityPrecompile.BlockTick.selector,
                bytes32(uint256(blockNumber)),
                bytes32(0),
                bytes32(0)
            ],
            origin: address(0),
            emitter: SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS
        });

        return _subscribe(handler, filter, options);
    }

    /// @notice Creates a subscription triggered at a specific epoch.
    /// @param handler Address of the handler contract that receives callbacks.
    /// @param epochNumber Epoch number to trigger on.
    /// @param options Fee and gas options for callback execution.
    /// @return subscriptionId Newly created subscription identifier.
    function scheduleSubscriptionAtEpoch(
        address handler,
        uint64 epochNumber,
        SubscriptionOptions memory options
    ) internal returns (uint256 subscriptionId) {
        SubscriptionFilter memory filter = SubscriptionFilter({
            eventTopics: [
                ISomniaReactivityPrecompile.EpochTick.selector,
                bytes32(uint256(epochNumber)),
                bytes32(0),
                bytes32(0)
            ],
            origin: address(0),
            emitter: SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS
        });

        return _subscribe(handler, filter, options);
    }

    /// @notice Cancels a subscription.
    /// @param subscriptionId Existing subscription identifier.
    function unsubscribe(uint256 subscriptionId) internal {
        // Low-level call used to bypass false positives from Solidity safety checks
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS.call(
            abi.encodeWithSelector(ISomniaReactivityPrecompile.unsubscribe.selector, subscriptionId)
        );
        if (!success) revert UnsubscribeFailed();
    }

    /// @notice Fetches subscription details and owner for a subscription id.
    /// @param subscriptionId Existing subscription identifier.
    /// @return subscriptionData Stored subscription parameters.
    /// @return owner Address currently owning the subscription.
    function getSubscriptionInfo(
        uint256 subscriptionId
    )
        internal
        view
        returns (
            ISomniaReactivityPrecompile.SubscriptionData
                memory subscriptionData,
            address owner
        )
    {
        return
            ISomniaReactivityPrecompile(SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS)
                .getSubscriptionInfo(subscriptionId);
    }

    /// @notice Returns the library default fee and gas options for subscriptions.
    /// @return options Default subscription options struct.
    function defaultSubscriptionOptions()
        internal
        pure
        returns (SubscriptionOptions memory)
    {
        return
            SubscriptionOptions({
                priorityFeePerGas: DEFAULT_PRIORITY_FEE_PER_GAS,
                maxFeePerGas: DEFAULT_MAX_FEE_PER_GAS,
                gasLimit: DEFAULT_HANDLER_GAS_LIMIT
            });
    }

    /// @dev Internal helper used by all public subscription creation functions.
    function _subscribe(
        address handler,
        SubscriptionFilter memory filter,
        SubscriptionOptions memory options
    ) private returns (uint256 subscriptionId) {
        if (handler == address(0)) {
            revert HandlerZeroAddress();
        }
        if (!_hasAnyFilter(filter)) {
            revert EmptyFilter();
        }
        if (options.gasLimit == 0) {
            revert GasLimitZero();
        }
        if (options.gasLimit > MAXIMUM_HANDLER_GAS_LIMIT) {
            revert GasLimitExceeded();
        }
        if (
            options.maxFeePerGas != 0 &&
            options.priorityFeePerGas + MINIMUM_BASE_FEE_PER_GAS  >
            options.maxFeePerGas
        ) {
            revert InvalidMaxFeePerGas();
        }
        if (address(this).balance < SUBSCRIPTION_OWNER_MINIMUM_BALANCE) {
            revert InsufficientBalance();
        }

        return
            ISomniaReactivityPrecompile(SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS)
                .subscribe(_buildSubscriptionData(handler, filter, options));
    }

    /// @dev Returns true when at least one filter criterion is non-wildcard.
    function _hasAnyFilter(
        SubscriptionFilter memory filter
    ) private pure returns (bool hasAnyFilter) {
        return
            filter.origin != address(0) ||
            filter.emitter != address(0) ||
            filter.eventTopics[0] != bytes32(0) ||
            filter.eventTopics[1] != bytes32(0) ||
            filter.eventTopics[2] != bytes32(0) ||
            filter.eventTopics[3] != bytes32(0);
    }

    /// @dev Builds low-level precompile subscription payload from high-level inputs.
    function _buildSubscriptionData(
        address handler,
        SubscriptionFilter memory filter,
        SubscriptionOptions memory options
    )
        private
        pure
        returns (
            ISomniaReactivityPrecompile.SubscriptionData memory subscriptionData
        )
    {
        ISomniaReactivityPrecompile.SubscriptionData
            memory data = ISomniaReactivityPrecompile.SubscriptionData({
                eventTopics: filter.eventTopics,
                origin: filter.origin,
                caller: address(0),
                emitter: filter.emitter,
                handlerContractAddress: handler,
                handlerFunctionSelector: ISomniaEventHandler.onEvent.selector,
                priorityFeePerGas: options.priorityFeePerGas,
                maxFeePerGas: options.maxFeePerGas,
                gasLimit: options.gasLimit,
                isGuaranteed: false,
                isCoalesced: false
            });

        return data;
    }
}
