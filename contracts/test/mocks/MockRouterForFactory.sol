// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockRouterForFactory
/// @notice Records `registerDesk` calls so the suite can prove a new desk is announced to the
/// only contract that owns a reactivity subscription.
/// @dev Deliberately not the full `ILucidRouter`: the factory calls exactly one router function,
/// and a mock that implements more than that invites tests to assert things the factory does not do.
contract MockRouterForFactory {
    /// @notice The router must never see the same desk twice; a duplicate means the factory
    /// handed out one address to two users.
    error DeskAlreadyRegistered(address desk);

    address[] public registered;
    mapping(address => bool) public isRegistered;

    function registerDesk(address desk) external {
        if (isRegistered[desk]) revert DeskAlreadyRegistered(desk);
        isRegistered[desk] = true;
        registered.push(desk);
    }

    function registeredCount() external view returns (uint256) {
        return registered.length;
    }

    function allRegistered() external view returns (address[] memory) {
        return registered;
    }
}
