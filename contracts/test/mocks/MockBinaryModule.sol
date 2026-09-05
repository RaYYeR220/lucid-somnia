// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockBinaryModule
/// @notice Stands in for DreamDEX's BinaryMarketsModule at 0x3ecC694Cef705358864a646142ac17A90E29e388.
/// @dev The relay's whole job is forwarding one exact call, so this mock records every argument
/// byte-for-byte rather than a summary: a relay that drops `venueId` or swaps `nonce` and
/// `deadline` would still "work" against a laxer mock and then fail silently on the live venue.
/// It can also be told to revert per owner, because the interesting relay behaviour is what
/// happens to the *other* queued redemptions when one of them fails.
contract MockBinaryModule {
    /// @notice One recorded `redeemFor` invocation, in the protocol's argument order.
    struct Call {
        address owner;
        uint256 nonce;
        uint256 deadline;
        bytes sig;
        uint32 operatorId;
        bytes32 venueId;
        bytes32 marketId;
        uint8 outcomeIdx;
        uint256 amount;
    }

    /// @dev The failure a real redemption surfaces most often: the market is not finalized yet.
    error MarketNotFinalized();

    Call[] internal _calls;

    /// @notice Owners whose redemption is configured to revert.
    mapping(address => bool) public failsFor;

    /// @notice Make `redeemFor` revert for one owner, leaving every other owner unaffected.
    function setFailsFor(address owner, bool on) external {
        failsFor[owner] = on;
    }

    /// @notice How many redemptions actually reached the module.
    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    /// @notice A recorded redemption, including the raw signature that was relayed.
    function callAt(uint256 index) external view returns (Call memory) {
        return _calls[index];
    }

    /// @dev 0x84f093c0 — mirrors IBinaryModule.redeemFor exactly.
    function redeemFor(
        address owner,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig,
        uint32 operatorId,
        bytes32 venueId,
        bytes32 marketId,
        uint8 outcomeIdx,
        uint256 amount
    ) external {
        if (failsFor[owner]) revert MarketNotFinalized();
        _calls.push(
            Call({
                owner: owner,
                nonce: nonce,
                deadline: deadline,
                sig: sig,
                operatorId: operatorId,
                venueId: venueId,
                marketId: marketId,
                outcomeIdx: outcomeIdx,
                amount: amount
            })
        );
    }
}
