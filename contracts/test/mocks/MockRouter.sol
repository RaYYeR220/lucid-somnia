// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../../src/types/LucidTypes.sol";

/// @title MockRouter
/// @notice Records `onVerdict` calls, and can be told to revert.
/// @dev The revert mode exists to prove the brain survives a router that is broken, paused or
/// out of gas: the verdict must still be stored and the callback must still return cleanly.
contract MockRouter {
    error RouterIsDown();

    uint256 public calls;
    bool public shouldRevert;
    bytes32 public lastMarketId;
    LucidTypes.Verdict internal _lastVerdict;

    function setRevert(bool on) external {
        shouldRevert = on;
    }

    function lastVerdict() external view returns (LucidTypes.Verdict memory) {
        return _lastVerdict;
    }

    function onVerdict(bytes32 marketId, LucidTypes.Verdict calldata v) external {
        if (shouldRevert) revert RouterIsDown();
        calls++;
        lastMarketId = marketId;
        _lastVerdict = v;
    }
}
