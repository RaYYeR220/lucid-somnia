// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../../src/types/LucidTypes.sol";

/// @title MockBrain
/// @notice Records verdict requests and the native currency paid for them.
/// @dev The real brain spends 0.213 SOMI of a shared float per request, so the number the router
/// cares about is not "did it ask" but "how many times did it ask, and with how much". Both are
/// recorded here. The revert modes stand in for a brain that is out of float or paused.
contract MockBrain {
    /// @notice Deliberate failure used by the revert modes.
    error BrainIsDown();

    uint256 public fee = 0.213 ether;
    bool public revertOnQuote;
    bool public revertOnRequest;

    uint256 public requestCount;
    bytes32 public lastMarketId;
    uint256 public lastValue;
    uint256 public lastPBookBps;
    uint256 public lastRecentLength;
    uint256 public totalReceived;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setRevertModes(bool quote_, bool request_) external {
        revertOnQuote = quote_;
        revertOnRequest = request_;
    }

    function quote() external view returns (uint256) {
        if (revertOnQuote) revert BrainIsDown();
        return fee;
    }

    function requestVerdict(
        bytes32 marketId,
        LucidTypes.MarketInfo calldata,
        uint256 pBookBps,
        uint16[] calldata recentOutcomes
    ) external payable returns (uint256 requestId) {
        if (revertOnRequest) revert BrainIsDown();

        requestCount++;
        lastMarketId = marketId;
        lastValue = msg.value;
        lastPBookBps = pBookBps;
        lastRecentLength = recentOutcomes.length;
        totalReceived += msg.value;
        return requestCount;
    }

    receive() external payable {}
}
