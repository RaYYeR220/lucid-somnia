// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAgentRequester, IAgentConsumer} from "../../src/interfaces/IAgentRequester.sol";

/// @title MockAgentPlatform
/// @notice Stands in for Somnia's agent platform at 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776.
/// @dev The live platform answers asynchronously from validator transactions, which no unit test
/// can reproduce. This mock keeps the two halves a consumer actually depends on: the exact request
/// shape it records, and a `deliver` hook that replays any committee outcome — including the ugly
/// ones the real network only produces once in a thousand windows.
contract MockAgentPlatform is IAgentRequester {
    /// @notice Every argument of the last `createAdvancedRequest`, plus the value that came with it.
    struct Recorded {
        uint256 agentId;
        address callbackAddress;
        bytes4 callbackSelector;
        bytes payload;
        uint256 subcommitteeSize;
        uint256 threshold;
        ConsensusType consensusType;
        uint256 timeout;
        uint256 value;
    }

    error NotImplemented();

    uint256 public nextRequestId = 1000;
    uint256 public requestCount;
    uint256 internal _flatDeposit;
    mapping(uint256 => uint256) internal _advancedDeposit;
    Recorded internal _last;

    /// @notice Set what `getAdvancedRequestDeposit(size)` reports, so a test can pin the fee formula.
    function setDeposit(uint256 subcommitteeSize, uint256 amount) external {
        _advancedDeposit[subcommitteeSize] = amount;
    }

    /// @notice Set what `getRequestDeposit()` reports.
    function setFlatDeposit(uint256 amount) external {
        _flatDeposit = amount;
    }

    /// @notice The last recorded request, including its `bytes` payload.
    function lastRequest() external view returns (Recorded memory) {
        return _last;
    }

    /// @notice Push an arbitrary committee outcome into a consumer's callback, as the platform would.
    function deliver(address consumer, uint256 requestId, Response[] calldata responses, ResponseStatus status)
        external
    {
        Request memory request;
        request.id = requestId;
        request.requester = address(this);
        request.callbackAddress = consumer;
        request.status = status;
        IAgentConsumer(consumer).handleResponse(requestId, responses, status, request);
    }

    // ── IAgentRequester ───────────────────────────────────────────────────────

    function createAdvancedRequest(
        uint256 agentId,
        address callbackAddress,
        bytes4 callbackSelector,
        bytes calldata payload,
        uint256 subcommitteeSize,
        uint256 threshold,
        ConsensusType consensusType,
        uint256 timeout
    ) external payable returns (uint256 requestId) {
        _last = Recorded({
            agentId: agentId,
            callbackAddress: callbackAddress,
            callbackSelector: callbackSelector,
            payload: payload,
            subcommitteeSize: subcommitteeSize,
            threshold: threshold,
            consensusType: consensusType,
            timeout: timeout,
            value: msg.value
        });
        requestCount++;
        requestId = nextRequestId++;
    }

    function createRequest(uint256, address, bytes4, bytes calldata) external payable returns (uint256) {
        revert NotImplemented();
    }

    function getRequestDeposit() external view returns (uint256) {
        return _flatDeposit;
    }

    function getAdvancedRequestDeposit(uint256 subcommitteeSize) external view returns (uint256) {
        return _advancedDeposit[subcommitteeSize];
    }
}
