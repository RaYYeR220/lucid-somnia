// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Somnia Foundation

pragma solidity 0.8.30;

/// @notice Somnia reactivity precompile interface and related data structures
/// @title ISomniaReactivityPrecompile
/// @author Somnia Foundation
interface ISomniaReactivityPrecompile {
    /// @notice Data structure representing a subscription
    struct SubscriptionData {
        // Topic filter, use 0x0 to indicate a wildcard or unused topic
        bytes32[4] eventTopics;
        //  Origin (tx.origin) filter, use address(0) to indicate a wildcard
        address origin;
        // Reserved for future use, use address(0)
        address caller;
        // Contract emitting the event filter, use address(0) to indicate a wildcard
        address emitter;
        // The address of the contract that will handle the event
        address handlerContractAddress;
        // The function selector in the handler contract, defaults to ISomniaEventHandler.onEvent
        bytes4 handlerFunctionSelector;
        // Extra fee per gas paid to validators to prioritize this event handling
        uint64 priorityFeePerGas;
        // Maximum fee per gas the subscriber is willing to pay (base fee + priority fee)
        uint64 maxFeePerGas;
        // Maximum gas that will be provisioned per subscription callback
        uint64 gasLimit;
        // Whether the event handling is guaranteed, i.e. moved to the next block if current is full
        bool isGuaranteed;
        // Whether multiple events can be coalesced into a single handling call per block
        bool isCoalesced;
    }

    /// @notice System tick emitted at the end of each block.
    /// @param blockNumber Current block number.
    event BlockTick(uint64 indexed blockNumber);

    /// @notice System tick emitted at epoch boundaries.
    /// @param epochNumber Current epoch number.
    /// @param blockNumber Current block number.
    event EpochTick(uint64 indexed epochNumber, uint64 indexed blockNumber);

    /// @notice Scheduled system event emitted at the requested timestamp.
    /// @param timestampMillis Timestamp in milliseconds.
    event Schedule(uint256 indexed timestampMillis);

    /// @notice Emitted when a new subscription is created
    /// @param subscriptionId New subscription identifier.
    /// @param owner Owner of the created subscription.
    /// @param subscriptionData Persisted subscription payload.
    event SubscriptionCreated(
        uint256 indexed subscriptionId,
        address indexed owner,
        SubscriptionData subscriptionData
    );

    /// @notice Emitted when a subscription is removed
    /// @param subscriptionId Removed subscription identifier.
    /// @param owner Owner of the removed subscription.
    event SubscriptionRemoved(
        uint256 indexed subscriptionId,
        address indexed owner
    );

    /**
     * @notice Creates a new Solidity subscription
     * @dev Cost: SUBSCRIPTION_MANAGEMENT_GAS_COST (~210k GAS)
     * @dev The caller becomes the owner of the subscription.
     * @dev The subscription starts being active immediately.
     * @param subscriptionData Defines the parameters for the subscription incl the handler contract
     * @return subscriptionId The subscription ID assigned to the new subscription
     */
    function subscribe(
        SubscriptionData calldata subscriptionData
    ) external returns (uint256 subscriptionId);

    /**
     * @notice Cancels a Solidity event subscription
     * @dev It can only be called by the owner
     * @dev Cost: SUBSCRIPTION_MANAGEMENT_GAS_COST (~210K GAS)
     * @param subscriptionId Unique subscription identifier
     */
    function unsubscribe(uint256 subscriptionId) external;

    /**
     * @notice Gets detailed information about a specific subscription
     * @param subscriptionId The unique subscription identifier
     * @return subscriptionData The recorded subscription information
     * @return owner The owner of the subscription that can make changes and pays for invocations
     */
    function getSubscriptionInfo(
        uint256 subscriptionId
    )
        external
        view
        returns (SubscriptionData memory subscriptionData, address owner);
}
