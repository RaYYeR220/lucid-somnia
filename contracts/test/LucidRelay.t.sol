// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LucidRelay} from "../src/LucidRelay.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {MockBinaryModule} from "./mocks/MockBinaryModule.sol";

/// @notice The relay exists because a winning position on DreamDEX does not pay itself out, and
/// only the official web app auto-claims. Two properties decide whether it is worth anything:
/// a signature it accepted must still be valid at settlement, and a single broken redemption must
/// not cost everybody else theirs. Every test below is one of those two questions.
contract LucidRelayTest is Test {
    event Submitted(address indexed owner, bytes32 indexed marketId, uint8 outcomeIdx, uint256 amount);
    event Relayed(address indexed owner, bytes32 indexed marketId, uint8 outcomeIdx, uint256 amount);
    event RelayFailed(address indexed owner, bytes32 indexed marketId, bytes reason);
    event Cancelled(address indexed owner, bytes32 indexed marketId);

    LucidRelay internal relay;
    MockBinaryModule internal module;

    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant BOB_PK = 0xB0B;
    address internal alice;
    address internal bob;

    /// @dev The live Shannon venue this relay is aimed at.
    uint32 internal constant OPERATOR_ID = 4;
    bytes32 internal constant VENUE_ID = 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f;
    bytes32 internal constant MARKET_ID = bytes32(uint256(0xA0));

    /// @dev Verified against the live module; the relay must never derive it from anything else.
    bytes32 internal constant EXPECTED_TYPEHASH = 0x0e39444d9a47715564ad8a54c4a3da131c90fd5c197bc7b332f28fed9fad138b;

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);

        // The EIP-712 domain names the module as verifyingContract, so the mock has to live at the
        // module's real address or every signature this test makes would be for a different domain.
        MockBinaryModule impl = new MockBinaryModule();
        vm.etch(LucidTypes.MODULE, address(impl).code);
        module = MockBinaryModule(LucidTypes.MODULE);

        relay = new LucidRelay();
        vm.warp(1_800_000_000);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _auth(address owner, uint8 outcomeIdx, uint256 amount, uint256 nonce)
        internal
        view
        returns (LucidRelay.Authorization memory)
    {
        return LucidRelay.Authorization({
            owner: owner,
            operatorId: OPERATOR_ID,
            venueId: VENUE_ID,
            marketId: MARKET_ID,
            outcomeIdx: outcomeIdx,
            amount: amount,
            nonce: nonce,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(uint256 pk, LucidRelay.Authorization memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, relay.digestOf(a));
        return abi.encodePacked(r, s, v);
    }

    function _submit(uint256 pk, LucidRelay.Authorization memory a) internal {
        relay.submit(a, _sign(pk, a));
    }

    // ── the signature must be the protocol's, not ours ────────────────────────

    /// @dev A domain we made up would produce signatures the module rejects at settlement, which is
    /// exactly the silent failure this contract exists to prevent.
    function test_digest_matches_the_protocol_domain() public view {
        assertEq(
            keccak256(bytes(relay.REDEEM_AUTHORIZATION_TYPE())),
            relay.REDEEM_AUTHORIZATION_TYPEHASH(),
            "typehash constant is not the hash of the type string"
        );
        assertEq(relay.REDEEM_AUTHORIZATION_TYPEHASH(), EXPECTED_TYPEHASH, "typehash drifted from the live module");

        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SomniaMarkets"),
                keccak256("1"),
                block.chainid,
                LucidTypes.MODULE
            )
        );
        assertEq(relay.DOMAIN_SEPARATOR(), expectedDomain, "domain must verify against the module, not the relay");

        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 1);
        bytes32 structHash = keccak256(
            abi.encode(
                EXPECTED_TYPEHASH,
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
        assertEq(relay.digestOf(a), keccak256(abi.encodePacked(hex"1901", expectedDomain, structHash)));
    }

    // ── rejection happens at submit, never at settlement ──────────────────────

    function test_rejects_bad_signature_at_submit() public {
        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 1);

        vm.expectRevert(LucidRelay.BadSignature.selector);
        relay.submit(a, hex"deadbeef");

        bytes memory wrongLength = new bytes(65);
        vm.expectRevert(LucidRelay.BadSignature.selector);
        relay.submit(a, wrongLength);

        assertEq(relay.pendingCount(MARKET_ID), 0, "a rejected authorization must never be stored");
    }

    function test_rejects_signature_from_another_signer() public {
        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 1);

        // Sign first: vm.expectRevert applies to the very next call, and `_sign` itself calls
        // `digestOf` on the relay.
        bytes memory sig = _sign(BOB_PK, a);
        vm.expectRevert(LucidRelay.BadSignature.selector);
        relay.submit(a, sig);

        assertFalse(relay.usedNonce(alice, 1), "a rejected submit must not burn the owner's nonce");
    }

    function test_rejects_expired_deadline() public {
        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 1);
        a.deadline = block.timestamp;

        bytes memory sig = _sign(ALICE_PK, a);
        vm.expectRevert(LucidRelay.Expired.selector);
        relay.submit(a, sig);
    }

    function test_rejects_reused_nonce() public {
        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 7);
        _submit(ALICE_PK, a);
        assertTrue(relay.usedNonce(alice, 7));

        LucidRelay.Authorization memory replay = _auth(alice, 1, 900e6, 7);
        bytes memory replaySig = _sign(ALICE_PK, replay);
        vm.expectRevert(LucidRelay.NonceUsed.selector);
        relay.submit(replay, replaySig);

        // The same nonce from a different owner is a different authorization entirely.
        LucidRelay.Authorization memory bobs = _auth(bob, 0, 100e6, 7);
        _submit(BOB_PK, bobs);
        assertEq(relay.pendingCount(MARKET_ID), 2);
    }

    // ── storage ───────────────────────────────────────────────────────────────

    function test_stores_pending_authorization() public {
        LucidRelay.Authorization memory a = _auth(alice, 1, 1234e6, 3);

        vm.expectEmit(true, true, false, true, address(relay));
        emit Submitted(alice, MARKET_ID, 1, 1234e6);
        _submit(ALICE_PK, a);

        assertEq(relay.pendingCount(MARKET_ID), 1);

        LucidRelay.Authorization[] memory pending = relay.pendingFor(MARKET_ID);
        assertEq(pending.length, 1);
        assertEq(pending[0].owner, alice);
        assertEq(pending[0].operatorId, OPERATOR_ID);
        assertEq(pending[0].venueId, VENUE_ID);
        assertEq(pending[0].marketId, MARKET_ID);
        assertEq(pending[0].outcomeIdx, 1);
        assertEq(pending[0].amount, 1234e6);
        assertEq(pending[0].nonce, 3);
        assertEq(pending[0].deadline, a.deadline);
    }

    // ── relaying ──────────────────────────────────────────────────────────────

    function test_relay_calls_redeemFor_with_exact_args() public {
        LucidRelay.Authorization memory a = _auth(alice, 1, 4321e6, 9);
        bytes memory sig = _sign(ALICE_PK, a);
        relay.submit(a, sig);

        vm.expectEmit(true, true, false, true, address(relay));
        emit Relayed(alice, MARKET_ID, 1, 4321e6);
        relay.relay(MARKET_ID);

        assertEq(module.callCount(), 1);
        MockBinaryModule.Call memory c = module.callAt(0);
        assertEq(c.owner, alice);
        assertEq(c.nonce, 9);
        assertEq(c.deadline, a.deadline);
        assertEq(c.sig, sig, "the module must receive the owner's signature verbatim");
        assertEq(c.operatorId, OPERATOR_ID);
        assertEq(c.venueId, VENUE_ID);
        assertEq(c.marketId, MARKET_ID);
        assertEq(c.outcomeIdx, 1);
        assertEq(c.amount, 4321e6);
    }

    function test_relay_failure_is_emitted_not_swallowed() public {
        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 1);
        _submit(ALICE_PK, a);
        module.setFailsFor(alice, true);

        vm.expectEmit(true, true, false, true, address(relay));
        emit RelayFailed(alice, MARKET_ID, abi.encodeWithSelector(MockBinaryModule.MarketNotFinalized.selector));
        relay.relay(MARKET_ID);

        assertEq(module.callCount(), 0, "nothing was redeemed");
        assertEq(relay.relayedCount(), 0, "a failure must never be counted as a success");
        assertEq(relay.failedCount(), 1);
    }

    function test_one_failure_does_not_stop_the_others() public {
        _submit(ALICE_PK, _auth(alice, 0, 500e6, 1));
        _submit(BOB_PK, _auth(bob, 1, 700e6, 1));

        uint256 carolPk = 0xC0FFEE;
        address carol = vm.addr(carolPk);
        _submit(carolPk, _auth(carol, 0, 900e6, 1));

        // The middle entry is the one that blows up; the two around it must still be redeemed.
        module.setFailsFor(bob, true);
        relay.relay(MARKET_ID);

        assertEq(module.callCount(), 2);
        assertEq(module.callAt(0).owner, alice);
        assertEq(module.callAt(1).owner, carol);
        assertEq(relay.relayedCount(), 2);
        assertEq(relay.failedCount(), 1);
    }

    function test_relay_clears_the_queue() public {
        _submit(ALICE_PK, _auth(alice, 0, 500e6, 1));
        _submit(BOB_PK, _auth(bob, 0, 500e6, 1));
        assertEq(relay.pendingCount(MARKET_ID), 2);

        relay.relay(MARKET_ID);
        assertEq(relay.pendingCount(MARKET_ID), 0);
        assertEq(relay.pendingFor(MARKET_ID).length, 0);

        // A second pass must be a no-op rather than a double redemption.
        relay.relay(MARKET_ID);
        assertEq(module.callCount(), 2);
    }

    function test_queue_cap_is_enforced() public {
        uint256 cap = relay.MAX_PENDING();
        assertEq(cap, 64);

        for (uint256 i = 1; i <= cap; ++i) {
            uint256 pk = 0x1000 + i;
            _submit(pk, _auth(vm.addr(pk), 0, 1e6, 1));
        }
        assertEq(relay.pendingCount(MARKET_ID), cap);

        uint256 overflowPk = 0x1000 + cap + 1;
        LucidRelay.Authorization memory a = _auth(vm.addr(overflowPk), 0, 1e6, 1);
        bytes memory sig = _sign(overflowPk, a);
        vm.expectRevert(LucidRelay.QueueFull.selector);
        relay.submit(a, sig);

        // A different market keeps its own budget.
        LucidRelay.Authorization memory other = _auth(vm.addr(overflowPk), 0, 1e6, 1);
        other.marketId = bytes32(uint256(0xBEEF));
        relay.submit(other, _sign(overflowPk, other));
        assertEq(relay.pendingCount(bytes32(uint256(0xBEEF))), 1);
    }

    // ── cancellation ──────────────────────────────────────────────────────────

    function test_only_owner_can_cancel() public {
        _submit(ALICE_PK, _auth(alice, 0, 500e6, 1));

        vm.prank(bob);
        vm.expectRevert(LucidRelay.NotAuthorizationOwner.selector);
        relay.cancel(MARKET_ID, 0);

        vm.expectEmit(true, true, false, false, address(relay));
        emit Cancelled(alice, MARKET_ID);
        vm.prank(alice);
        relay.cancel(MARKET_ID, 0);

        assertEq(relay.pendingCount(MARKET_ID), 0);
    }

    function test_cancel_removes_only_that_entry() public {
        _submit(ALICE_PK, _auth(alice, 0, 500e6, 1));
        _submit(BOB_PK, _auth(bob, 0, 600e6, 1));

        uint256 carolPk = 0xC0FFEE;
        address carol = vm.addr(carolPk);
        _submit(carolPk, _auth(carol, 0, 700e6, 1));

        // Swap-and-pop moves the tail into the hole, so the survivors are the other two in any order.
        vm.prank(bob);
        relay.cancel(MARKET_ID, 1);

        LucidRelay.Authorization[] memory pending = relay.pendingFor(MARKET_ID);
        assertEq(pending.length, 2);
        assertEq(pending[0].owner, alice);
        assertEq(pending[1].owner, carol);

        relay.relay(MARKET_ID);
        assertEq(module.callCount(), 2, "the cancelled authorization must not be relayed");
    }

    function test_cancelled_nonce_stays_used() public {
        LucidRelay.Authorization memory a = _auth(alice, 0, 500e6, 1);
        _submit(ALICE_PK, a);

        vm.prank(alice);
        relay.cancel(MARKET_ID, 0);

        // The signature still exists off-chain; re-accepting it would undo the cancellation.
        assertTrue(relay.usedNonce(alice, 1));
        bytes memory sig = _sign(ALICE_PK, a);
        vm.expectRevert(LucidRelay.NonceUsed.selector);
        relay.submit(a, sig);
    }

    // ── the proof surface ─────────────────────────────────────────────────────

    function test_counters_track_success_and_failure() public {
        assertEq(relay.relayedCount(), 0);
        assertEq(relay.failedCount(), 0);

        _submit(ALICE_PK, _auth(alice, 0, 500e6, 1));
        _submit(BOB_PK, _auth(bob, 0, 500e6, 1));
        module.setFailsFor(bob, true);
        relay.relay(MARKET_ID);

        assertEq(relay.relayedCount(), 1);
        assertEq(relay.failedCount(), 1);

        // Counters are cumulative across markets: they are the ecosystem-impact number.
        bytes32 second = bytes32(uint256(0xFEED));
        LucidRelay.Authorization memory a = _auth(alice, 0, 100e6, 2);
        a.marketId = second;
        _submit(ALICE_PK, a);
        relay.relay(second);

        assertEq(relay.relayedCount(), 2);
        assertEq(relay.failedCount(), 1);
    }
}
