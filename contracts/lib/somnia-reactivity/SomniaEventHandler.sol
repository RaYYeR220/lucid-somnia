// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Somnia Foundation

pragma solidity 0.8.30;

import {ISomniaEventHandler} from "./interfaces/ISomniaEventHandler.sol";
import {SomniaExtensions} from "./interfaces/SomniaExtensions.sol";
import {IERC165} from "./interfaces/IERC165.sol";

/// @notice Abstract smart contract implementing native on-chain reactivity safely with reduced boilerplate
/// @dev The _onEvent virtual method must be overridden to define logic executed when subscription callbacks are invoked by the chain
/// @dev The contract is deemed upgrade safe due to the absence of storage variables
/// @title SomniaEventHandler
/// @author Somnia Foundation
abstract contract SomniaEventHandler is IERC165, ISomniaEventHandler {
    error OnlyReactivityPrecompile();

    /// @inheritdoc ISomniaEventHandler
    function onEvent(
        address emitter,
        bytes32[] calldata eventTopics,
        bytes calldata data
    ) external override {
        // Ensure only privileged execution is permitted since the receiving contract may execute its own side effects i.e. releasing prize money
        require(
            msg.sender == SomniaExtensions.SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS,
            OnlyReactivityPrecompile()
        );
        _onEvent(emitter, eventTopics, data);
    }

    /// @notice Returns whether this contract supports the requested interface id.
    /// @param interfaceId Interface identifier as defined by ERC-165.
    /// @dev Allows the Somnia reactivity precompile to reason about support for reactivity subscriptions.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return type(IERC165).interfaceId == interfaceId
            || type(ISomniaEventHandler).interfaceId == interfaceId;
    }

    /**
     * @notice Handles a verified callback dispatched by the reactivity precompile.
     * @dev Implementing contract must override to define what logic it wants to execute for subscription callbacks
     * @param emitter Smart contract that emitted the EVM event log
     * @param eventTopics List of event topics associated with the event (event signature being first param)
     * @param data Event data for non-indexed event arguments. May be empty if event only has indexed params
     */
    function _onEvent(
        address emitter,
        bytes32[] calldata eventTopics,
        bytes calldata data
    ) internal virtual;
}