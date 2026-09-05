// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LucidTypes} from "./types/LucidTypes.sol";
import {ILucidDesk, ILucidRouter} from "./interfaces/ILucid.sol";

/// @title LucidFactory
/// @author Lucid
/// @notice Deploys one desk per user and holds the social graph on top of them: which desks have
/// opted in to being copied, and who mirrors whom at what size.
/// @dev Two design choices drive everything here.
///
/// 1. Desks are ERC-1167 minimal proxies. A shared vault would make one contract custody every
///    user's collateral; a per-user clone costs a few thousand gas to deploy and keeps the money
///    behind the user's own address. The factory sets the clone's owner to `msg.sender` and then
///    holds no authority over it at all - it cannot pause, drain, or re-point a live desk.
///
/// 2. The factory is the registry, not the executor. It never moves funds and never mirrors a
///    trade itself; it records the link and the router reads it. A follower's own `Policy` still
///    gates every copied trade independently, so following a leader can never make a desk breach
///    the caps its owner set.
contract LucidFactory {
    /// @notice A desk may follow at most this many leaders' worth of followers.
    /// @dev The router fans out over `followersOf(leader)` inside a reactivity handler, where the
    /// gas limit is fixed and a revert takes down every desk in the same batch. An unbounded list
    /// would let one popular leader turn the whole fan-out into a gas bomb, so the array is capped
    /// at a length the handler can always afford to walk.
    uint256 public constant MAX_FOLLOWERS = 32;

    /// @notice The `LucidDesk` bytecode every clone delegates to.
    address public immutable implementation;
    /// @notice The router each desk is wired to and registered with.
    address public immutable router;
    /// @notice The agent-committee wrapper each desk asks for verdicts.
    address public immutable brain;

    /// @dev Immutable on purpose: no admin can retarget an already-deployed desk at a different
    /// brain or router after the fact.

    /// @dev user => their one desk. Zero means the user has never created one.
    mapping(address => address) private _deskOf;
    address[] private _desks;

    /// @dev desk => 1-based index into `_published`. Zero doubles as "not published", which is why
    /// the index is offset by one rather than stored raw.
    mapping(address => uint256) private _publishedIndex;
    mapping(address => string) private _strategyName;
    address[] private _published;

    mapping(address => address[]) private _followers;
    /// @dev leader => follower => 1-based index into `_followers[leader]`, same trick as above.
    mapping(address => mapping(address => uint256)) private _followerIndex;
    mapping(address => mapping(address => uint16)) private _scaleOf;

    /// @notice A user got their desk. The desk address is the one every other call refers to.
    event DeskCreated(address indexed owner, address indexed desk);
    /// @notice A desk opted in to being copied, under this display name.
    event Published(address indexed desk, string name);
    /// @notice A desk withdrew from the public strategy list.
    event Unpublished(address indexed desk);
    /// @notice `follower` will mirror `leader` at `scaleBps` of the leader's size.
    event Followed(address indexed leader, address indexed follower, uint16 scaleBps);
    /// @notice The copy link between `leader` and `follower` is gone.
    event Unfollowed(address indexed leader, address indexed follower);

    /// @notice The caller already has a desk; the existing one is returned in the error.
    error DeskExists(address desk);
    /// @notice The caller has no desk, so there is nothing to publish from or mirror into.
    error NoDesk();
    /// @notice The target desk has not opted in to being copied.
    error NotPublished(address desk);
    /// @notice `scaleBps` must be in 1..10_000 - a follower may mirror a leader, never lever them up.
    error InvalidScale(uint16 scaleBps);
    /// @notice A desk cannot copy itself; the mirror would recurse.
    error SelfFollow();
    /// @notice `leader` already has `MAX_FOLLOWERS` followers.
    error FollowerLimit();
    /// @notice The caller does not currently follow `leader`.
    error NotFollowing(address leader);
    /// @notice A constructor argument was the zero address.
    error ZeroAddress();

    /// @param implementation_ The `LucidDesk` every clone delegates to.
    /// @param router_ The router that owns the reactivity subscriptions and drives the desks.
    /// @param brain_ The agent-committee wrapper desks ask for verdicts.
    constructor(address implementation_, address router_, address brain_) {
        if (implementation_ == address(0) || router_ == address(0) || brain_ == address(0)) {
            revert ZeroAddress();
        }
        implementation = implementation_;
        router = router_;
        brain = brain_;
    }

    // ── desk deployment ───────────────────────────────────────────────────────

    /// @notice Deploy the caller's personal desk and register it with the router.
    /// @dev Reverts `DeskExists` on a second call from the same address: the whole registry keys
    /// off one desk per user, and a second desk would silently orphan the first one's follow links.
    /// @param p The policy the desk starts under. It can be changed later, but only by its owner.
    /// @return desk The freshly deployed clone.
    function createDesk(LucidTypes.Policy calldata p) external returns (address desk) {
        address existing = _deskOf[msg.sender];
        if (existing != address(0)) revert DeskExists(existing);

        desk = Clones.clone(implementation);

        // Registry first, external calls after: a reentrant `createDesk` from a malicious
        // implementation would then hit the `DeskExists` guard instead of minting a second desk.
        _deskOf[msg.sender] = desk;
        _desks.push(desk);

        // Ownership goes straight to the caller. The factory is never an owner, so it can never
        // touch the collateral the user later deposits.
        ILucidDesk(desk).initialize(msg.sender, router, brain);
        ILucidDesk(desk).setPolicy(p);

        // The router is the only contract holding a reactivity subscription, so a desk is invisible
        // to the chain's event fan-out until it has been announced here.
        ILucidRouter(router).registerDesk(desk);

        emit DeskCreated(msg.sender, desk);
    }

    /// @notice The desk belonging to `user`, or the zero address if they have none.
    function deskOf(address user) external view returns (address) {
        return _deskOf[user];
    }

    /// @notice Every desk this factory has deployed, in creation order.
    /// @dev View-only and unbounded by design: it is for indexers and the UI, never read on-chain.
    function allDesks() external view returns (address[] memory) {
        return _desks;
    }

    /// @notice How many desks exist. Cheaper than `allDesks().length` for a paging caller.
    function deskCount() external view returns (uint256) {
        return _desks.length;
    }

    // ── strategy publication ──────────────────────────────────────────────────

    /// @notice Opt the caller's desk in to being copied, under a display name.
    /// @dev Publishing again renames in place instead of listing the same desk twice, so a leader
    /// can rebrand without dropping the followers they already have.
    /// @param name The label shown to prospective followers. Purely cosmetic; nothing keys off it.
    function publish(string calldata name) external {
        address desk = _requireDesk();

        if (_publishedIndex[desk] == 0) {
            _published.push(desk);
            _publishedIndex[desk] = _published.length;
        }
        _strategyName[desk] = name;

        emit Published(desk, name);
    }

    /// @notice Withdraw the caller's desk from the public strategy list.
    /// @dev Existing followers are deliberately left in place. Mirroring is gated on publication,
    /// so an unpublished leader stops producing copied trades either way, and clearing up to
    /// `MAX_FOLLOWERS` rows here would make the cost of quitting scale with popularity - exactly
    /// the wrong incentive. A follower who wants the link gone calls `unfollow` themselves.
    function unpublish() external {
        address desk = _requireDesk();

        uint256 idx = _publishedIndex[desk];
        if (idx == 0) revert NotPublished(desk);

        uint256 len = _published.length;
        if (idx != len) {
            address moved = _published[len - 1];
            _published[idx - 1] = moved;
            _publishedIndex[moved] = idx;
        }
        _published.pop();

        delete _publishedIndex[desk];
        delete _strategyName[desk];

        emit Unpublished(desk);
    }

    /// @notice Whether `desk` has opted in to being copied.
    function isPublished(address desk) external view returns (bool) {
        return _publishedIndex[desk] != 0;
    }

    /// @notice The display name `desk` published under, or the empty string if it is not published.
    function strategyName(address desk) external view returns (string memory) {
        return _strategyName[desk];
    }

    /// @notice Every desk currently offering itself to be copied.
    function publishedDesks() external view returns (address[] memory) {
        return _published;
    }

    // ── copy trading ──────────────────────────────────────────────────────────

    /// @notice Mirror `leader` into the caller's desk at `scaleBps` of the leader's size.
    /// @dev The link is a record, not a permission: the router reads it to size a mirrored trade,
    /// and the follower's own policy gate still gets to refuse that trade on its own terms.
    /// Following an already-followed leader updates the scale in place rather than duplicating
    /// the row, which is what keeps the follower array inside `MAX_FOLLOWERS`.
    /// @param leader The desk to copy. Must be published.
    /// @param scaleBps Fraction of the leader's stake to mirror, in basis points, 1..10_000.
    function follow(address leader, uint16 scaleBps) external {
        address follower = _requireDesk();

        if (leader == follower) revert SelfFollow();
        if (_publishedIndex[leader] == 0) revert NotPublished(leader);
        if (scaleBps == 0 || scaleBps > LucidTypes.BPS) revert InvalidScale(scaleBps);

        if (_followerIndex[leader][follower] == 0) {
            address[] storage fs = _followers[leader];
            if (fs.length >= MAX_FOLLOWERS) revert FollowerLimit();
            fs.push(follower);
            _followerIndex[leader][follower] = fs.length;
        }
        _scaleOf[leader][follower] = scaleBps;

        emit Followed(leader, follower, scaleBps);
    }

    /// @notice Stop mirroring `leader`.
    /// @dev Swap-and-pop, so removal is O(1) and the fan-out never walks a hole. Reverts rather
    /// than no-opping when there is no link, because a silent success here would read to a UI as
    /// "unfollowed" while the router kept copying.
    /// @param leader The desk to stop copying.
    function unfollow(address leader) external {
        address follower = _requireDesk();

        uint256 idx = _followerIndex[leader][follower];
        if (idx == 0) revert NotFollowing(leader);

        address[] storage fs = _followers[leader];
        uint256 len = fs.length;
        if (idx != len) {
            address moved = fs[len - 1];
            fs[idx - 1] = moved;
            _followerIndex[leader][moved] = idx;
        }
        fs.pop();

        delete _followerIndex[leader][follower];
        delete _scaleOf[leader][follower];

        emit Unfollowed(leader, follower);
    }

    /// @notice The desks currently mirroring `leader`. Never longer than `MAX_FOLLOWERS`.
    function followersOf(address leader) external view returns (address[] memory) {
        return _followers[leader];
    }

    /// @notice The scale `follower` mirrors `leader` at, in basis points. Zero means no link.
    function scaleOf(address leader, address follower) external view returns (uint16) {
        return _scaleOf[leader][follower];
    }

    // ── internal ──────────────────────────────────────────────────────────────

    /// @dev Every social action operates on the caller's own desk, never on an address they pass
    /// in, so a caller can only ever publish or follow with skin in the game.
    function _requireDesk() private view returns (address desk) {
        desk = _deskOf[msg.sender];
        if (desk == address(0)) revert NoDesk();
    }
}
