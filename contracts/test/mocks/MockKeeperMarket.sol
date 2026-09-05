// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice A stand-in for one window's `BinaryMarket`, limited to what the keeper reads and calls.
///
/// @dev The three reads are separately breakable because each of them is a precondition the keeper
/// must not guess at: without a readable status or window it has no way to tell a stuck market from
/// a settled one, and voiding on a guess would destroy a real answer.
contract MockKeeperMarket {
    error MarketIsDown();
    error NotVoidable();

    uint64 public expiryTs;
    uint64 public window;
    bool public resolved;

    uint256 public voidCalls;

    bool public revertIsResolved;
    bool public revertExpiry;
    bool public revertWindow;
    bool public revertVoid;

    constructor(uint64 expiry_, uint64 settlementWindow_) {
        expiryTs = expiry_;
        window = settlementWindow_;
    }

    function setResolved(bool on) external {
        resolved = on;
    }

    function setReverts(bool isResolved_, bool expiry_, bool window_, bool void_) external {
        revertIsResolved = isResolved_;
        revertExpiry = expiry_;
        revertWindow = window_;
        revertVoid = void_;
    }

    function isResolved() external view returns (bool) {
        if (revertIsResolved) revert MarketIsDown();
        return resolved;
    }

    function expiry() external view returns (uint64) {
        if (revertExpiry) revert MarketIsDown();
        return expiryTs;
    }

    function settlementWindow() external view returns (uint64) {
        if (revertWindow) revert MarketIsDown();
        return window;
    }

    function voidExpired() external {
        if (revertVoid) revert NotVoidable();
        ++voidCalls;
    }
}
