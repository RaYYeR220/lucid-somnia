// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IBinaryModule} from "./interfaces/IDreamDex.sol";
import {LucidTypes} from "./types/LucidTypes.sol";

/// @title LucidRelay
/// @notice Universal auto-redeem for DreamDEX Event Contracts.
/// @dev A winning position on DreamDEX does not pay itself out. The official web app quietly
/// auto-claims for its own users; anybody trading from a script, a bot or another contract just
/// leaves winnings sitting unredeemed forever. The protocol already exposes `redeemFor`, authorised
/// by an EIP-712 signature from the position owner and relayable by *anyone* — there is no relayer
/// allowlist. Nobody runs it. This contract does.
///
/// A user signs their exit at the moment they enter, submits it here once, and the redemption is
/// executed for them right after settlement. Nothing in this contract is Lucid-specific: any
/// address, any operator, any venue, any market. It holds no funds and has no owner, because a
/// public good that one key can switch off is not a public good.
contract LucidRelay {
    /// @notice One position owner's pre-signed permission to redeem one leg of one market.
    /// @dev Field order is the EIP-712 struct's field order, not a convenient one — the encoding
    /// below depends on it.
    struct Authorization {
        address owner;
        uint32 operatorId;
        bytes32 venueId;
        bytes32 marketId;
        uint8 outcomeIdx;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev An authorization plus the signature that proves it. The signature is not part of the
    /// signed struct, so it is kept alongside rather than inside `Authorization`.
    struct Pending {
        Authorization auth;
        bytes signature;
    }

    /// @notice The recovered signer is not the stated owner, or the signature is malformed.
    error BadSignature();
    /// @notice The authorization's deadline has already passed, so the module would reject it.
    error Expired();
    /// @notice This (owner, nonce) pair was already submitted. Sign a fresh nonce.
    error NonceUsed();
    /// @notice This market already holds `MAX_PENDING` authorizations.
    error QueueFull();
    /// @notice Only the address that signed an authorization may cancel it.
    error NotAuthorizationOwner();
    /// @notice No pending authorization exists at that index.
    error IndexOutOfRange();
    /// @notice The queue is being relayed; it may not be mutated from inside that loop.
    error Reentrant();

    /// @notice An authorization was accepted and is now queued for its market's settlement.
    event Submitted(address indexed owner, bytes32 indexed marketId, uint8 outcomeIdx, uint256 amount);
    /// @notice `redeemFor` actually executed on the module. Emitted only after the call returned.
    event Relayed(address indexed owner, bytes32 indexed marketId, uint8 outcomeIdx, uint256 amount);
    /// @notice `redeemFor` reverted. The raw revert data is published so the failure is diagnosable
    /// off-chain instead of disappearing.
    event RelayFailed(address indexed owner, bytes32 indexed marketId, bytes reason);
    /// @notice An owner withdrew their own queued authorization before it was relayed.
    event Cancelled(address indexed owner, bytes32 indexed marketId);

    /// @notice DreamDEX's BinaryMarketsModule.
    /// @dev Deployed with CREATE3, so this address is byte-identical on Shannon (50312) and Somnia
    /// mainnet (5031). It is a constant rather than a constructor argument on purpose: the EIP-712
    /// domain below names it as `verifyingContract`, and a relay that could be pointed at a
    /// different "module" could be handed signatures for a domain nobody audited.
    IBinaryModule public constant MODULE = IBinaryModule(LucidTypes.MODULE);

    /// @notice Most authorizations a single market may queue.
    /// @dev `relay` is driven from inside a Somnia reactivity handler, which runs under a fixed gas
    /// limit. An unbounded queue would let one market's backlog grow until no caller on earth could
    /// drain it, so the loop is bounded by construction. A full 64-entry queue is still a large
    /// transaction and may not fit one handler; that is survivable because `relay` is permissionless
    /// — any EOA can finish the job — whereas an unbounded queue would not be.
    uint256 public constant MAX_PENDING = 64;

    /// @notice The EIP-712 type string the module signs against, verbatim.
    string public constant REDEEM_AUTHORIZATION_TYPE = "RedeemAuthorization(address owner,uint32 operatorId,"
        "bytes32 venueId,bytes32 marketId,uint8 outcomeIdx,uint256 amount,uint256 nonce,uint256 deadline)";

    /// @notice keccak256 of `REDEEM_AUTHORIZATION_TYPE`, verified against the live module.
    /// @dev Pinned as a literal so a typo in the type string above cannot silently change what this
    /// contract signs against; `LucidRelayTest` asserts the two still agree.
    bytes32 public constant REDEEM_AUTHORIZATION_TYPEHASH =
        0x0e39444d9a47715564ad8a54c4a3da131c90fd5c197bc7b332f28fed9fad138b;

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev The protocol's domain name, not this contract's. The signature has to be valid for
    /// DreamDEX, not for us.
    bytes32 private constant _NAME_HASH = keccak256("SomniaMarkets");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    /// @notice How many redemptions this relay has actually executed, ever.
    /// @dev Together with `failedCount` this is the whole honest scoreboard: every relayed
    /// redemption is money that would otherwise still be unclaimed.
    uint256 public relayedCount;

    /// @notice How many relay attempts reverted on the module.
    uint256 public failedCount;

    /// @notice Whether an (owner, nonce) pair has already been submitted.
    /// @dev Set at submit, never cleared — not even by `cancel`. The signature keeps existing
    /// off-chain, so releasing the nonce would let anyone re-submit a cancelled authorization.
    mapping(address => mapping(uint256 => bool)) public usedNonce;

    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    mapping(bytes32 => Pending[]) private _queue;

    /// @dev Cheaper than a mutex library and it only has to cover this one contract's three
    /// mutating entry points. `relay` clears the queue after its loop, so a callback that pushed or
    /// popped mid-loop would have its work silently discarded.
    uint256 private _relaying;

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    modifier notWhileRelaying() {
        if (_relaying != 0) revert Reentrant();
        _;
    }

    /// @notice Accept a signed redemption authorization and queue it for its market.
    /// @dev The signature is verified here, not at settlement. Rejecting late would mean a
    /// redemption that never happens and that nobody notices — the exact failure mode this contract
    /// exists to remove. A submitter does not have to be the owner: anyone may carry a signature.
    /// @param a The authorization exactly as the owner signed it.
    /// @param sig The owner's 65-byte EIP-712 signature over `digestOf(a)`.
    function submit(Authorization calldata a, bytes calldata sig) external notWhileRelaying {
        if (a.deadline <= block.timestamp) revert Expired();
        if (usedNonce[a.owner][a.nonce]) revert NonceUsed();

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digestOf(a), sig);
        if (err != ECDSA.RecoverError.NoError || signer != a.owner) revert BadSignature();

        Pending[] storage queue = _queue[a.marketId];
        if (queue.length >= MAX_PENDING) revert QueueFull();

        usedNonce[a.owner][a.nonce] = true;
        queue.push(Pending({auth: a, signature: sig}));

        emit Submitted(a.owner, a.marketId, a.outcomeIdx, a.amount);
    }

    /// @notice Execute every pending redemption for one settled market. Callable by anyone.
    /// @dev Each entry is isolated in try/catch: a market that is not finalized yet, an owner who
    /// already redeemed by hand, an amount larger than the balance — none of those may cost the
    /// other queued owners their payout. A failure is published with its raw revert data and
    /// counted separately; `Relayed` is emitted only on the success branch, because a fabricated
    /// success is worse than a visible failure.
    /// @param marketId The market whose queue to drain.
    function relay(bytes32 marketId) external notWhileRelaying {
        _relaying = 1;

        Pending[] storage queue = _queue[marketId];
        uint256 n = queue.length;

        for (uint256 i; i < n; ++i) {
            Authorization memory a = queue[i].auth;
            bytes memory sig = queue[i].signature;

            try MODULE.redeemFor(
                a.owner, a.nonce, a.deadline, sig, a.operatorId, a.venueId, a.marketId, a.outcomeIdx, a.amount
            ) {
                unchecked {
                    ++relayedCount;
                }
                emit Relayed(a.owner, a.marketId, a.outcomeIdx, a.amount);
            } catch (bytes memory reason) {
                unchecked {
                    ++failedCount;
                }
                emit RelayFailed(a.owner, a.marketId, reason);
            }
        }

        // Cleared whatever happened: a relayed nonce is spent on the module, and a failed one is
        // already reported. Leaving either behind would only produce repeat attempts nobody reads.
        delete _queue[marketId];
        _relaying = 0;
    }

    /// @notice Withdraw one of your own queued authorizations before it is relayed.
    /// @dev Swap-and-pop, so the surviving entries keep no particular order — order carries no
    /// meaning here, every entry redeems an independent position. The nonce stays marked used.
    /// @param marketId The market the authorization was queued under.
    /// @param index Its current index, as returned by `pendingFor`.
    function cancel(bytes32 marketId, uint256 index) external notWhileRelaying {
        Pending[] storage queue = _queue[marketId];
        if (index >= queue.length) revert IndexOutOfRange();
        if (queue[index].auth.owner != msg.sender) revert NotAuthorizationOwner();

        uint256 last = queue.length - 1;
        if (index != last) queue[index] = queue[last];
        queue.pop();

        emit Cancelled(msg.sender, marketId);
    }

    /// @notice Every authorization currently queued for a market.
    /// @param marketId The market to read.
    /// @return The pending authorizations, without their signatures.
    function pendingFor(bytes32 marketId) external view returns (Authorization[] memory) {
        Pending[] storage queue = _queue[marketId];
        uint256 n = queue.length;
        Authorization[] memory out = new Authorization[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = queue[i].auth;
        }
        return out;
    }

    /// @notice How many authorizations are queued for a market.
    /// @param marketId The market to read.
    /// @return The queue length, at most `MAX_PENDING`.
    function pendingCount(bytes32 marketId) external view returns (uint256) {
        return _queue[marketId].length;
    }

    /// @notice The stored signature for one queued authorization.
    /// @dev Published so anyone can re-verify off-chain that what this relay holds really is the
    /// owner's signature, without trusting the accept-time check.
    /// @param marketId The market the authorization is queued under.
    /// @param index Its index in that queue.
    /// @return The raw 65-byte signature.
    function pendingSignatureFor(bytes32 marketId, uint256 index) external view returns (bytes memory) {
        Pending[] storage queue = _queue[marketId];
        if (index >= queue.length) revert IndexOutOfRange();
        return queue[index].signature;
    }

    /// @notice The EIP-712 digest an owner must sign for `a`.
    /// @dev Exposed so a wallet, a script or a UI can produce the signature without re-deriving the
    /// domain and risking a mismatch nobody would notice until settlement.
    /// @param a The authorization to hash.
    /// @return The `\x19\x01`-prefixed typed-data digest.
    function digestOf(Authorization calldata a) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                REDEEM_AUTHORIZATION_TYPEHASH,
                a.owner,
                a.operatorId,
                a.venueId,
                a.marketId,
                a.outcomeIdx,
                a.amount,
                a.nonce,
                a.deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), structHash));
    }

    /// @notice The EIP-712 domain separator these signatures are checked against.
    /// @dev Its `verifyingContract` is the module, never this relay — the signature has to satisfy
    /// DreamDEX, and this contract is only the courier.
    /// @return The domain separator for the current chain.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        // Rebuilt after a chain split so signatures cannot be replayed across forks.
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(MODULE)));
    }
}
