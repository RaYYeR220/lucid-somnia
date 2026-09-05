// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBinaryMarket} from "../../src/interfaces/IDreamDex.sol";

/// @title MockMarket
/// @notice The per-window BinaryMarket, reduced to the one read that decides a settlement.
/// @dev `winningOutcome()` was removed from the protocol and now reverts, so the only supported
/// way to learn the result is the payout vector, with the winner as its argmax. A voided market
/// pays both legs half, which is why the vector matters and a single winner index does not.
contract MockMarket is IBinaryMarket {
    /// @notice What the live market throws while it is still trading.
    error NotResolved();

    uint256[] internal _payoutNumerators;
    bool public revertOnRead;
    bool internal _resolved;
    bool internal _voided;
    uint8 internal _status;
    uint64 internal _expiry;

    function setPayoutNumerators(uint256[] calldata nums) external {
        delete _payoutNumerators;
        for (uint256 i; i < nums.length; ++i) {
            _payoutNumerators.push(nums[i]);
        }
        _resolved = true;
        _status = 4;
    }

    /// @notice Make the payout read revert, standing in for a window that has not resolved.
    function setRevertOnRead(bool on) external {
        revertOnRead = on;
    }

    function setExpiry(uint64 expiry_) external {
        _expiry = expiry_;
    }

    function payoutNumerators() external view returns (uint256[] memory) {
        if (revertOnRead) revert NotResolved();
        return _payoutNumerators;
    }

    function isResolved() external view returns (bool) {
        return _resolved;
    }

    function isVoided() external view returns (bool) {
        return _voided;
    }

    function status() external view returns (uint8) {
        return _status;
    }

    function expiry() external view returns (uint64) {
        return _expiry;
    }

    function settlementWindow() external pure returns (uint64) {
        return 300;
    }

    function voidExpired() external {}
}
