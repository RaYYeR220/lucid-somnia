// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../types/LucidTypes.sol";

/// @notice The router owns every reactivity subscription, because the precompile requires the
/// subscribing contract to hold at least 32 SOMI. Desks never subscribe; they are dispatched to.
interface ILucidRouter {
    function armVenue(address module, bytes32 venueId_) external;
    function registerDesk(address desk) external;
    function setDeskArmed(address desk, bool on) external;
    function topUp(address desk) external payable;
    function gasCreditOf(address desk) external view returns (uint256);
    function onVerdict(bytes32 marketId, LucidTypes.Verdict calldata v) external;
    function follow(address leader, address follower, uint16 scaleBps) external;
    function unfollow(address leader, address follower) external;
    function marketOf(bytes32 marketId) external view returns (LucidTypes.MarketInfo memory);
}

/// @notice A non-custodial desk. Only the router may drive it, and it never reverts when driven:
/// a revert inside a reactivity handler would take down every other desk in the same fan-out.
interface ILucidDesk {
    function initialize(address owner_, address router_, address brain_) external;
    function setPolicy(LucidTypes.Policy calldata p) external;
    function arm(bool on) external;
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function fundFromFaucet(uint256 amount) external;
    function preCheck(LucidTypes.MarketInfo calldata m) external view returns (bool);
    function onVerdict(LucidTypes.MarketInfo calldata m, LucidTypes.Verdict calldata v, uint256 pBookBps)
        external;
    function onSettlement(LucidTypes.MarketInfo calldata m) external;
    function onLeaderTrade(LucidTypes.MarketInfo calldata m, uint8 kind, uint256 stake) external;
    function equity() external view returns (uint256);
    function policy() external view returns (LucidTypes.Policy memory);
    function state() external view returns (LucidTypes.DeskState memory);
    function owner() external view returns (address);
}

/// @notice Wraps Somnia's native agent committee. Every failure path still produces a verdict
/// with ok=false, so the desk can refuse explicitly instead of hanging.
interface ILucidBrain {
    function requestVerdict(
        bytes32 marketId,
        LucidTypes.MarketInfo calldata m,
        uint256 pBookBps,
        uint16[] calldata recentOutcomes
    ) external payable returns (uint256 requestId);

    function verdictOf(bytes32 marketId) external view returns (LucidTypes.Verdict memory);
    function quote() external view returns (uint256 weiNeeded);
}
