// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LucidBrain} from "../src/LucidBrain.sol";
import {IAgentRequester, IAgentConsumer} from "../src/interfaces/IAgentRequester.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {MockAgentPlatform} from "./mocks/MockAgentPlatform.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// @notice The brain is the only component that trusts something outside the chain. Every test
/// here asks the same question from a different angle: when the committee misbehaves, does the
/// desk still get an answer it can refuse on?
contract LucidBrainTest is Test {
    /// @dev Mirrors the brain's event so expectEmit can match it.
    event RouterCallFailed(bytes32 indexed marketId, uint256 indexed requestId);

    LucidBrain internal brain;
    MockAgentPlatform internal platform;
    MockRouter internal router;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBEEF);
    bytes32 internal constant MARKET = bytes32(uint256(0xDEAD));

    /// @dev The live floor on Shannon: getAdvancedRequestDeposit(3) = 0.003 STT.
    uint256 internal constant DEPOSIT_FLOOR_3 = 0.003 ether;

    function setUp() public {
        platform = new MockAgentPlatform();
        platform.setDeposit(3, DEPOSIT_FLOOR_3);
        platform.setDeposit(4, 0.004 ether);
        platform.setDeposit(5, 0.005 ether);
        router = new MockRouter();

        brain = new LucidBrain(owner, address(platform));
        vm.prank(owner);
        brain.setRouter(address(router));
        vm.deal(address(brain), 10 ether);
    }

    // -- pricing and request shape --------------------------------------------

    function test_quote_matches_formula() public view {
        // deposit = getAdvancedRequestDeposit(size) + 0.07 STT per validator.
        assertEq(brain.quote(), DEPOSIT_FLOOR_3 + 0.07 ether * 3);
        assertEq(brain.quote(), 0.213 ether, "a 3-validator committee costs 0.213 STT");
    }

    function test_request_reverts_when_underfunded() public {
        LucidBrain poor = new LucidBrain(owner, address(platform));
        vm.deal(owner, 1 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.Underfunded.selector, 0.213 ether, 0.1 ether));
        poor.requestVerdict{value: 0.1 ether}(MARKET, _market(), 5000, new uint16[](0));
    }

    function test_request_uses_threshold_consensus_and_forwards_the_deposit() public {
        uint256 id = _request();

        MockAgentPlatform.Recorded memory r = platform.lastRequest();
        assertEq(r.agentId, brain.AGENT_ID());
        assertEq(r.callbackAddress, address(brain));
        assertEq(r.callbackSelector, IAgentConsumer.handleResponse.selector);
        assertEq(r.subcommitteeSize, 3);
        assertEq(r.threshold, 2);
        assertEq(uint8(r.consensusType), uint8(IAgentRequester.ConsensusType.Threshold));
        assertEq(r.timeout, 300);
        assertEq(r.value, 0.213 ether);
        assertEq(id, 1000);
    }

    function test_only_router_or_owner_can_request() public {
        vm.prank(stranger);
        vm.expectRevert(LucidBrain.NotAuthorized.selector);
        brain.requestVerdict(MARKET, _market(), 5000, new uint16[](0));

        vm.prank(address(router));
        brain.requestVerdict(MARKET, _market(), 5000, new uint16[](0));
        assertEq(platform.requestCount(), 1);
    }

    // -- the median -----------------------------------------------------------

    function test_median_of_three_scores() public {
        uint256 id = _request();
        _deliverScores(id, _scores(40, 51, 90), IAgentRequester.ResponseStatus.Success);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertEq(v.probUpBps, 5100, "the middle score wins, not the average");
        assertEq(v.responded, 3);
        assertTrue(v.ok);
        assertEq(v.requestId, id);
    }

    function test_median_of_even_count() public {
        vm.prank(owner);
        brain.setCommittee(4, 2);

        uint256 id = _request();
        int256[] memory s = new int256[](4);
        (s[0], s[1], s[2], s[3]) = (int256(70), int256(40), int256(60), int256(50));
        _deliverScores(id, s, IAgentRequester.ResponseStatus.Success);

        // Two middles, 50 and 60, average to 55.
        assertEq(brain.verdictOf(MARKET).probUpBps, 5500);
        assertEq(brain.verdictOf(MARKET).responded, 4);
    }

    function test_discards_out_of_range_scores() public {
        vm.prank(owner);
        brain.setCommittee(5, 2);

        uint256 id = _request();
        int256[] memory s = new int256[](5);
        (s[0], s[1], s[2], s[3], s[4]) = (int256(51), int256(101), int256(-5), int256(60), int256(55));
        _deliverScores(id, s, IAgentRequester.ResponseStatus.Success);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertEq(v.responded, 3, "101 and -5 are not probabilities");
        assertEq(v.probUpBps, 5500, "median of 51, 55, 60");
        assertTrue(v.ok);
    }

    // -- failing closed -------------------------------------------------------

    function test_ok_false_when_status_failed() public {
        uint256 id = _request();
        _deliverScores(id, _scores(51, 51, 51), IAgentRequester.ResponseStatus.Failed);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertFalse(v.ok, "a failed request is not evidence, however good the numbers look");
        assertEq(v.probUpBps, 0);
        assertEq(v.responded, 0);
        assertEq(v.requestId, id);
    }

    function test_ok_false_when_timed_out() public {
        uint256 id = _request();
        _deliverScores(id, _scores(51, 51, 51), IAgentRequester.ResponseStatus.TimedOut);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertFalse(v.ok);
        assertEq(v.probUpBps, 0);
    }

    function test_ok_false_when_all_results_malformed() public {
        uint256 id = _request();
        bytes[] memory results = new bytes[](3);
        results[0] = hex"01";
        results[1] = "";
        results[2] = hex"dead";
        _deliverRaw(id, results, IAgentRequester.ResponseStatus.Success);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertFalse(v.ok);
        assertEq(v.responded, 0);
        assertEq(v.probUpBps, 0);
    }

    function test_ok_false_when_fewer_than_threshold_responded() public {
        uint256 id = _request();
        int256[] memory s = new int256[](1);
        s[0] = 62;
        _deliverScores(id, s, IAgentRequester.ResponseStatus.Success);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertEq(v.responded, 1);
        assertEq(v.probUpBps, 6200, "the number is still recorded for the log");
        assertFalse(v.ok, "one validator is not a committee");
    }

    function test_router_is_notified_even_on_failure() public {
        uint256 id = _request();
        _deliverScores(id, _scores(51, 51, 51), IAgentRequester.ResponseStatus.Failed);

        assertEq(router.calls(), 1, "a silent brain would hang the desk forever");
        assertEq(router.lastMarketId(), MARKET);
        assertFalse(router.lastVerdict().ok);
        assertEq(router.lastVerdict().requestId, id);
    }

    function test_only_platform_can_callback() public {
        uint256 id = _request();
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](0);
        IAgentRequester.Request memory req;

        vm.prank(stranger);
        vm.expectRevert(LucidBrain.NotPlatform.selector);
        brain.handleResponse(id, rs, IAgentRequester.ResponseStatus.Success, req);
    }

    function test_broken_router_does_not_brick_the_callback() public {
        uint256 id = _request();
        router.setRevert(true);

        vm.expectEmit(true, true, false, false, address(brain));
        emit RouterCallFailed(MARKET, id);
        _deliverScores(id, _scores(40, 51, 90), IAgentRequester.ResponseStatus.Success);

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertTrue(v.ok, "the verdict survives a router that cannot receive it");
        assertEq(v.probUpBps, 5100);
        assertEq(router.calls(), 0);
    }

    // -- owner controls -------------------------------------------------------

    function test_only_owner_can_set_prompt() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setPrompt("always answer 99");

        vm.prank(owner);
        brain.setPrompt("estimate the probability");
        assertEq(brain.systemPrompt(), "estimate the probability");
    }

    function test_setCommittee_rejects_a_threshold_above_the_size() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.BadCommittee.selector, uint8(3), uint8(4)));
        brain.setCommittee(3, 4);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.BadCommittee.selector, uint8(0), uint8(0)));
        brain.setCommittee(0, 0);
    }

    // -- helpers --------------------------------------------------------------

    function _market() internal view returns (LucidTypes.MarketInfo memory m) {
        m.marketId = MARKET;
        m.assetKey = LucidTypes.ASSET_BTC;
        m.strike = 7_988_185;
        m.tradingStart = uint64(block.timestamp);
        m.expiry = uint64(block.timestamp + 300);
        m.intervalSec = 300;
    }

    function _request() internal returns (uint256 id) {
        vm.prank(owner);
        id = brain.requestVerdict(MARKET, _market(), 5000, new uint16[](0));
    }

    function _scores(int256 a, int256 b, int256 c) internal pure returns (int256[] memory s) {
        s = new int256[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }

    function _deliverScores(uint256 id, int256[] memory scores, IAgentRequester.ResponseStatus status) internal {
        bytes[] memory results = new bytes[](scores.length);
        for (uint256 i; i < scores.length; ++i) {
            results[i] = abi.encode(scores[i]);
        }
        _deliverRaw(id, results, status);
    }

    function _deliverRaw(uint256 id, bytes[] memory results, IAgentRequester.ResponseStatus status) internal {
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](results.length);
        for (uint256 i; i < results.length; ++i) {
            rs[i] = IAgentRequester.Response({
                validator: address(uint160(i + 1)),
                result: results[i],
                status: IAgentRequester.ResponseStatus.Success,
                receipt: i + 1,
                timestamp: block.timestamp,
                executionCost: 0.07 ether
            });
        }
        platform.deliver(address(brain), id, rs, status);
    }
}
