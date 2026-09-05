// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../../src/types/LucidTypes.sol";
import {MockCollateral} from "./MockCollateral.sol";
import {MockOutcomeToken} from "./MockOutcomeToken.sol";

/// @title MockModule
/// @notice Stands in for BinaryMarketsModule at 0x3ecC694Cef705358864a646142ac17A90E29e388.
/// @dev Reproduces the two settlement facts the desk is built around. `finalizeMarket` may fail
/// because somebody else already finalized the window, which is the normal case and not an error.
/// And redeeming a LOSING leg succeeds while paying zero rather than reverting, so a desk that
/// tried to predict its proceeds instead of measuring them would book a phantom profit.
contract MockModule {
    error FinalizeFailed();
    error RedeemFailed();

    /// @notice One recorded redemption, in the module's argument order.
    struct RedeemCall {
        uint32 operatorId;
        bytes32 venueId;
        bytes32 marketId;
        uint8 outcomeIdx;
        uint256 amount;
    }

    RedeemCall[] internal _redeems;

    uint256 public finalizeCalls;
    bool public revertOnFinalize;
    bool public revertOnRedeem;

    /// @notice Payout per outcome id, in bps of face value: 10000 for a winner, 0 for a loser,
    /// 5000 for each leg of a voided window.
    mapping(uint256 => uint256) public payoutBps;

    /// @notice The outcome ids of each market, so an outcome INDEX can be resolved to an id.
    mapping(bytes32 => uint256[2]) internal _ids;

    function setMarketIds(bytes32 marketId, uint256 yesId, uint256 noId) external {
        _ids[marketId] = [yesId, noId];
    }

    function setPayoutBps(uint256 outcomeId, uint256 bps) external {
        payoutBps[outcomeId] = bps;
    }

    function setRevertOnFinalize(bool on) external {
        revertOnFinalize = on;
    }

    function setRevertOnRedeem(bool on) external {
        revertOnRedeem = on;
    }

    function redeemCount() external view returns (uint256) {
        return _redeems.length;
    }

    function redeemAt(uint256 i) external view returns (RedeemCall memory) {
        return _redeems[i];
    }

    function finalizeMarket(bytes32) external {
        finalizeCalls += 1;
        if (revertOnFinalize) revert FinalizeFailed();
    }

    function redeem(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint8 outcomeIdx, uint256 amount)
        external
    {
        if (revertOnRedeem) revert RedeemFailed();

        _redeems.push(
            RedeemCall({
                operatorId: operatorId,
                venueId: venueId,
                marketId: marketId,
                outcomeIdx: outcomeIdx,
                amount: amount
            })
        );

        uint256 id = _ids[marketId][outcomeIdx];
        MockOutcomeToken(LucidTypes.OUTCOME_TOKEN).burn(msg.sender, id, amount);

        uint256 out = amount * payoutBps[id] / LucidTypes.BPS;
        if (out != 0) MockCollateral(LucidTypes.COLLATERAL).transfer(msg.sender, out);
    }

    // ── rest of the module surface: present so the mock is substitutable, unused by the desk ──

    function redeemMany(uint32, bytes32, bytes32[] calldata, uint8[] calldata, uint256[] calldata) external {}

    function releasePool(bytes32) external {}

    function syncSettlement(bytes32) external {}

    function pokeOracle(uint256) external {}
}
