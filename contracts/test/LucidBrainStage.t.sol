// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LucidBrain, IJsonApiAgent, IAgentPriceConsumer} from "../src/LucidBrain.sol";
import {IAgentRequester, IAgentConsumer, ILLMInferenceAgent} from "../src/interfaces/IAgentRequester.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {PromptLib} from "../src/lib/PromptLib.sol";
import {MockAgentPlatform} from "./mocks/MockAgentPlatform.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// @notice The committee answered 50, 50, 50 on a live at-the-money window — correctly, because it
/// was shown the strike and never the spot, and these windows open at their strike. This suite
/// covers the fix: a price fetched by the same validator set before the question is asked, and a
/// deadline guard that refuses to buy either half of an answer the window cannot still use.
///
/// The through-line of every test below is that the protocol never spends on a verdict it cannot
/// act on, and never goes quiet when it declines to spend.
contract LucidBrainStageTest is Test {
    LucidBrain internal brain;
    MockAgentPlatform internal platform;
    MockRouter internal router;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBEEF);
    bytes32 internal constant MARKET = bytes32(uint256(0xDEAD));

    /// @dev 79881.85, the strike the venue published on the window this was reproduced against.
    uint256 internal constant STRIKE = 7_988_185;
    /// @dev 79912.40 — about four basis points above the strike.
    uint256 internal constant SPOT = 7_991_240;

    uint256 internal constant FLOOR_3 = 0.003 ether;
    uint256 internal constant STAGE1 = FLOOR_3 + 0.03 ether * 3;
    uint256 internal constant STAGE2 = FLOOR_3 + 0.07 ether * 3;

    /// @dev Seeded latencies of 60s each give (60 + 60) * 2 + 30.
    uint256 internal constant SEEDED_SLACK = 270;

    uint64 internal start;

    function setUp() public {
        // A real wall-clock so windows can expire without warping into negative time.
        vm.warp(1_700_000_000);
        start = uint64(block.timestamp);

        platform = new MockAgentPlatform();
        platform.setDeposit(3, FLOOR_3);
        platform.setDeposit(4, 0.004 ether);
        platform.setDeposit(5, 0.005 ether);
        router = new MockRouter();

        brain = new LucidBrain(owner, address(platform));
        vm.prank(owner);
        brain.setRouter(address(router));
        vm.deal(address(brain), 10 ether);
    }

    // ── stage order ───────────────────────────────────────────────────────────

    function test_stage_one_is_a_price_fetch_and_nothing_else_goes_out_with_it() public {
        uint256 priceId = _requestPrice(_market(start + 900));

        assertEq(platform.requestCount(), 1, "one request, not two: the inference has nothing to say yet");

        MockAgentPlatform.Recorded memory r = platform.requestAt(0);
        assertEq(r.agentId, brain.DEFAULT_FEED_AGENT_ID(), "the JSON API Request base agent");
        assertEq(r.callbackAddress, address(brain));
        assertEq(r.callbackSelector, IAgentPriceConsumer.handlePrice.selector, "its own callback, not the verdict one");
        assertEq(r.subcommitteeSize, 3);
        assertEq(r.threshold, 2);
        assertEq(uint8(r.consensusType), uint8(IAgentRequester.ConsensusType.Threshold), "prices never match exactly");
        assertEq(r.value, STAGE1, "a fetch is priced under an inference");
        assertEq(brain.marketOfPriceRequest(priceId), MARKET);

        // And the payload really is fetchUint(url, selector, decimals).
        assertEq(_selectorOf(r.payload), IJsonApiAgent.fetchUint.selector);
        (string memory url, string memory sel, uint8 decimals) = abi.decode(_args(r.payload), (string, string, uint8));
        assertEq(url, "https://api.coinbase.com/v2/prices/BTC-USD/spot");
        assertEq(sel, "data.amount");
        assertEq(decimals, 2, "the venue publishes strikes in hundredths");
    }

    function test_stage_two_fires_only_once_the_price_has_landed() public {
        uint256 priceId = _requestPrice(_market(start + 900));
        assertEq(platform.requestCount(), 1);

        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));

        assertEq(platform.requestCount(), 2, "the inference goes out on the back of the price");
        MockAgentPlatform.Recorded memory r = platform.lastRequest();
        assertEq(r.agentId, brain.AGENT_ID(), "the LLM Inference base agent");
        assertEq(r.callbackSelector, IAgentConsumer.handleResponse.selector);
        assertEq(r.value, STAGE2);
    }

    function test_the_prompt_carries_the_spot_and_the_distance_it_makes_computable() public {
        uint256 priceId = _requestPrice(_market(start + 900));
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));

        string memory prompt = _promptOf(platform.lastRequest().payload);
        assertTrue(_contains(prompt, "Spot: 79912.40"), "the fact the committee was missing");
        assertTrue(_contains(prompt, "Strike: 79881.85"), "and the one it already had");
        assertTrue(_contains(prompt, "Distance to strike: +3 bps"), "computed here, not by the model");
    }

    /// @dev The tail the brain carries between callbacks must be the tail the prompt renders. If
    /// `PENDING_OUTCOMES` and `PromptLib.MAX_OUTCOMES` ever drift apart, either the brain pays for
    /// storage nobody reads or the committee silently loses history.
    function test_pending_history_matches_the_prompt_window() public {
        uint16[] memory outcomes = new uint16[](7);
        for (uint256 i; i < 7; ++i) {
            outcomes[i] = uint16(i % 2); // 0,1,0,1,0,1,0 -> tail of five is 0,1,0,1,0
        }

        vm.prank(owner);
        uint256 priceId = brain.requestVerdict(MARKET, _market(start + 900), 5000, outcomes);
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));

        string memory prompt = _promptOf(platform.lastRequest().payload);
        assertEq(PromptLib.MAX_OUTCOMES, 5, "the prompt renders five");
        assertTrue(_contains(prompt, "DOWN,UP,DOWN,UP,DOWN"), "and five is what survived the gap");
        assertFalse(_contains(prompt, "DOWN,UP,DOWN,UP,DOWN,UP"), "no sixth entry");
    }

    // ── the median price ──────────────────────────────────────────────────────

    function test_the_median_price_is_used_and_zeros_are_discarded() public {
        vm.prank(owner);
        brain.setFeedCommittee(5, 3);

        uint256 priceId = _requestPrice(_market(start + 900));

        uint256[] memory p = new uint256[](5);
        // Two validators returned nothing usable; three read the market a moment apart.
        (p[0], p[1], p[2], p[3], p[4]) = (0, 7_991_000, 7_993_000, 0, 7_992_000);
        _deliverPrices(priceId, p);

        // 79910.00, 79920.00, 79930.00 -> the middle one, not the average of five including zeros.
        assertTrue(_contains(_promptOf(platform.lastRequest().payload), "Spot: 79920.00"), "median of the survivors");
    }

    function test_a_price_nowhere_near_the_strike_is_not_a_price() public {
        vm.prank(owner);
        brain.setFeedCommittee(5, 3);

        uint256 priceId = _requestPrice(_market(start + 900));

        uint256[] memory p = new uint256[](5);
        // A rate-limited validator that parsed an error body, and one that read the wrong asset.
        // Over a window measured in minutes the spot cannot be an order of magnitude from the open.
        (p[0], p[1], p[2], p[3], p[4]) = (1, 7_991_000, 999_999_999_999, 7_993_000, 7_992_000);
        _deliverPrices(priceId, p);

        assertTrue(_contains(_promptOf(platform.lastRequest().payload), "Spot: 79920.00"), "outliers never voted");
    }

    function test_no_usable_price_means_no_inference_is_bought() public {
        uint256 priceId = _requestPrice(_market(start + 900));
        uint256 floatBefore = address(brain).balance;

        _deliverPrices(priceId, _three(0, 0, 0));

        assertEq(platform.requestCount(), 1, "the inference was never worth buying");
        assertEq(address(brain).balance, floatBefore, "and nothing was spent trying");
        assertFalse(brain.verdictOf(MARKET).ok, "the desk is told, not left waiting");
        assertEq(router.calls(), 1);
    }

    function test_a_failed_price_committee_is_not_a_price() public {
        uint256 priceId = _requestPrice(_market(start + 900));

        _deliverPricesWithStatus(priceId, _three(SPOT, SPOT, SPOT), IAgentRequester.ResponseStatus.TimedOut);

        assertEq(platform.requestCount(), 1, "good-looking numbers under a failed status are not evidence");
        assertFalse(brain.verdictOf(MARKET).ok);
        assertEq(router.calls(), 1);
    }

    // ── the deadline guard ────────────────────────────────────────────────────

    function test_required_slack_starts_conservative() public view {
        assertEq(brain.feedLatencyEma(), 60, "seeded pessimistic, not optimistic");
        assertEq(brain.verdictLatencyEma(), 60);
        assertEq(brain.requiredSlack(), SEEDED_SLACK, "(60 + 60) * 2 + 30");
    }

    function test_required_slack_grows_as_the_committees_slow_down() public {
        uint256 priceId = _requestPrice(_market(start + 3000));

        // A price that took two hundred seconds.
        vm.warp(start + 200);
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        // (60 * 3 + 200) / 4 = 95.
        assertEq(brain.feedLatencyEma(), 95, "the average walks toward what was observed");
        assertEq(brain.requiredSlack(), (95 + 60) * 2 + 30);

        // Then an inference that took three hundred more.
        uint256 verdictId = platform.idAt(platform.requestCount() - 1);
        vm.warp(start + 500);
        _deliverScores(verdictId, _threeScores(51, 52, 53));
        // (60 * 3 + 300) / 4 = 120.
        assertEq(brain.verdictLatencyEma(), 120);
        assertEq(brain.requiredSlack(), (95 + 120) * 2 + 30, "both stages count, twice over, plus 30s to trade");
        assertGt(brain.requiredSlack(), SEEDED_SLACK, "a slower network buys fewer windows, on its own");
    }

    function test_required_slack_is_clamped_at_both_ends() public {
        assertEq(brain.MIN_SLACK(), 90, "below this the venue rejects the order anyway");
        assertEq(brain.MAX_SLACK(), 600);

        // Fast committees cannot talk the requirement below the venue's own floor.
        for (uint256 i; i < 12; ++i) {
            _runInstantWindow(uint64(start + 3000));
        }
        assertLt(brain.feedLatencyEma(), 2, "the average has converged on ~0");
        assertEq(brain.requiredSlack(), 90, "still floored where the venue stops accepting orders");

        // And one pathological round trip cannot ratchet it past every window the venue rolls.
        uint256 priceId = _requestPrice(_market(start + 100_000));
        vm.warp(block.timestamp + 50_000);
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        assertEq(brain.feedLatencyEma(), 150, "the sample itself is capped at MAX_SLACK before it is folded in");
        assertLe(brain.requiredSlack(), 600);
    }

    function test_a_window_that_is_already_too_tight_is_refused_before_anything_is_spent() public {
        uint256 floatBefore = address(brain).balance;

        // Ninety seconds left against a 270-second requirement.
        vm.expectEmit(true, false, false, true, address(brain));
        emit LucidBrain.WindowTooTight(MARKET, 90, SEEDED_SLACK);
        vm.prank(owner);
        uint256 id = brain.requestVerdict(MARKET, _market(start + 90), 5000, new uint16[](0));

        assertEq(id, 0, "nothing was requested, and the caller can see that");
        assertEq(platform.requestCount(), 0, "not even the cheap stage");
        assertEq(address(brain).balance, floatBefore, "the float is untouched");
        assertFalse(brain.verdictOf(MARKET).ok);
        assertEq(router.calls(), 1, "a refusal is an answer, and it is delivered");
        assertFalse(router.lastVerdict().ok);
    }

    function test_an_asset_with_no_feed_is_refused_rather_than_guessed_at() public {
        LucidTypes.MarketInfo memory m = _market(start + 900);
        m.assetKey = keccak256("SOL");

        vm.expectEmit(true, true, false, false, address(brain));
        emit LucidBrain.NoFeed(MARKET, keccak256("SOL"));
        vm.prank(owner);
        uint256 id = brain.requestVerdict(MARKET, m, 5000, new uint16[](0));

        assertEq(id, 0);
        assertEq(platform.requestCount(), 0, "without a spot the answer would be 50 again");
        assertEq(router.calls(), 1);
    }

    function test_a_window_that_ran_out_mid_flight_aborts_before_the_expensive_stage() public {
        uint256 priceId = _requestPrice(_market(start + 400));
        uint256 floatAfterStageOne = address(brain).balance;
        assertEq(floatAfterStageOne, 10 ether - STAGE1);

        // The price took 290 of the window's 400 seconds. 110 left against the 150 the inference
        // is still expected to need. Saving this deposit is the entire reason the check lives here.
        vm.warp(start + 290);
        vm.expectEmit(true, false, false, true, address(brain));
        emit LucidBrain.LateAbort(MARKET, 110, 150);
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));

        assertEq(platform.requestCount(), 1, "the inference was never requested");
        assertEq(address(brain).balance, floatAfterStageOne, "and never paid for");
        assertFalse(brain.verdictOf(MARKET).ok);
        assertEq(router.calls(), 1, "the desk is told the window got away");
    }

    function test_a_verdict_that_arrives_after_expiry_is_recorded_but_never_tradeable() public {
        uint64 expiry = start + 400;
        uint256 priceId = _requestPrice(_market(expiry));
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        uint256 verdictId = platform.idAt(platform.requestCount() - 1);

        vm.warp(expiry + 30);
        vm.expectEmit(true, false, false, true, address(brain));
        emit LucidBrain.VerdictTooLate(MARKET, expiry, expiry + 30);
        _deliverScores(verdictId, _threeScores(72, 74, 76));

        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertFalse(v.ok, "the window it describes has already settled");
        assertEq(v.probUpBps, 7400, "a late answer is not a wrong answer, and it is kept");
        assertEq(v.responded, 3);
        assertEq(router.calls(), 1);
        assertFalse(router.lastVerdict().ok, "and the desk is told not to act on it");
    }

    function test_the_float_running_out_between_stages_refuses_rather_than_reverts() public {
        vm.deal(address(brain), brain.quote());
        uint256 priceId = _requestPrice(_market(start + 900));

        // The operator swept mid-flight. A revert here would fail the platform's callback and
        // nobody would ever learn why the verdict never came.
        vm.prank(owner);
        brain.sweep(owner, 0.1 ether);

        vm.expectEmit(true, false, false, true, address(brain));
        emit LucidBrain.StageTwoUnfunded(MARKET, STAGE2, STAGE2 - 0.1 ether);
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));

        assertEq(platform.requestCount(), 1);
        assertFalse(brain.verdictOf(MARKET).ok);
        assertEq(router.calls(), 1);
    }

    /// @dev Every way this contract can decline, walked in one test, because the failure that
    /// matters is not any single abort — it is an abort that forgets to say so and leaves a desk
    /// exposed with an open position and no explanation.
    function test_the_router_is_notified_on_every_abort_path() public {
        uint256 expected;

        // 1. Refused before spending: the window was already too short.
        vm.prank(owner);
        brain.requestVerdict(MARKET, _market(start + 60), 5000, new uint16[](0));
        assertEq(router.calls(), ++expected, "window too tight");

        // 2. Refused before spending: the asset has no feed.
        LucidTypes.MarketInfo memory noFeed = _market(start + 900);
        noFeed.assetKey = keccak256("SOL");
        vm.prank(owner);
        brain.requestVerdict(MARKET, noFeed, 5000, new uint16[](0));
        assertEq(router.calls(), ++expected, "no feed");

        // 3. The price came back unusable.
        _deliverPrices(_requestPrice(_market(start + 900)), _three(0, 0, 0));
        assertEq(router.calls(), ++expected, "price unusable");

        // 4. The window ran out while the price was in flight.
        uint256 late = _requestPrice(_market(start + 400));
        vm.warp(start + 300);
        _deliverPrices(late, _three(SPOT, SPOT, SPOT));
        assertEq(router.calls(), ++expected, "late abort");

        // 5. The verdict itself came back after expiry.
        vm.warp(start + 300);
        uint64 expiry = uint64(block.timestamp) + 900;
        uint256 priceId = _requestPrice(_market(expiry));
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        vm.warp(expiry + 10);
        _deliverScores(platform.idAt(platform.requestCount() - 1), _threeScores(60, 61, 62));
        assertEq(router.calls(), ++expected, "verdict too late");
    }

    // ── funding ───────────────────────────────────────────────────────────────

    function test_quote_is_the_sum_of_the_two_stages() public {
        assertEq(brain.quote(), brain.quoteStage1() + brain.quoteStage2(), "the router funds both at once");
        assertEq(brain.quote(), STAGE1 + STAGE2);

        // And it tracks both committees independently.
        vm.startPrank(owner);
        brain.setFeedCommittee(5, 3);
        brain.setCommittee(4, 3);
        vm.stopPrank();

        assertEq(brain.quoteStage1(), 0.005 ether + 0.03 ether * 5);
        assertEq(brain.quoteStage2(), 0.004 ether + 0.07 ether * 4);
        assertEq(brain.quote(), brain.quoteStage1() + brain.quoteStage2());
    }

    function test_both_stages_are_funded_from_the_one_payment_the_router_makes() public {
        vm.deal(address(brain), 0);
        vm.deal(owner, 1 ether);

        // Read before pranking: a view call would otherwise consume the prank.
        uint256 fee = brain.quote();

        vm.prank(owner);
        uint256 priceId = brain.requestVerdict{value: fee}(MARKET, _market(start + 900), 5000, new uint16[](0));

        assertEq(address(brain).balance, STAGE2, "what the inference will cost stays as float");
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        assertEq(address(brain).balance, 0, "and is spent from inside the callback, where no caller can pay");
        assertEq(platform.requestCount(), 2);
    }

    // ── feeds ─────────────────────────────────────────────────────────────────

    function test_a_feed_can_be_repointed_by_the_owner() public {
        vm.prank(owner);
        brain.setFeed(LucidTypes.ASSET_BTC, "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "price", 8);

        LucidBrain.Feed memory f = brain.feedOf(LucidTypes.ASSET_BTC);
        assertEq(f.url, "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT");
        assertEq(f.selector, "price");
        assertEq(f.decimals, 8);

        _requestPrice(_market(start + 900));
        (string memory url, string memory sel, uint8 decimals) =
            abi.decode(_args(platform.requestAt(0).payload), (string, string, uint8));
        assertEq(url, "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "the committee fetches the new one");
        assertEq(sel, "price");
        assertEq(decimals, 8);
    }

    function test_only_the_owner_can_repoint_a_feed() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setFeed(LucidTypes.ASSET_BTC, "https://evil.example/price", "p", 2);

        assertEq(
            brain.feedOf(LucidTypes.ASSET_BTC).url,
            "https://api.coinbase.com/v2/prices/BTC-USD/spot",
            "the feed every verdict is built on is not open to the street"
        );
    }

    function test_feeds_are_per_asset() public {
        assertEq(brain.feedOf(LucidTypes.ASSET_ETH).url, "https://api.coinbase.com/v2/prices/ETH-USD/spot");

        vm.prank(owner);
        brain.setFeed(LucidTypes.ASSET_ETH, "https://api.coinbase.com/v2/prices/ETH-USD/buy", "data.amount", 2);

        assertEq(brain.feedOf(LucidTypes.ASSET_ETH).url, "https://api.coinbase.com/v2/prices/ETH-USD/buy");
        assertEq(
            brain.feedOf(LucidTypes.ASSET_BTC).url,
            "https://api.coinbase.com/v2/prices/BTC-USD/spot",
            "repointing one asset does not touch another"
        );
    }

    function test_a_feed_must_be_usable() public {
        vm.startPrank(owner);
        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(LucidTypes.ASSET_BTC, "", "data.amount", 2);

        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(LucidTypes.ASSET_BTC, "https://api.coinbase.com/v2/prices/BTC-USD/spot", "", 2);

        // Past eighteen the rescale to the venue's hundredths could overflow a garbage response.
        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(LucidTypes.ASSET_BTC, "https://api.coinbase.com/v2/prices/BTC-USD/spot", "data.amount", 19);
        vm.stopPrank();
    }

    function test_a_feed_on_another_scale_is_normalised_to_the_strike() public {
        vm.prank(owner);
        brain.setFeed(LucidTypes.ASSET_BTC, "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "price", 8);

        uint256 priceId = _requestPrice(_market(start + 900));
        // 79912.40 at eight decimals. Compared against a hundredths strike unconverted, this would
        // read as a market that had moved by a factor of a million.
        _deliverPrices(priceId, _three(7_991_240_000_000, 7_991_240_000_000, 7_991_240_000_000));

        string memory prompt = _promptOf(platform.lastRequest().payload);
        assertTrue(_contains(prompt, "Spot: 79912.40"), "the same price, on the venue's scale");
        assertTrue(_contains(prompt, "Distance to strike: +3 bps"), "and a distance that means something");
    }

    function test_only_the_owner_can_repoint_the_price_agent() public {
        assertEq(brain.feedAgentId(), 13174292974160097713, "the registered JSON API Request agent");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setFeedAgent(1);

        vm.prank(owner);
        brain.setFeedAgent(42);
        assertEq(brain.feedAgentId(), 42, "an id can move without a redeploy that would orphan the verdicts");
    }

    function test_only_the_owner_can_resize_the_price_committee() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setFeedCommittee(5, 3);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.BadCommittee.selector, uint8(3), uint8(4)));
        brain.setFeedCommittee(3, 4);
    }

    // ── the callback boundary ─────────────────────────────────────────────────

    function test_only_the_platform_can_deliver_a_price() public {
        uint256 priceId = _requestPrice(_market(start + 900));

        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](0);
        IAgentRequester.Request memory req;

        vm.prank(stranger);
        vm.expectRevert(LucidBrain.NotPlatform.selector);
        brain.handlePrice(priceId, rs, IAgentRequester.ResponseStatus.Success, req);
    }

    function test_a_price_is_answered_once() public {
        uint256 priceId = _requestPrice(_market(start + 900));
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));

        // A replayed callback must not buy a second inference on the same window.
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.UnknownRequest.selector, priceId));
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        assertEq(platform.requestCount(), 2);
    }

    function test_the_two_stages_do_not_answer_for_each_other() public {
        uint256 priceId = _requestPrice(_market(start + 900));

        // A verdict callback carrying the price request's id belongs to neither stage.
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.UnknownRequest.selector, priceId));
        _deliverScores(priceId, _threeScores(51, 51, 51));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _market(uint64 expiry) internal pure returns (LucidTypes.MarketInfo memory m) {
        m.marketId = MARKET;
        m.assetKey = LucidTypes.ASSET_BTC;
        m.strike = STRIKE;
        m.expiry = expiry;
        m.intervalSec = 300;
        m.tradingStart = expiry - 300;
    }

    function _requestPrice(LucidTypes.MarketInfo memory m) internal returns (uint256 id) {
        vm.prank(owner);
        id = brain.requestVerdict(MARKET, m, 5000, new uint16[](0));
    }

    /// @dev A whole window answered in the same block, which is what the fast end of the live
    /// network looks like.
    function _runInstantWindow(uint64 expiry) internal {
        uint256 priceId = _requestPrice(_market(expiry));
        _deliverPrices(priceId, _three(SPOT, SPOT, SPOT));
        _deliverScores(platform.idAt(platform.requestCount() - 1), _threeScores(51, 52, 53));
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory p) {
        p = new uint256[](3);
        (p[0], p[1], p[2]) = (a, b, c);
    }

    function _threeScores(int256 a, int256 b, int256 c) internal pure returns (int256[] memory s) {
        s = new int256[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }

    function _deliverPrices(uint256 id, uint256[] memory prices) internal {
        _deliverPricesWithStatus(id, prices, IAgentRequester.ResponseStatus.Success);
    }

    function _deliverPricesWithStatus(uint256 id, uint256[] memory prices, IAgentRequester.ResponseStatus status)
        internal
    {
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](prices.length);
        for (uint256 i; i < prices.length; ++i) {
            rs[i] = _response(i, abi.encode(prices[i]));
        }
        platform.deliverPrice(address(brain), id, rs, status);
    }

    function _deliverScores(uint256 id, int256[] memory scores) internal {
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](scores.length);
        for (uint256 i; i < scores.length; ++i) {
            rs[i] = _response(i, abi.encode(scores[i]));
        }
        platform.deliver(address(brain), id, rs, IAgentRequester.ResponseStatus.Success);
    }

    function _response(uint256 i, bytes memory result) internal view returns (IAgentRequester.Response memory) {
        return IAgentRequester.Response({
            validator: address(uint160(i + 1)),
            result: result,
            status: IAgentRequester.ResponseStatus.Success,
            receipt: i + 1,
            timestamp: block.timestamp,
            executionCost: 0.03 ether
        });
    }

    /// @dev Pulls the prompt back out of an `inferNumber` payload, so a test can read exactly what
    /// the committee was shown rather than trusting that it was built.
    function _promptOf(bytes memory payload) internal pure returns (string memory prompt) {
        assertEq(_selectorOf(payload), ILLMInferenceAgent.inferNumber.selector);
        (prompt,,,,) = abi.decode(_args(payload), (string, string, int256, int256, bool));
    }

    function _selectorOf(bytes memory payload) internal pure returns (bytes4 sel) {
        return bytes4(bytes.concat(payload[0], payload[1], payload[2], payload[3]));
    }

    function _args(bytes memory payload) internal pure returns (bytes memory out) {
        out = new bytes(payload.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = payload[i + 4];
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            uint256 j;
            while (j < n.length && h[i + j] == n[j]) {
                ++j;
            }
            if (j == n.length) return true;
        }
        return false;
    }
}
