// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Canonical interface for Somnia's native Agent Requester contract.
/// ABI verified 2026-05-22 against the live portal:
///   https://agents.testnet.somnia.network/agent/12847293847561029384
/// Testnet (Shannon, chain 50312): 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776
///
/// Deposit formula (from portal deposit UI):
///   deposit = getRequestDeposit() + PER_AGENT_EXECUTION_COST * subcommitteeSize
///   PER_AGENT_EXECUTION_COST = 0.07 ether (70000000000000000 wei)
///   e.g. 3 runners: 0.03 floor + 0.21 reward = 0.24 STT total
interface IAgentRequester {
    enum ConsensusType {
        Majority,
        Threshold
    }

    enum ResponseStatus {
        None,    // 0 - Default zero value (uninitialized storage)
        Pending, // 1 - Awaiting responses
        Success, // 2 - Consensus reached normally
        Failed,  // 3 - Validators reported failure
        TimedOut // 4 - Request timed out
    }

    struct Response {
        address validator;
        bytes result;
        ResponseStatus status;
        uint256 receipt;
        uint256 timestamp;
        uint256 executionCost;
    }

    /// @dev Verified 15-field on-chain consensus state struct (portal Solidity tab, 2026-05-22).
    struct Request {
        uint256 id;
        address requester;
        address callbackAddress;
        bytes4 callbackSelector;
        address[] subcommittee;
        Response[] responses;
        uint256 responseCount;
        uint256 failureCount;
        uint256 threshold;
        uint256 createdAt;
        uint256 deadline;
        ResponseStatus status;
        ConsensusType consensusType;
        uint256 remainingBudget;
        uint256 perAgentBudget;
    }

    function createRequest(
        uint256 agentId,
        address callbackAddress,
        bytes4 callbackSelector,
        bytes calldata payload
    ) external payable returns (uint256 requestId);

    function createAdvancedRequest(
        uint256 agentId,
        address callbackAddress,
        bytes4 callbackSelector,
        bytes calldata payload,
        uint256 subcommitteeSize,
        uint256 threshold,
        ConsensusType consensusType,
        uint256 timeout
    ) external payable returns (uint256 requestId);

    function getRequestDeposit() external view returns (uint256);

    function getAdvancedRequestDeposit(uint256 subcommitteeSize) external view returns (uint256);
}

/// @notice Callback interface a consumer of IAgentRequester must implement.
/// Signature verified 2026-05-22 against portal Solidity tab (handleResponse).
interface IAgentConsumer {
    function handleResponse(
        uint256 requestId,
        IAgentRequester.Response[] memory responses,
        IAgentRequester.ResponseStatus status,
        IAgentRequester.Request memory request
    ) external;
}

/// @notice The pre-deployed LLM Inference base agent (agentId 12847293847561029384).
/// Used only for its function selectors when ABI-encoding the request payload.
/// Signatures verified 2026-05-22 against portal Solidity tab.
interface ILLMInferenceAgent {
    /// @dev inferNumber selector verified from portal: same as IAgent.inferNumber in canonical code.
    /// Returns int256 (signed — clamp to 0..100 before use as a score).
    function inferNumber(
        string calldata prompt,
        string calldata system,
        int256 minValue,
        int256 maxValue,
        bool chainOfThought
    ) external returns (int256);

    function inferString(
        string calldata prompt,
        string calldata system,
        bool chainOfThought,
        string[] calldata allowedValues
    ) external returns (string memory);
}
