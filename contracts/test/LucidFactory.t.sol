// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {LucidFactory} from "../src/LucidFactory.sol";
import {MockDesk} from "./mocks/MockDesk.sol";
import {MockRouterForFactory} from "./mocks/MockRouterForFactory.sol";

/// @notice Covers the two jobs of the factory: minting one non-custodial desk per user, and
/// holding the strategy graph that the router later fans a leader trade out over.
contract LucidFactoryTest is Test {
    LucidFactory internal factory;
    MockRouterForFactory internal router;
    MockDesk internal impl;

    address internal constant BRAIN = address(0xB4A1);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    /// @dev Base for the synthetic follower fleet used to push the leader to `MAX_FOLLOWERS`.
    uint160 internal constant FOLLOWER_BASE = 0x1000;

    event DeskCreated(address indexed owner, address indexed desk);
    event Published(address indexed desk, string name);
    event Unpublished(address indexed desk);
    event Followed(address indexed leader, address indexed follower, uint16 scaleBps);
    event Unfollowed(address indexed leader, address indexed follower);

    function setUp() public {
        impl = new MockDesk();
        router = new MockRouterForFactory();
        factory = new LucidFactory(address(impl), address(router), BRAIN);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _policy(uint64 cap) internal pure returns (LucidTypes.Policy memory p) {
        p = LucidTypes.Policy({
            maxStakePerWindow: cap,
            dailyBudget: cap * 10,
            maxOpenMarkets: 3,
            maxDrawdownBps: 2_000,
            maxConsecutiveLosses: 4,
            minEdgeBps: 300,
            allowedAssets: 1,
            allowedCadences: 1,
            strategy: uint8(LucidTypes.Strategy.AiEdge),
            armed: true
        });
    }

    function _createDesk(address user) internal returns (address desk) {
        vm.prank(user);
        desk = factory.createDesk(_policy(100e6));
    }

    /// @dev A desk that has opted in to being copied: the starting point for the social tests.
    function _publishedLeader(address user, string memory name) internal returns (address desk) {
        desk = _createDesk(user);
        vm.prank(user);
        factory.publish(name);
    }

    // ── desk deployment ───────────────────────────────────────────────────────

    function test_clone_is_initialized_with_owner_and_policy() public {
        vm.expectEmit(true, false, false, false);
        emit DeskCreated(ALICE, address(0));
        address desk = _createDesk(ALICE);

        assertTrue(desk != address(0), "no desk deployed");
        assertTrue(desk != address(impl), "clone must not be the implementation");
        assertTrue(desk.code.length > 0, "clone has no code");

        MockDesk clone = MockDesk(desk);
        assertEq(clone.initCalls(), 1, "initialize not called exactly once");
        assertEq(clone.owner(), ALICE, "owner is not the caller");
        assertEq(clone.router(), address(router), "router not wired");
        assertEq(clone.brain(), BRAIN, "brain not wired");

        assertEq(clone.policyCalls(), 1, "policy not pushed");
        assertEq(clone.policy().maxStakePerWindow, 100e6, "policy not forwarded");
        assertEq(clone.policy().minEdgeBps, 300, "policy not forwarded verbatim");
        assertTrue(clone.policy().armed, "policy not forwarded verbatim");

        // The implementation must stay virgin: a clone writing through to it would mean every
        // desk in the protocol shares one set of storage slots.
        assertEq(impl.owner(), address(0), "implementation was initialised");
        assertEq(impl.initCalls(), 0, "implementation was initialised");
    }

    function test_second_createDesk_reverts() public {
        address desk = _createDesk(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LucidFactory.DeskExists.selector, desk));
        factory.createDesk(_policy(1e6));

        assertEq(factory.deskCount(), 1, "a failed create must not grow the registry");
    }

    function test_deskOf_returns_the_clone() public {
        assertEq(factory.deskOf(ALICE), address(0), "unknown user must map to zero");

        address aliceDesk = _createDesk(ALICE);
        assertEq(factory.deskOf(ALICE), aliceDesk);
        assertEq(factory.deskOf(BOB), address(0));

        address bobDesk = _createDesk(BOB);
        assertEq(factory.deskOf(BOB), bobDesk);
        assertTrue(aliceDesk != bobDesk, "two users must not share a desk");
    }

    function test_router_is_notified_of_the_new_desk() public {
        address desk = _createDesk(ALICE);

        assertEq(router.registeredCount(), 1, "router was not told about the desk");
        assertEq(router.registered(0), desk);
        assertTrue(router.isRegistered(desk));

        address bobDesk = _createDesk(BOB);
        assertEq(router.registeredCount(), 2);
        assertEq(router.registered(1), bobDesk);
    }

    function test_allDesks_tracks_every_clone() public {
        assertEq(factory.allDesks().length, 0);
        assertEq(factory.deskCount(), 0);

        address a = _createDesk(ALICE);
        address b = _createDesk(BOB);
        address c = _createDesk(CAROL);

        address[] memory desks = factory.allDesks();
        assertEq(desks.length, 3);
        assertEq(factory.deskCount(), 3);
        assertEq(desks[0], a);
        assertEq(desks[1], b);
        assertEq(desks[2], c);
    }

    // ── strategy publication ──────────────────────────────────────────────────

    function test_publish_requires_a_desk() public {
        vm.prank(ALICE);
        vm.expectRevert(LucidFactory.NoDesk.selector);
        factory.publish("Momentum");

        vm.prank(ALICE);
        vm.expectRevert(LucidFactory.NoDesk.selector);
        factory.unpublish();

        assertEq(factory.publishedDesks().length, 0);
    }

    function test_publish_lists_the_leader() public {
        address desk = _createDesk(ALICE);
        assertFalse(factory.isPublished(desk), "a fresh desk must be private");

        vm.expectEmit(true, false, false, true);
        emit Published(desk, "Momentum");
        vm.prank(ALICE);
        factory.publish("Momentum");

        assertTrue(factory.isPublished(desk));
        assertEq(factory.strategyName(desk), "Momentum");

        address[] memory published = factory.publishedDesks();
        assertEq(published.length, 1);
        assertEq(published[0], desk);

        // Re-publishing renames in place rather than listing the same desk twice.
        vm.prank(ALICE);
        factory.publish("Mean Reversion");
        assertEq(factory.publishedDesks().length, 1);
        assertEq(factory.strategyName(desk), "Mean Reversion");
    }

    function test_unpublish_removes_from_the_list() public {
        address a = _publishedLeader(ALICE, "A");
        address b = _publishedLeader(BOB, "B");
        address c = _publishedLeader(CAROL, "C");
        assertEq(factory.publishedDesks().length, 3);

        // A follower on the desk about to be unpublished, to pin down that the link survives.
        address followerUser = address(0xF0110);
        address follower = _createDesk(followerUser);
        vm.prank(followerUser);
        factory.follow(b, 5_000);

        vm.expectEmit(true, false, false, false);
        emit Unpublished(b);
        vm.prank(BOB);
        factory.unpublish();

        assertFalse(factory.isPublished(b));
        assertEq(factory.strategyName(b), "", "name must be cleared");

        address[] memory published = factory.publishedDesks();
        assertEq(published.length, 2);
        assertEq(published[0], a, "swap-and-pop must not disturb earlier entries");
        assertEq(published[1], c, "the tail must move into the hole");
        assertTrue(factory.isPublished(a));
        assertTrue(factory.isPublished(c));

        // Followers are intentionally left in place; they simply stop receiving new trades.
        assertEq(factory.followersOf(b).length, 1);
        assertEq(factory.followersOf(b)[0], follower);
        assertEq(factory.scaleOf(b, follower), 5_000);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LucidFactory.NotPublished.selector, b));
        factory.unpublish();
    }

    // ── copy trading ──────────────────────────────────────────────────────────

    function test_follow_requires_a_published_leader() public {
        address leader = _publishedLeader(ALICE, "A");

        // A caller with no desk of their own has nothing to mirror into.
        vm.prank(BOB);
        vm.expectRevert(LucidFactory.NoDesk.selector);
        factory.follow(leader, 5_000);

        _createDesk(BOB);
        address unpublished = _createDesk(CAROL);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LucidFactory.NotPublished.selector, unpublished));
        factory.follow(unpublished, 5_000);

        vm.prank(BOB);
        factory.follow(leader, 5_000);
        assertEq(factory.followersOf(leader).length, 1);
    }

    function test_follow_rejects_zero_and_over_range_scale() public {
        address leader = _publishedLeader(ALICE, "A");
        address follower = _createDesk(BOB);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LucidFactory.InvalidScale.selector, uint16(0)));
        factory.follow(leader, 0);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LucidFactory.InvalidScale.selector, uint16(10_001)));
        factory.follow(leader, 10_001);

        assertEq(factory.followersOf(leader).length, 0, "a rejected follow must leave no trace");

        // 1x is the top of the range: a follower can mirror a leader, never lever them up.
        vm.prank(BOB);
        factory.follow(leader, 10_000);
        assertEq(factory.scaleOf(leader, follower), 10_000);
    }

    function test_cannot_follow_yourself() public {
        address desk = _publishedLeader(ALICE, "A");

        vm.prank(ALICE);
        vm.expectRevert(LucidFactory.SelfFollow.selector);
        factory.follow(desk, 5_000);

        assertEq(factory.followersOf(desk).length, 0);
    }

    function test_refollow_updates_scale_without_duplicating() public {
        address leader = _publishedLeader(ALICE, "A");
        address follower = _createDesk(BOB);

        vm.prank(BOB);
        factory.follow(leader, 2_500);
        assertEq(factory.scaleOf(leader, follower), 2_500);
        assertEq(factory.followersOf(leader).length, 1);

        vm.expectEmit(true, true, false, true);
        emit Followed(leader, follower, 7_500);
        vm.prank(BOB);
        factory.follow(leader, 7_500);

        assertEq(factory.scaleOf(leader, follower), 7_500, "scale must be updated in place");
        assertEq(factory.followersOf(leader).length, 1, "re-follow must not duplicate the entry");
        assertEq(factory.followersOf(leader)[0], follower);
    }

    function test_unfollow_swap_pops_cleanly() public {
        address leader = _publishedLeader(ALICE, "A");

        address[3] memory users = [BOB, CAROL, address(0xD00D)];
        address[3] memory desks;
        for (uint256 i = 0; i < 3; i++) {
            desks[i] = _createDesk(users[i]);
            vm.prank(users[i]);
            factory.follow(leader, uint16(1_000 * (i + 1)));
        }
        assertEq(factory.followersOf(leader).length, 3);

        vm.expectEmit(true, true, false, false);
        emit Unfollowed(leader, desks[0]);
        vm.prank(users[0]);
        factory.unfollow(leader);

        address[] memory fs = factory.followersOf(leader);
        assertEq(fs.length, 2);
        assertEq(fs[0], desks[2], "the tail must be swapped into the hole");
        assertEq(fs[1], desks[1], "the untouched entry must keep its slot");
        assertEq(factory.scaleOf(leader, desks[0]), 0, "scale must be zeroed");
        assertEq(factory.scaleOf(leader, desks[1]), 2_000, "other scales must survive");
        assertEq(factory.scaleOf(leader, desks[2]), 3_000, "other scales must survive");

        // Unfollowing twice is a caller mistake, not a silent no-op.
        vm.prank(users[0]);
        vm.expectRevert(abi.encodeWithSelector(LucidFactory.NotFollowing.selector, leader));
        factory.unfollow(leader);

        // The swapped entry must still be reachable at its new index.
        vm.prank(users[2]);
        factory.unfollow(leader);
        vm.prank(users[1]);
        factory.unfollow(leader);
        assertEq(factory.followersOf(leader).length, 0);
    }

    function test_follower_limit_is_enforced() public {
        address leader = _publishedLeader(ALICE, "A");
        uint256 max = factory.MAX_FOLLOWERS();

        address firstFollower;
        for (uint160 i = 0; i < max; i++) {
            address user = address(FOLLOWER_BASE + i);
            address desk = _createDesk(user);
            if (i == 0) firstFollower = desk;
            vm.prank(user);
            factory.follow(leader, 1_000);
        }
        assertEq(factory.followersOf(leader).length, max);

        address overflowUser = address(FOLLOWER_BASE + 0x1000);
        _createDesk(overflowUser);
        vm.prank(overflowUser);
        vm.expectRevert(LucidFactory.FollowerLimit.selector);
        factory.follow(leader, 1_000);

        assertEq(factory.followersOf(leader).length, max, "a rejected follow must not grow the list");

        // A desk already on the list can still change its scale at the cap: the limit guards the
        // length of the array, not the right to manage an existing link.
        vm.prank(address(FOLLOWER_BASE));
        factory.follow(leader, 9_000);
        assertEq(factory.scaleOf(leader, firstFollower), 9_000);
        assertEq(factory.followersOf(leader).length, max);

        // Freeing a slot lets the next desk in.
        vm.prank(address(FOLLOWER_BASE));
        factory.unfollow(leader);
        vm.prank(overflowUser);
        factory.follow(leader, 1_000);
        assertEq(factory.followersOf(leader).length, max);
    }
}
