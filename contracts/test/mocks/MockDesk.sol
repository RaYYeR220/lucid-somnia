// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../../src/types/LucidTypes.sol";
import {ILucidDesk} from "../../src/interfaces/ILucid.sol";

/// @title MockDesk
/// @notice Minimal `ILucidDesk` stand-in used as the clone implementation in factory tests.
/// @dev It only has to prove three things about the factory: that each clone is a fresh contract
/// with its own storage, that `initialize` is one-shot (so a hijacker cannot re-own a live desk),
/// and that the policy handed to `createDesk` actually reaches the clone.
contract MockDesk is ILucidDesk {
    /// @notice A clone may only be initialised once; a second call is an attempted takeover.
    error AlreadyInitialized();

    uint256 public initCalls;
    uint256 public policyCalls;

    address internal _owner;
    address public router;
    address public brain;

    LucidTypes.Policy internal _policy;
    LucidTypes.DeskState internal _state;

    function initialize(address owner_, address router_, address brain_) external {
        if (initCalls != 0) revert AlreadyInitialized();
        initCalls = 1;
        _owner = owner_;
        router = router_;
        brain = brain_;
    }

    function setPolicy(LucidTypes.Policy calldata p) external {
        policyCalls++;
        _policy = p;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function policy() external view returns (LucidTypes.Policy memory) {
        return _policy;
    }

    function state() external view returns (LucidTypes.DeskState memory) {
        return _state;
    }

    // ── Rest of the ILucidDesk surface. The factory never touches these, so they stay inert
    //    rather than growing behaviour the factory suite would then have to reason about. ──
    function arm(bool) external {}
    function deposit(uint256) external {}
    function withdraw(uint256) external {}
    function fundFromFaucet(uint256) external {}

    function preCheck(LucidTypes.MarketInfo calldata) external pure returns (bool) {
        return false;
    }

    function onVerdict(LucidTypes.MarketInfo calldata, LucidTypes.Verdict calldata, uint256) external {}
    function onSettlement(LucidTypes.MarketInfo calldata) external {}
    function onLeaderTrade(LucidTypes.MarketInfo calldata, uint8, uint256) external {}

    function equity() external pure returns (uint256) {
        return 0;
    }
}
