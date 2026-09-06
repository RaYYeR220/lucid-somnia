// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LucidBrain, IJsonApiAgent, IPriceOracleAgent, IAgentPriceConsumer} from "../src/LucidBrain.sol";
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
        assertEq(r.agentId, brain.DEFAULT_ORACLE_AGENT_ID(), "the Price Oracle base agent");
        assertEq(r.agentId, 9911223344556677889, "the id the registry answers to on Shannon");
        assertEq(r.callbackAddress, address(brain));
        assertEq(r.callbackSelector, IAgentPriceConsumer.handlePrice.selector, "its own callback, not the verdict one");
        assertEq(r.subcommitteeSize, 3);
        assertEq(r.threshold, 2);
        assertEq(uint8(r.consensusType), uint8(IAgentRequester.ConsensusType.Threshold), "prices never match exactly");
        assertEq(r.value, STAGE1, "a fetch is priced under an inference");
        assertEq(brain.marketOfPriceRequest(priceId), MARKET);

        // And the payload really is getPrices(symbols, decimals), carrying the configured symbol.
        assertEq(_selectorOf(r.payload), IPriceOracleAgent.getPrices.selector);
        (string[] memory symbols, uint8 decimals) = abi.decode(_args(r.payload), (string[], uint8));
        assertEq(symbols.length, 1, "one window, one symbol");
        assertEq(symbols[0], "BTC/USDT", "the agent's own pair spelling, off its token list");
        assertEq(decimals, 2, "the venue publishes strikes in hundredths");
    }

    function test_the_default_feed_kind_is_the_price_oracle_with_the_json_fallback_armed() public view {
        LucidBrain.Feed memory btc = brain.feedOf(LucidTypes.ASSET_BTC);
        assertEq(uint8(btc.kind), uint8(LucidBrain.FeedKind.PriceOracle), "a median beats one venue's endpoint");
        assertEq(btc.symbol, "BTC/USDT");
        assertEq(btc.decimals, 2);
        // The documented agent stays configured, so falling back is one owner call and not a
        // decision about which endpoint to trust made in the middle of an outage.
        assertEq(btc.url, "https://api.coinbase.com/v2/prices/BTC-USD/spot", "the fallback is armed, not absent");
        assertEq(btc.selector, "data.amount");

        LucidBrain.Feed memory eth = brain.feedOf(LucidTypes.ASSET_ETH);
        assertEq(uint8(eth.kind), uint8(LucidBrain.FeedKind.PriceOracle));
        assertEq(eth.symbol, "ETH/USDT");

        assertEq(brain.oracleAgentId(), 9911223344556677889, "testnet-only, so a default and not a constant");
        assertEq(brain.feedAgentId(), 13174292974160097713, "the documented agent the fallback uses");
        assertEq(brain.maxFeedAgeMillis(), 60_000, "a median older than the shortest window is not a price");
        assertEq(brain.minSources(), 2, "one exchange is not a median");
    }

    function test_a_getPrices_response_is_decoded_and_element_zero_is_the_price() public {
        uint256 priceId = _requestPrice(_market(start + 900));

        // Three validators, each answering in the agent's three-array shape.
        _deliverPrices(priceId, _three(7_991_000, 7_991_240, 7_991_500));

        assertEq(platform.requestCount(), 2, "the inference goes out on the back of the median");
        assertTrue(
            _contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"),
            "the middle reading, taken out of element 0 of the arrays"
        );
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

    // ── the price-oracle guards ───────────────────────────────────────────────

    function test_a_stale_reading_is_discarded_like_a_zero() public {
        vm.prank(owner);
        brain.setFeedCommittee(5, 3);

        uint256 priceId = _requestPrice(_market(start + 900));

        uint64 nowMillis = uint64(block.timestamp * 1000);
        bytes[] memory results = new bytes[](5);
        // Three medians refreshed a moment ago, and two that stopped refreshing minutes back. The
        // stale pair would drag the median if age were merely noted rather than acted on.
        results[0] = _oracleResult(7_991_000, 3, nowMillis - 1_000);
        results[1] = _oracleResult(7_000_000, 3, nowMillis - 60_001);
        results[2] = _oracleResult(7_991_240, 3, nowMillis);
        results[3] = _oracleResult(9_000_000, 3, nowMillis - 600_000);
        results[4] = _oracleResult(7_991_500, 3, nowMillis - 59_000);

        vm.expectEmit(true, true, false, true, address(brain));
        emit LucidBrain.PriceGuardRejected(MARKET, priceId, 2, 0);
        _deliverRawPrices(priceId, results);

        assertTrue(
            _contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"),
            "the median of the three that were still refreshing"
        );
    }

    function test_a_reading_from_too_few_exchanges_is_discarded_like_a_zero() public {
        vm.prank(owner);
        brain.setFeedCommittee(5, 3);

        uint256 priceId = _requestPrice(_market(start + 900));

        uint64 nowMillis = uint64(block.timestamp * 1000);
        bytes[] memory results = new bytes[](5);
        // A "median" over one exchange is that exchange, and over none it is nothing at all.
        results[0] = _oracleResult(7_991_000, 3, nowMillis);
        results[1] = _oracleResult(7_000_000, 1, nowMillis);
        results[2] = _oracleResult(7_991_240, 2, nowMillis);
        results[3] = _oracleResult(9_000_000, 0, nowMillis);
        results[4] = _oracleResult(7_991_500, 7, nowMillis);

        vm.expectEmit(true, true, false, true, address(brain));
        emit LucidBrain.PriceGuardRejected(MARKET, priceId, 0, 2);
        _deliverRawPrices(priceId, results);

        assertTrue(
            _contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"),
            "the median of the readings that were actually medians"
        );
    }

    function test_when_every_reading_is_rejected_the_brain_refuses_and_spends_nothing() public {
        uint256 priceId = _requestPrice(_market(start + 900));
        uint256 floatBefore = address(brain).balance;

        uint64 nowMillis = uint64(block.timestamp * 1000);
        bytes[] memory results = new bytes[](3);
        results[0] = _oracleResult(SPOT, 3, nowMillis - 120_000); // stale
        results[1] = _oracleResult(SPOT, 1, nowMillis); // thin
        results[2] = _oracleResult(SPOT, 0, nowMillis - 90_000); // both

        vm.expectEmit(true, true, false, false, address(brain));
        emit LucidBrain.PriceUnusable(MARKET, priceId);
        _deliverRawPrices(priceId, results);

        assertEq(platform.requestCount(), 1, "a degraded median is not a price worth an inference");
        assertEq(address(brain).balance, floatBefore, "and nothing was spent trying");
        assertFalse(brain.verdictOf(MARKET).ok, "the zero-spend refusal, not a guess");
        assertEq(router.calls(), 1, "and the desk is still told");
    }

    /// @dev The guards are the whole reason this feed is safe to prefer, so a response the agent
    /// could not have produced must not reach the median either. Every one of these decodes to
    /// nothing usable, and none of them may revert the callback.
    function test_a_malformed_oracle_response_is_discarded_rather_than_fatal() public {
        vm.prank(owner);
        brain.setFeedCommittee(5, 3);

        uint256 priceId = _requestPrice(_market(start + 900));

        bytes[] memory results = new bytes[](5);
        results[0] = "";
        results[1] = abi.encode(uint256(7_991_240)); // the JsonApi shape, on the oracle path
        results[2] = _freshOracleResult(7_991_240);
        results[3] = abi.encode(new uint256[](0), new uint8[](0), new uint64[](0));
        results[4] = hex"deadbeef";

        _deliverRawPrices(priceId, results);

        assertEq(platform.requestCount(), 2, "the one honest reading still bought the inference");
        assertTrue(_contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"));
        assertEq(router.calls(), 0, "nothing refused, so nothing to announce yet");
    }

    function test_the_guards_are_owner_only_and_must_admit_less_than_everything() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setFeedGuards(1, 1);

        vm.startPrank(owner);
        // A zero age bound or a zero source floor is a guard that admits the thing it exists to
        // catch, which is worse than no guard at all because it reads as one.
        vm.expectRevert(abi.encodeWithSelector(LucidBrain.BadFeedGuard.selector, uint64(0), uint8(2)));
        brain.setFeedGuards(0, 2);

        vm.expectRevert(abi.encodeWithSelector(LucidBrain.BadFeedGuard.selector, uint64(60_000), uint8(0)));
        brain.setFeedGuards(60_000, 0);

        brain.setFeedGuards(5_000, 4);
        vm.stopPrank();

        assertEq(brain.maxFeedAgeMillis(), 5_000);
        assertEq(brain.minSources(), 4);

        // And a tightened floor is applied to the next answer, not merely recorded.
        uint256 priceId = _requestPrice(_market(start + 900));
        bytes[] memory results = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            results[i] = _oracleResult(SPOT, 3, uint64(block.timestamp * 1000));
        }
        _deliverRawPrices(priceId, results);

        assertEq(platform.requestCount(), 1, "three sources no longer clears a floor of four");
        assertFalse(brain.verdictOf(MARKET).ok);
    }

    // ── the two kinds ─────────────────────────────────────────────────────────

    function test_a_json_api_feed_still_works_end_to_end() public {
        _useJsonFeed(
            LucidTypes.ASSET_BTC, "BTC/USDT", "https://api.coinbase.com/v2/prices/BTC-USD/spot", "data.amount", 2
        );

        uint256 priceId = _requestPrice(_market(start + 900));

        MockAgentPlatform.Recorded memory r = platform.requestAt(0);
        assertEq(r.agentId, brain.DEFAULT_FEED_AGENT_ID(), "the documented JSON API Request agent");
        assertEq(_selectorOf(r.payload), IJsonApiAgent.fetchUint.selector);

        _deliverJsonPrices(priceId, _three(7_991_000, 7_991_240, 7_991_500));

        assertEq(platform.requestCount(), 2, "and the inference follows exactly as before");
        assertTrue(_contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"));

        _deliverScores(platform.idAt(platform.requestCount() - 1), _threeScores(70, 72, 74));
        LucidTypes.Verdict memory v = brain.verdictOf(MARKET);
        assertTrue(v.ok, "the fallback produces a tradeable verdict, not a degraded one");
        assertEq(v.probUpBps, 7200);
    }

    /// @dev The owner may repoint a feed while a request is in flight, and the two kinds answer in
    /// shapes that are not merely different — they are silently compatible in the wrong direction.
    /// A `getPrices` response read as a bare uint decodes to the head of its own ABI offset table,
    /// which is a number, and the committee would then be shown it as a price. So the decoder reads
    /// the kind off the request, never off storage.
    function test_the_kind_is_read_from_the_request_not_from_storage() public {
        // Out under the oracle kind.
        uint256 priceId = _requestPrice(_market(start + 900));
        assertEq(_selectorOf(platform.requestAt(0).payload), IPriceOracleAgent.getPrices.selector);

        // Repointed mid-flight to the JSON fallback.
        _useJsonFeed(
            LucidTypes.ASSET_BTC, "BTC/USDT", "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "price", 8
        );
        assertEq(uint8(brain.feedOf(LucidTypes.ASSET_BTC).kind), uint8(LucidBrain.FeedKind.JsonApi), "storage moved");

        // The answer that comes back is still an oracle answer, and is still read as one — at the
        // scale the request went out with, not the eight the new feed declares.
        _deliverPrices(priceId, _three(7_991_000, 7_991_240, 7_991_500));

        assertEq(platform.requestCount(), 2, "the reply to the request that was actually made");
        assertTrue(
            _contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"),
            "decoded as getPrices at two decimals, which is what was asked for"
        );
    }

    /// @dev The mirror image: a JSON request answered after the owner flipped the asset to the
    /// oracle. A bare uint256 is not a valid `getPrices` return, so reading it under the new kind
    /// would discard every reading and refuse a window that had a perfectly good price.
    function test_a_json_request_survives_a_repoint_to_the_oracle() public {
        _useJsonFeed(
            LucidTypes.ASSET_BTC, "BTC/USDT", "https://api.coinbase.com/v2/prices/BTC-USD/spot", "data.amount", 2
        );
        uint256 priceId = _requestPrice(_market(start + 900));

        vm.prank(owner);
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.PriceOracle, "BTC/USDT", "", "", 2);

        _deliverJsonPrices(priceId, _three(7_991_000, 7_991_240, 7_991_500));

        assertEq(platform.requestCount(), 2, "the price it fetched is still a price");
        assertTrue(_contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"));
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
        _useJsonFeed(
            LucidTypes.ASSET_BTC, "BTC/USDT", "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "price", 8
        );

        LucidBrain.Feed memory f = brain.feedOf(LucidTypes.ASSET_BTC);
        assertEq(uint8(f.kind), uint8(LucidBrain.FeedKind.JsonApi));
        assertEq(f.url, "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT");
        assertEq(f.selector, "price");
        assertEq(f.decimals, 8);

        _requestPrice(_market(start + 900));
        assertEq(platform.requestAt(0).agentId, brain.feedAgentId(), "and the JSON agent is who gets asked");
        assertEq(_selectorOf(platform.requestAt(0).payload), IJsonApiAgent.fetchUint.selector);
        (string memory url, string memory sel, uint8 decimals) =
            abi.decode(_args(platform.requestAt(0).payload), (string, string, uint8));
        assertEq(url, "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "the committee fetches the new one");
        assertEq(sel, "price");
        assertEq(decimals, 8);
    }

    function test_only_the_owner_can_repoint_a_feed() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.JsonApi, "", "https://evil.example/price", "p", 2);

        LucidBrain.Feed memory f = brain.feedOf(LucidTypes.ASSET_BTC);
        assertEq(uint8(f.kind), uint8(LucidBrain.FeedKind.PriceOracle), "the kind is not open to the street either");
        assertEq(f.symbol, "BTC/USDT", "the feed every verdict is built on is not open to the street");
        assertEq(f.url, "https://api.coinbase.com/v2/prices/BTC-USD/spot");
    }

    function test_feeds_are_per_asset() public {
        assertEq(brain.feedOf(LucidTypes.ASSET_ETH).symbol, "ETH/USDT");

        vm.prank(owner);
        brain.setFeed(
            LucidTypes.ASSET_ETH,
            LucidBrain.FeedKind.PriceOracle,
            "ETH/USDC",
            "https://api.coinbase.com/v2/prices/ETH-USD/buy",
            "data.amount",
            2
        );

        assertEq(brain.feedOf(LucidTypes.ASSET_ETH).symbol, "ETH/USDC");
        assertEq(brain.feedOf(LucidTypes.ASSET_ETH).url, "https://api.coinbase.com/v2/prices/ETH-USD/buy");
        assertEq(brain.feedOf(LucidTypes.ASSET_BTC).symbol, "BTC/USDT", "repointing one asset does not touch another");
    }

    /// @dev Each kind is validated against the one field it is actually fetched by, because the
    /// other half is an armed fallback rather than a requirement. Setting an oracle feed with no
    /// symbol, or a JSON feed with no endpoint, would leave the asset silently unpriceable.
    function test_a_feed_must_be_usable_for_the_kind_it_declares() public {
        vm.startPrank(owner);

        // A PriceOracle feed with no symbol has nothing to ask the agent about.
        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(
            LucidTypes.ASSET_BTC,
            LucidBrain.FeedKind.PriceOracle,
            "",
            "https://api.coinbase.com/v2/prices/BTC-USD/spot",
            "data.amount",
            2
        );

        // A JsonApi feed needs both halves of a fetch, and having a symbol does not substitute.
        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.JsonApi, "BTC/USDT", "", "data.amount", 2);

        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(
            LucidTypes.ASSET_BTC,
            LucidBrain.FeedKind.JsonApi,
            "BTC/USDT",
            "https://api.coinbase.com/v2/prices/BTC-USD/spot",
            "",
            2
        );

        // Past eighteen the rescale to the venue's hundredths could overflow a garbage response,
        // whichever agent produced it.
        vm.expectRevert(LucidBrain.BadFeed.selector);
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.PriceOracle, "BTC/USDT", "", "", 19);

        // And the mirror image of each: the field the kind needs is enough on its own.
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.PriceOracle, "BTC/USDT", "", "", 2);
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.JsonApi, "", "https://x.example/p", "price", 2);
        vm.stopPrank();
    }

    function test_a_feed_on_another_scale_is_normalised_to_the_strike() public {
        _useJsonFeed(
            LucidTypes.ASSET_BTC, "BTC/USDT", "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT", "price", 8
        );

        uint256 priceId = _requestPrice(_market(start + 900));
        // 79912.40 at eight decimals. Compared against a hundredths strike unconverted, this would
        // read as a market that had moved by a factor of a million.
        _deliverJsonPrices(priceId, _three(7_991_240_000_000, 7_991_240_000_000, 7_991_240_000_000));

        string memory prompt = _promptOf(platform.lastRequest().payload);
        assertTrue(_contains(prompt, "Spot: 79912.40"), "the same price, on the venue's scale");
        assertTrue(_contains(prompt, "Distance to strike: +3 bps"), "and a distance that means something");
    }

    /// @dev The same normalisation on the oracle path, where the scale is what `getPrices` was
    /// asked to answer in rather than what an endpoint happens to publish.
    function test_an_oracle_feed_on_another_scale_is_normalised_to_the_strike() public {
        vm.prank(owner);
        brain.setFeed(LucidTypes.ASSET_BTC, LucidBrain.FeedKind.PriceOracle, "BTC/USDT", "", "", 8);

        uint256 priceId = _requestPrice(_market(start + 900));
        (, uint8 decimals) = abi.decode(_args(platform.requestAt(0).payload), (string[], uint8));
        assertEq(decimals, 8, "the agent is asked for the scale the feed declares");

        _deliverPrices(priceId, _three(7_991_240_000_000, 7_991_240_000_000, 7_991_240_000_000));
        assertTrue(_contains(_promptOf(platform.lastRequest().payload), "Spot: 79912.40"));
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

    /// @dev A separate setter from `setFeedAgent`, because the two agents answer in different
    /// shapes and one mistyped id across a shared setter would point an oracle feed at the JSON
    /// agent — which returns bytes that decode as nothing, so every window would quietly refuse.
    function test_only_the_owner_can_repoint_the_oracle_agent() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        brain.setOracleAgent(1);

        vm.prank(owner);
        brain.setOracleAgent(7);
        assertEq(brain.oracleAgentId(), 7);
        assertEq(brain.feedAgentId(), 13174292974160097713, "and the JSON agent is untouched");

        _requestPrice(_market(start + 900));
        assertEq(platform.requestAt(0).agentId, 7, "the oracle feed follows the oracle id");
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

    /// @dev One validator's `getPrices` return: three parallel arrays, one entry each. Named
    /// arguments everywhere it matters, because the two guards under test both live in fields a
    /// positional tuple would hide.
    function _oracleResult(uint256 price, uint8 sources, uint64 updatedMillis) internal pure returns (bytes memory) {
        uint256[] memory p = new uint256[](1);
        uint8[] memory n = new uint8[](1);
        uint64[] memory u = new uint64[](1);
        (p[0], n[0], u[0]) = (price, sources, updatedMillis);
        return abi.encode(p, n, u);
    }

    /// @dev A healthy reading: three exchanges, refreshed this second.
    function _freshOracleResult(uint256 price) internal view returns (bytes memory) {
        return _oracleResult(price, 3, uint64(block.timestamp * 1000));
    }

    function _deliverPrices(uint256 id, uint256[] memory prices) internal {
        _deliverPricesWithStatus(id, prices, IAgentRequester.ResponseStatus.Success);
    }

    function _deliverPricesWithStatus(uint256 id, uint256[] memory prices, IAgentRequester.ResponseStatus status)
        internal
    {
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](prices.length);
        for (uint256 i; i < prices.length; ++i) {
            rs[i] = _response(i, _freshOracleResult(prices[i]));
        }
        platform.deliverPrice(address(brain), id, rs, status);
    }

    /// @dev The `JsonApi` shape: a bare uint256 per validator, which is what `fetchUint` returns.
    function _deliverJsonPrices(uint256 id, uint256[] memory prices) internal {
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](prices.length);
        for (uint256 i; i < prices.length; ++i) {
            rs[i] = _response(i, abi.encode(prices[i]));
        }
        platform.deliverPrice(address(brain), id, rs, IAgentRequester.ResponseStatus.Success);
    }

    /// @dev Delivers raw response bodies, so a test can hand the brain bytes no honest agent would
    /// ever produce.
    function _deliverRawPrices(uint256 id, bytes[] memory results) internal {
        IAgentRequester.Response[] memory rs = new IAgentRequester.Response[](results.length);
        for (uint256 i; i < results.length; ++i) {
            rs[i] = _response(i, results[i]);
        }
        platform.deliverPrice(address(brain), id, rs, IAgentRequester.ResponseStatus.Success);
    }

    /// @dev Repoints an asset at the documented JSON fallback, carrying the oracle symbol along so
    /// the flip is the one field it is meant to be.
    function _useJsonFeed(bytes32 assetKey, string memory symbol, string memory url, string memory sel, uint8 dec)
        internal
    {
        vm.prank(owner);
        brain.setFeed(assetKey, LucidBrain.FeedKind.JsonApi, symbol, url, sel, dec);
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
