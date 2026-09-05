// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice A stand-in for `BinaryMarketsModule`'s permissionless upkeep surface.
///
/// @dev Etched over `LucidTypes.MODULE`, which is a compile-time constant the keeper cannot be
/// pointed away from. It records what was called so a test can assert the keeper actually reached
/// the venue, and it can be told to revert per function so the "this normally reverts" paths — a
/// market somebody else already finalized, a pool already released — are exercised as the ordinary
/// case they are rather than as an edge case.
contract MockKeeperModule {
    error AlreadyFinalized();
    error PoolNotReleasable();
    error NothingToSync();
    error QuestionNotAnswerable();

    uint256 public finalizeCalls;
    uint256 public releaseCalls;
    uint256 public syncCalls;
    uint256 public pokeCalls;

    bytes32 public lastFinalized;
    bytes32 public lastReleased;
    bytes32 public lastSynced;
    uint256 public lastPoked;

    bool public revertFinalize;
    bool public revertRelease;
    bool public revertSync;
    bool public revertPoke;
    bool public revertMarkets;

    /// @dev Zero unless a test sets one, which is exactly the "oracle question unknown" case.
    mapping(bytes32 marketId => uint256) public questionOf;

    function setReverts(bool finalize_, bool sync_, bool release_, bool poke_) external {
        revertFinalize = finalize_;
        revertSync = sync_;
        revertRelease = release_;
        revertPoke = poke_;
    }

    function setRevertMarkets(bool on) external {
        revertMarkets = on;
    }

    function setQuestion(bytes32 marketId, uint256 questionId) external {
        questionOf[marketId] = questionId;
    }

    function finalizeMarket(bytes32 marketId) external {
        if (revertFinalize) revert AlreadyFinalized();
        ++finalizeCalls;
        lastFinalized = marketId;
    }

    function syncSettlement(bytes32 marketId) external {
        if (revertSync) revert NothingToSync();
        ++syncCalls;
        lastSynced = marketId;
    }

    function releasePool(bytes32 marketId) external {
        if (revertRelease) revert PoolNotReleasable();
        ++releaseCalls;
        lastReleased = marketId;
    }

    function pokeOracle(uint256 questionId) external {
        if (revertPoke) revert QuestionNotAnswerable();
        ++pokeCalls;
        lastPoked = questionId;
    }

    /// @notice The oracle question id the keeper reads back for `pokeOracle`.
    ///
    /// @dev Declared as fourteen raw words rather than as the real fourteen-value tuple. Every
    /// field of that tuple is a static type, so the ABI encoding is identical word for word and the
    /// selector — derived from the argument types alone — is unchanged; the tuple form is simply
    /// stack-too-deep without the IR pipeline. Only the fields the keeper could plausibly read are
    /// filled in, because reading the first word is the whole of its interest here.
    function markets(bytes32 marketId) external view returns (uint256[14] memory out) {
        if (revertMarkets) revert QuestionNotAnswerable();
        out[0] = questionOf[marketId]; // oracleQuestionId
        out[1] = 2; // outcomeSlotCount
        out[4] = 4; // originOperatorId
    }
}
