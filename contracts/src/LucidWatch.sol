// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SomniaExtensions} from "@somnia/reactivity/interfaces/SomniaExtensions.sol";
import {ISomniaReactivityPrecompile} from "@somnia/reactivity/interfaces/ISomniaReactivityPrecompile.sol";

import {LucidTypes} from "./types/LucidTypes.sol";

/// @title LucidWatch
/// @notice Owns the venue's `MarketCreated` subscription and has the chain deliver it to the
/// router. It holds a bond of its own and nothing else: no funds, no policy, no market state.
///
/// @dev **Why this contract exists at all.**
///
/// The reactivity precompile requires a subscription's owner to hold at least 32 SOMI, and it
/// reaps the subscriptions of an owner that falls below that line. The router pays for every
/// committee call and every settlement wake-up out of the same balance that backs its bond, so
/// running out of float is not a hypothetical for it — it is the ordinary end of a funding round.
///
/// That alone would be survivable. What was not survivable is what the deployed router does on
/// the way back up: `armVenue` cancels the previous subscription before creating the new one, and
/// `SomniaExtensions.unsubscribe` reverts when the precompile refuses. Once the chain has already
/// removed the subscription, the id the router still holds names nothing, the cancel fails, and
/// the whole call reverts — so a router that ran dry can never be re-armed, no matter how much
/// SOMI it is later handed. That is exactly what happened to the live deployment, and desks bind
/// to their router permanently, so redeploying the router would have stranded their collateral.
///
/// Two things follow, and this contract is both of them.
///
/// The first is a bug fix. The cancel here goes through a low-level call whose failure is recorded
/// and ignored, because "the subscription is already gone" and "the cancel was refused" leave the
/// caller in the same place — the id is not live either way — and neither is worth reverting over.
/// A contract whose job is to recover from an empty balance must not carry a path that an empty
/// balance can close permanently.
///
/// The second is a separation that should have been there from the start. The venue watch and the
/// router's own scheduling now sit behind two independent bonds. The router draining no longer
/// takes the venue subscription with it: the watch keeps delivering markets, the router keeps
/// refusing them with `ROUTER_FLOAT` until it is topped up, and the protocol resumes on the next
/// window rather than on the next deployment.
///
/// The router accepts this arrangement without changes. `SomniaEventHandler` admits any call from
/// `0x0100`, the precompile lets a subscription name a handler other than its owner, and the
/// router's own `_onEvent` re-checks the emitter against `venueModule` before it decodes anything
/// — so a watch pointed at the wrong module is ignored rather than believed.
contract LucidWatch is Ownable {
    /// @notice The contract the chain calls when a matching log lands. Fixed at construction: a
    /// watch that could be re-pointed would be a way to feed decoded markets to an arbitrary
    /// address that never agreed to receive them.
    address public immutable handler;

    /// @notice The module whose `MarketCreated` logs are being watched, or zero when disarmed.
    address public module;

    /// @notice The live subscription id, or zero when disarmed.
    uint256 public subscriptionId;

    /// @notice The venue subscription was created. `module` is what the filter pins.
    event Armed(address indexed module, uint256 indexed subscriptionId);

    /// @notice The venue subscription was released.
    /// @param subscriptionId_ The id that was held.
    /// @param accepted Whether the precompile accepted the cancel. False means the subscription
    /// was already gone — recorded rather than reverted on, which is the whole point of this
    /// contract.
    event Disarmed(uint256 indexed subscriptionId_, bool accepted);

    /// @notice Float was withdrawn.
    event Swept(address indexed to, uint256 amount);

    error ZeroAddress();
    error WatchUnderfunded(uint256 have, uint256 need);
    error SweepFailed();

    /// @param owner_ The address allowed to arm, disarm and sweep.
    /// @param handler_ The router that receives the decoded logs.
    constructor(address owner_, address handler_) Ownable(owner_) {
        if (handler_ == address(0)) revert ZeroAddress();
        handler = handler_;
    }

    /// @notice Accepts the bond and the gas float. The precompile bills handler execution straight
    /// from this balance, so it is topped up by plain transfer.
    receive() external payable {}

    /// @notice Watch a module's `MarketCreated` logs on the router's behalf.
    /// @dev Releases any previous subscription first, so re-arming cannot leave two live watches
    /// firing into the same router. Unlike the router's own `armVenue`, a release the precompile
    /// refuses does not stop the re-arm.
    /// @param module_ The DreamDEX module that emits the logs.
    /// @return id The new subscription id.
    function arm(address module_) external onlyOwner returns (uint256 id) {
        if (module_ == address(0)) revert ZeroAddress();

        uint256 have = address(this).balance;
        if (have < SomniaExtensions.SUBSCRIPTION_OWNER_MINIMUM_BALANCE) {
            revert WatchUnderfunded(have, SomniaExtensions.SUBSCRIPTION_OWNER_MINIMUM_BALANCE);
        }

        _release();

        module = module_;
        id = SomniaExtensions.subscribe(
            handler,
            SomniaExtensions.SubscriptionFilter({
                // Only topic0 is pinned. The indexed fields are marketId, market and pool, none of
                // which exist before the log does.
                eventTopics: [LucidTypes.TOPIC_MARKET_CREATED, bytes32(0), bytes32(0), bytes32(0)],
                origin: address(0),
                emitter: module_
            }),
            // Deliberately the router's own numbers: `HANDLER_GAS_LIMIT`, `HANDLER_PRIORITY_FEE`
            // and `HANDLER_MAX_FEE`. The handler that runs on this subscription is the router's,
            // so the ceiling that has to hold is the router's.
            SomniaExtensions.SubscriptionOptions({
                priorityFeePerGas: 1 gwei,
                maxFeePerGas: 20 gwei,
                gasLimit: 100_000_000
            })
        );

        subscriptionId = id;
        emit Armed(module_, id);
    }

    /// @notice Stop watching. Safe to call when the subscription is already gone.
    function disarm() external onlyOwner {
        _release();
        module = address(0);
    }

    /// @notice Withdraw float. Taking the balance below the floor disarms the watch by starving
    /// it, which is the owner's call to make and is why nothing here stops it.
    /// @param to Recipient.
    /// @param amount Wei to send.
    function sweep(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SweepFailed();
        emit Swept(to, amount);
    }

    /// @notice Whether the precompile still holds the subscription this contract thinks it owns.
    /// @dev Worth exposing, because a watch whose balance dipped goes on looking armed in its own
    /// storage long after the chain stopped delivering to it. The precompile is the only address
    /// that can tell those two states apart.
    function armed() external view returns (bool) {
        uint256 id = subscriptionId;
        if (id == 0) return false;

        (bool ok, bytes memory ret) = SomniaExtensions.SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS.staticcall(
            abi.encodeWithSelector(ISomniaReactivityPrecompile.getSubscriptionInfo.selector, id)
        );
        if (!ok || ret.length == 0) return false;

        (, address owner_) = abi.decode(ret, (ISomniaReactivityPrecompile.SubscriptionData, address));
        return owner_ == address(this);
    }

    /// @dev Cancel whatever is held, and carry on either way. The precompile reverts on an id it
    /// has already removed, and that revert must not be able to reach a caller that is trying to
    /// recover.
    function _release() private {
        uint256 id = subscriptionId;
        if (id == 0) return;

        // solhint-disable-next-line avoid-low-level-calls
        (bool accepted,) = SomniaExtensions.SOMNIA_REACTIVITY_PRECOMPILE_ADDRESS.call(
            abi.encodeWithSelector(ISomniaReactivityPrecompile.unsubscribe.selector, id)
        );

        subscriptionId = 0;
        emit Disarmed(id, accepted);
    }
}
