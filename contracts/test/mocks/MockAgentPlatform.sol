// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAgentRequester, IAgentConsumer} from "../../src/interfaces/IAgentRequester.sol";
import {IAgentPriceConsumer} from "../../src/LucidBrain.sol";

/// @title MockAgentPlatform
/// @notice Stands in for Somnia's agent platform at 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776.
/// @dev The live platform answers asynchronously from validator transactions, which no unit test
/// can reproduce. This mock keeps the two halves a consumer actually depends on: the exact request
/// shape it records, and a `deliver` hook that replays any committee outcome — including the ugly
/// ones the real network only produces once in a thousand windows.
///
/// A verdict now takes two committee calls, and the whole point of the deadline guard is what
/// happens *between* them, so every request is kept rather than only the last one and the two
/// callbacks are delivered independently. A test can let a price land and then stall for a minute
/// before the inference, exactly as a slow validator would.
contract MockAgentPlatform is IAgentRequester {
    /// @notice Every argument of one `createAdvancedRequest`, plus the value that came with it.
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
    error NoSuchRequest(uint256 requestId);

    uint256 public nextRequestId = 1000;
    uint256 public requestCount;
    uint256 internal _flatDeposit;
    mapping(uint256 => uint256) internal _advancedDeposit;
    Recorded[] internal _all;
    /// @dev One past the index, so a never-recorded id reads as zero rather than as request 0.
    mapping(uint256 requestId => uint256 indexPlusOne) internal _indexOf;

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
        return _all[_all.length - 1];
    }

    /// @notice The n-th request this platform received, oldest first.
    function requestAt(uint256 index) external view returns (Recorded memory) {
        return _all[index];
    }

    /// @notice The request that was answered with a given id.
    function requestById(uint256 requestId) external view returns (Recorded memory) {
        uint256 slot = _indexOf[requestId];
        if (slot == 0) revert NoSuchRequest(requestId);
        return _all[slot - 1];
    }

    /// @notice The id the n-th request was issued under.
    function idAt(uint256 index) external pure returns (uint256) {
        return 1000 + index;
    }

    /// @notice Push an arbitrary committee outcome into a consumer's verdict callback.
    function deliver(address consumer, uint256 requestId, Response[] calldata responses, ResponseStatus status)
        external
    {
        IAgentConsumer(consumer).handleResponse(requestId, responses, status, _request(consumer, requestId, status));
    }

    /// @notice Push an arbitrary committee outcome into a consumer's price callback.
    /// @dev Separate entry point rather than a switch on the recorded selector, because a test that
    /// wants to deliver a price to a verdict request — or the other way round — is testing whether
    /// the consumer keeps its two stages apart, and the mock must let it try.
    function deliverPrice(address consumer, uint256 requestId, Response[] calldata responses, ResponseStatus status)
        external
    {
        IAgentPriceConsumer(consumer).handlePrice(requestId, responses, status, _request(consumer, requestId, status));
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
        _all.push(
            Recorded({
                agentId: agentId,
                callbackAddress: callbackAddress,
                callbackSelector: callbackSelector,
                payload: payload,
                subcommitteeSize: subcommitteeSize,
                threshold: threshold,
                consensusType: consensusType,
                timeout: timeout,
                value: msg.value
            })
        );
        requestCount++;
        requestId = nextRequestId++;
        _indexOf[requestId] = _all.length;
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

    function _request(address consumer, uint256 requestId, ResponseStatus status)
        internal
        view
        returns (Request memory request)
    {
        request.id = requestId;
        request.requester = address(this);
        request.callbackAddress = consumer;
        request.status = status;
    }
}
