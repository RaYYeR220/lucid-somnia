// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @notice A stand-in for the DreamDEX `MarketCreator` that owns a series and pays for its rolls.
///
/// @dev It records what was called so a test can assert the creator was actually reached, and it
/// can be told to revert so the failure that shipped this whole contract — the creator's own
/// auto-roll completing the roll and then unwinding it — is exercised as the ordinary case it is.
///
/// @dev The float is the creator's *native balance*, not a number it reports, because that is what
/// `LucidSeries` reads: a balance cannot lie about itself and cannot revert. That leaves a test
/// needing to move a balance directly, so `setFloat` reaches for `vm.deal` rather than inventing a
/// reported float the contract under test would not look at.
contract MockMarketCreator {
    /// @dev Shaped like the real failure: the roll succeeds and something afterwards unwinds it.
    error PrecompileReverted();

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public rollCalls;
    uint32 public lastSeriesId;

    /// @dev Sampled inside the creator's own frame, which is the only place the stipend the series
    /// handed over is observable at all.
    uint256 public lastGasReceived;

    bool public revertOnRoll;

    function setRevertOnRoll(bool on) external {
        revertOnRoll = on;
    }

    /// @notice Set the creator's float to an exact amount.
    function setFloat(uint256 amount) external {
        VM.deal(address(this), amount);
    }

    function triggerRoll(uint32 seriesId) external {
        if (revertOnRoll) revert PrecompileReverted();

        lastGasReceived = gasleft();
        ++rollCalls;
        lastSeriesId = seriesId;
    }

    receive() external payable {}
}
