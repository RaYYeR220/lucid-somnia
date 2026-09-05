// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Somnia Foundation

pragma solidity 0.8.30;

/// @notice Somnia event handler interface
/// @title ISomniaEventHandler
/// @author Somnia Foundation
interface ISomniaEventHandler {

    /**
     * @notice Default function invoked for a matching reactivity subscription filter
     * @param emitter Smart contract that emitted the EVM event log(s)
     * @param eventTopics List of event topics associated with the event (event signature being first param)
     * @param data Event data for non-indexed event arguments. May be empty if event only has indexed params
     */
    function onEvent(
        address emitter,
        bytes32[] calldata eventTopics,
        bytes calldata data
    ) external;

}