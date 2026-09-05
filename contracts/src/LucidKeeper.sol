// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBinaryModule, IBinaryMarket} from "./interfaces/IDreamDex.sol";
import {LucidTypes} from "./types/LucidTypes.sol";

/// @title LucidKeeper
/// @notice Runs DreamDEX's permissionless upkeep for the whole venue, not just for the windows this
/// protocol's own desks happen to hold.
///
/// @dev Event Contracts expose five calls that anyone may make — `finalizeMarket`, `syncSettlement`,
/// `releasePool`, `pokeOracle` and the market's own `voidExpired` — and in practice nobody makes
/// them except the venue operator's own infrastructure. A market that is never finalized never pays
/// out; a pool that is never released is never recycled. This protocol already pays for a
/// subscription that wakes up on every market the venue creates, so running that upkeep for
/// everybody costs it a slice of gas and nothing else. That is the entire reason this contract
/// exists, and it is why it takes no fee and holds no funds.
///
/// @dev The keeper deliberately owns no subscription. Somnia's reactivity precompile requires the
/// *subscribing* contract to hold at least 32 SOMI, and that bond is scarce on testnet, so the
/// router's existing bond is reused: `LucidRouter` calls `keep` from inside its settlement handler
/// and this contract is a plain callee.
contract LucidKeeper is Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Gas stipend for one upkeep write.
    /// @dev The router hands `keep` 1_500_000 gas. Five writes and three reads at these stipends
    /// come to about 1.43M, which leaves the counter writes and the events inside that budget. A
    /// stipend rather than a bare call is what stops one hostile market contract from spending the
    /// whole allowance and starving the four upkeep calls queued behind it.
    uint256 public constant UPKEEP_GAS = 250_000;

    /// @notice Gas stipend for one precondition read.
    uint256 public constant READ_GAS = 60_000;

    /// @notice Tags carried by `Kept` and `KeepFailed`, one per upkeep call.
    /// @dev A tag rather than five event types, so an indexer can count the whole surface with one
    /// filter and adding an upkeep call later does not change the log schema.
    bytes32 public constant WHAT_FINALIZE = "finalize";
    /// @notice See {WHAT_FINALIZE}.
    bytes32 public constant WHAT_SYNC = "sync";
    /// @notice See {WHAT_FINALIZE}.
    bytes32 public constant WHAT_RELEASE = "release";
    /// @notice See {WHAT_FINALIZE}.
    bytes32 public constant WHAT_POKE = "poke";
    /// @notice See {WHAT_FINALIZE}.
    bytes32 public constant WHAT_VOID = "void";
    /// @notice Reported when the module itself has no code, so none of its upkeep could be tried.
    bytes32 public constant WHAT_MODULE = "module";

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Two storage slots, written once per firing. These numbers are the public claim this
    /// contract makes about its own usefulness, so they live on-chain rather than being derived
    /// from logs a reader would have to trust an indexer for.
    struct Counters {
        uint64 finalized;
        uint64 released;
        uint64 synced;
        uint64 poked;
        uint64 voided;
        uint64 failures;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The only address allowed to drive upkeep.
    address public router;

    Counters internal _counts;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Only the router may drive upkeep.
    error NotRouter();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice One upkeep call went through.
    /// @param marketId The window it was made for.
    /// @param what Which call, as one of the `WHAT_*` tags.
    event Kept(bytes32 indexed marketId, bytes32 what);

    /// @notice One upkeep call did not go through.
    /// @dev Routine. Most of these calls revert in normal operation: a market somebody else already
    /// finalized, a pool already released, an oracle question that is not answerable yet. The
    /// `failures` counter is information about how much of the venue was already tended to when we
    /// arrived, not an alarm, and a long run of failures usually means the venue is healthy.
    /// @param marketId The window it was made for.
    /// @param what Which call, as one of the `WHAT_*` tags.
    /// @param reason The raw revert data, or `NO_CODE` when the target could not be called at all.
    event KeepFailed(bytes32 indexed marketId, bytes32 what, bytes reason);

    /// @notice The router allowed to drive upkeep changed.
    event RouterSet(address router);

    /// @param owner_ The operator that may re-point the keeper at a new router.
    /// @param router_ The router that drives upkeep, or zero to attach one later.
    constructor(address owner_, address router_) Ownable(owner_) {
        router = router_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Upkeep
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Run every permissionless upkeep call the venue exposes for one settled window.
    ///
    /// @dev Two rules govern this function, and both have already cost this codebase a firing.
    ///
    /// First, past the router check it must not revert. It runs inside a reactivity handler, and
    /// Somnia executes handlers as synthetic transactions: a revert here does not fail one market's
    /// upkeep, it discards the entire settlement fan-out for every desk woken in the same firing,
    /// and the router is charged for the gas regardless. Every call below is therefore wrapped, and
    /// a failure is counted and emitted rather than propagated. The router check itself is allowed
    /// to revert because it runs before any work and rejects a caller that should not be here.
    ///
    /// Second, `try`/`catch` does not catch everything. When a call is expected to return data the
    /// return-data decoder runs in *this* contract's frame after the call comes back, and its
    /// revert is raised outside the `catch`. A call to an address with no code therefore takes the
    /// whole handler down despite the wrapper. Every external target below is checked with
    /// `code.length` first. The same check also keeps a counter honest: a call into an empty
    /// address returns success without executing anything, which would otherwise be recorded as
    /// upkeep that never happened.
    ///
    /// @dev The order matters. `finalizeMarket` writes the payout numerators, `syncSettlement`
    /// pushes the settlement accounting off the back of them, and only then is the pool free to be
    /// released and recycled. `pokeOracle` nudges a question that has not been answered, and
    /// `voidExpired` is the last resort for one that never will be.
    ///
    /// @param m The window to tend to, as the router decoded it from the venue's own log.
    function keep(LucidTypes.MarketInfo calldata m) external {
        if (msg.sender != router) revert NotRouter();

        _keepModule(m);
        _keepMarket(m);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wiring
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the router allowed to drive upkeep.
    /// @param router_ The new router, or zero to stop accepting upkeep entirely.
    function setRouter(address router_) external onlyOwner {
        router = router_;
        emit RouterSet(router_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice How much venue upkeep this contract has actually performed.
    /// @dev Each counter moves only when the matching call returned. Nothing here is an estimate.
    /// @return finalized Markets finalized.
    /// @return released Pools released back to the venue.
    /// @return synced Settlements synchronised.
    /// @return poked Oracle questions nudged.
    /// @return voided Markets voided after their settlement window ran out.
    /// @return failures Upkeep calls that reverted or could not be attempted. Expected to be large:
    /// most of this work is already done by the time we reach it, and that is the good case.
    function counts()
        external
        view
        returns (uint64 finalized, uint64 released, uint64 synced, uint64 poked, uint64 voided, uint64 failures)
    {
        Counters memory c = _counts;
        return (c.finalized, c.released, c.synced, c.poked, c.voided, c.failures);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The four upkeep calls that live on the module.
    function _keepModule(LucidTypes.MarketInfo calldata m) private {
        address module = LucidTypes.MODULE;
        // The module is a fixed protocol address. If it has no code the keeper is pointed at the
        // wrong chain, and staying quiet would look exactly like a venue that needed no upkeep.
        if (module.code.length == 0) {
            _fail(m.marketId, WHAT_MODULE, "NO_CODE");
            return;
        }

        try IBinaryModule(module).finalizeMarket{gas: UPKEEP_GAS}(m.marketId) {
            ++_counts.finalized;
            emit Kept(m.marketId, WHAT_FINALIZE);
        } catch (bytes memory reason) {
            _fail(m.marketId, WHAT_FINALIZE, reason);
        }

        try IBinaryModule(module).syncSettlement{gas: UPKEEP_GAS}(m.marketId) {
            ++_counts.synced;
            emit Kept(m.marketId, WHAT_SYNC);
        } catch (bytes memory reason) {
            _fail(m.marketId, WHAT_SYNC, reason);
        }

        try IBinaryModule(module).releasePool{gas: UPKEEP_GAS}(m.marketId) {
            ++_counts.released;
            emit Kept(m.marketId, WHAT_RELEASE);
        } catch (bytes memory reason) {
            _fail(m.marketId, WHAT_RELEASE, reason);
        }

        // `MarketInfo` is decoded from the creation log, which carries the oracle question id in a
        // field this protocol does not keep, so it is read back from the module. A question id of
        // zero means we could not establish which question to poke — an answer rather than a
        // failure, and poking a made-up id would be worse than not poking at all.
        uint256 questionId = _oracleQuestionId(m.marketId);
        if (questionId == 0) return;

        try IBinaryModule(module).pokeOracle{gas: UPKEEP_GAS}(questionId) {
            ++_counts.poked;
            emit Kept(m.marketId, WHAT_POKE);
        } catch (bytes memory reason) {
            _fail(m.marketId, WHAT_POKE, reason);
        }
    }

    /// @dev The one upkeep call that lives on the market contract itself.
    ///
    /// `voidExpired` is the venue's escape hatch for a window whose oracle never answered: once
    /// `expiry + settlementWindow` has passed, anyone may void it and free the collateral held
    /// against it. Its preconditions are checked here rather than left to revert on the venue,
    /// because calling it early is not merely useless — it would drown the failures that matter.
    function _keepMarket(LucidTypes.MarketInfo calldata m) private {
        address market = m.market;
        if (market.code.length == 0) {
            _fail(m.marketId, WHAT_VOID, "NO_CODE");
            return;
        }

        // A resolved market has an answer, and voiding it would throw that answer away.
        try IBinaryMarket(market).isResolved{gas: READ_GAS}() returns (bool resolved) {
            if (resolved) return;
        } catch {
            // Without a readable status there is no telling a stuck window from a settled one.
            return;
        }

        uint64 expiry;
        uint64 window;
        try IBinaryMarket(market).expiry{gas: READ_GAS}() returns (uint64 e) {
            expiry = e;
        } catch {
            return;
        }
        try IBinaryMarket(market).settlementWindow{gas: READ_GAS}() returns (uint64 w) {
            window = w;
        } catch {
            return;
        }

        // Not yet voidable is the ordinary state of a window that just closed. It is an answer
        // rather than an error, so it is passed over in silence.
        if (block.timestamp <= uint256(expiry) + uint256(window)) return;

        try IBinaryMarket(market).voidExpired{gas: UPKEEP_GAS}() {
            ++_counts.voided;
            emit Kept(m.marketId, WHAT_VOID);
        } catch (bytes memory reason) {
            _fail(m.marketId, WHAT_VOID, reason);
        }
    }

    /// @dev The market's oracle question id, or zero if it cannot be read.
    ///
    /// A low-level call rather than `try IBinaryModule(...).markets(...)`: `markets` answers with a
    /// fourteen-value tuple of which exactly one field is wanted here, and decoding the rest would
    /// cost stack and gas for nothing. It also keeps a malformed answer contained — a failed decode
    /// inside a `try` is raised in this frame, outside the `catch`, which is the one thing this
    /// contract must never allow. The caller has already proved the module has code.
    function _oracleQuestionId(bytes32 marketId) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            LucidTypes.MODULE.staticcall{gas: READ_GAS}(abi.encodeCall(IBinaryModule.markets, (marketId)));
        if (!ok || ret.length < 32) return 0;

        // `oracleQuestionId` is the tuple's first field, so the first word is the whole answer.
        return abi.decode(ret, (uint256));
    }

    /// @dev Records work that did not happen, and says so.
    function _fail(bytes32 marketId, bytes32 what, bytes memory reason) private {
        ++_counts.failures;
        emit KeepFailed(marketId, what, reason);
    }
}
