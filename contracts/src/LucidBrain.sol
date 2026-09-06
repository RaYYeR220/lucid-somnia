// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAgentRequester, IAgentConsumer, ILLMInferenceAgent} from "./interfaces/IAgentRequester.sol";
import {ILucidBrain, ILucidRouter} from "./interfaces/ILucid.sol";
import {LucidTypes} from "./types/LucidTypes.sol";
import {PromptLib} from "./lib/PromptLib.sol";

/// @notice The pre-deployed JSON API Request base agent ("json-fetch"), used only for its function
/// selectors when ABI-encoding the request payload.
/// @dev Confirmed against the on-chain agent registry rather than the docs, which ship a
/// placeholder id: `AgentRegistry` at 0x08D1Fc808f1983d2Ea7B63a28ECD4d8C885Cd02A answers
/// `getAllAgents()` on both Somnia mainnet (5031) and Shannon testnet (50312), and
/// `getAgent(13174292974160097713)` returns the `agents/json-fetch/...json` manifest whose `name`
/// is "JSON API Request" and whose ABI carries exactly the signatures below.
interface IJsonApiAgent {
    /// @param url A public endpoint the agent fetches with a plain GET.
    /// @param selector Dot-notation path into the JSON body, e.g. `data.amount` or `items[0].name`.
    /// @param decimals Fixed-point scale: the parsed value is multiplied by 10**decimals.
    function fetchUint(string calldata url, string calldata selector, uint8 decimals) external returns (uint256);
}

/// @notice The pre-deployed Price Oracle base agent, used only for its function selector when
/// ABI-encoding the request payload.
/// @dev Undocumented, and confirmed the same way `IJsonApiAgent` was: `AgentRegistry` at
/// 0x08D1Fc808f1983d2Ea7B63a28ECD4d8C885Cd02A answers `getAgent(9911223344556677889)` on Shannon
/// testnet (50312) with the `agents/price-oracle/...json` manifest, whose `name` is "Price Oracle"
/// and whose ABI carries exactly the signature below. The same call on Somnia mainnet (5031)
/// reverts with `AgentRegistry: agent not found`, which is why this is a default and not a
/// constant the deployment is welded to — see `FeedKind` for what that buys.
///
/// The manifest also lists `getPricesPacked`, `getPricesSlots` and
/// `getExchangePrice(string,string,uint8,uint64)`. Only `getPrices` is used here: the packed forms
/// drop the source count and the timestamp, which are the two fields the guards below exist to
/// read, and `getExchangePrice` names a single venue, which is the thing a median is for avoiding.
interface IPriceOracleAgent {
    /// @param symbols Trading pairs in the agent's own `BASE/QUOTE` form, e.g. `BTC/USDT`.
    /// @param decimals Fixed-point scale the prices are returned in.
    /// @return prices The median price across exchanges, one per requested symbol.
    /// @return numSources How many exchanges that median was taken over.
    /// @return lastUpdated When each median was last refreshed, as a unix timestamp in
    /// milliseconds — the sibling `getExchangePrice` names the same field `lastUpdatedMillis`.
    function getPrices(string[] calldata symbols, uint8 decimals)
        external
        returns (uint256[] memory prices, uint8[] memory numSources, uint64[] memory lastUpdated);
}

/// @notice Callback interface for a consumer of the price stage. Same shape as
/// `IAgentConsumer.handleResponse`; a distinct selector is what keeps the two stages apart when the
/// platform calls back.
interface IAgentPriceConsumer {
    function handlePrice(
        uint256 requestId,
        IAgentRequester.Response[] memory responses,
        IAgentRequester.ResponseStatus status,
        IAgentRequester.Request memory request
    ) external;
}

/// @title LucidBrain
/// @notice Asks Somnia's validator committee to score one market window, and reduces the answers
/// to a single verdict the rest of the protocol can act on.
/// @dev This is the protocol's only trust boundary with something that is not deterministic code,
/// so every path through it ends in a stored verdict and a router notification. There is no path
/// that ends in silence: a desk waiting on a verdict that never arrives would sit exposed with no
/// way to say why, which is strictly worse than a refusal.
///
/// A verdict takes two committee calls, in order, because one is not enough to ask an answerable
/// question. These windows settle against the price they opened at, so the strike *is* the opening
/// price; asking whether the close will be above the open, without saying where the price is now,
/// has exactly one honest answer, and the live committee gave it — 50, 50, 50. Stage one therefore
/// fetches the spot price through a price agent, and only once that lands does stage
/// two ask the LLM committee to price the window with the move-so-far in front of it. Both stages
/// are validator consensus; nothing in this contract talks to a server the operator runs.
contract LucidBrain is ILucidBrain, IAgentConsumer, IAgentPriceConsumer, Ownable {
    /// @notice The pre-deployed LLM Inference base agent every Somnia validator can run.
    uint256 public constant AGENT_ID = 12847293847561029384;

    /// @notice The JSON API Request base agent, as registered on both Somnia networks.
    /// @dev Seeds `feedAgentId`. Somnia labels Agents a prototype and reserves the right to move
    /// ids, so this is a default rather than a constant the deployment is welded to.
    uint256 public constant DEFAULT_FEED_AGENT_ID = 13174292974160097713;

    /// @notice The Price Oracle base agent, as registered on Shannon testnet only.
    /// @dev Seeds `oracleAgentId`, and is a default for a stronger reason than the one above: the
    /// registry has no entry for this id on mainnet at all. See `FeedKind`.
    uint256 public constant DEFAULT_ORACLE_AGENT_ID = 9911223344556677889;

    /// @notice How old a Price Oracle median may be before this contract stops calling it a price.
    /// @dev Sixty seconds, in the milliseconds the agent reports. The shortest window the venue
    /// rolls is sixty seconds, so a median older than that describes a window that has already
    /// closed. Tunable, because the agent's own refresh cadence is not a constant of nature.
    uint64 public constant DEFAULT_MAX_FEED_AGE_MILLIS = 60_000;

    /// @notice How many exchanges a Price Oracle median must be taken over to count as a median.
    /// @dev Two. One exchange is not a median, it is a single venue wearing a median's name — which
    /// is precisely the failure mode this feed exists to remove. The agent's own configuration asks
    /// for three by default, so this floor is deliberately below it: the guard is here to catch a
    /// degraded reading, not to second-guess the agent when it is healthy.
    uint8 public constant DEFAULT_MIN_SOURCES = 2;

    /// @notice Gas ceiling on the self-call that decodes one Price Oracle reading.
    /// @dev A committee response is arbitrary bytes, and `abi.decode` of a dynamic array reads its
    /// length from those bytes. A hostile length would expand memory until the frame is gone, and a
    /// `try` that catches an out-of-gas has already lost 63/64 of what the callback needed to finish
    /// notifying the router. Capping the call is what keeps that a discarded reading.
    uint256 internal constant DECODE_GAS = 200_000;

    /// @notice The platform's reward per validator for an LLM inference, on top of its deposit floor.
    uint256 internal constant LLM_PER_AGENT_COST = 0.07 ether;

    /// @notice The platform's reward per validator for a JSON fetch.
    /// @dev A single HTTP call with no GPU behind it, so runners price it well under an inference.
    /// Underpaying is not a cheaper request, it is an ignored one: runners read the budget off
    /// `RequestCreated` and skip anything below their price, and the request then times out.
    uint256 internal constant FEED_PER_AGENT_COST = 0.03 ether;

    /// @notice Seconds the platform waits for either committee before reporting a timeout.
    /// @dev Sized against the shortest window the venue rolls (60s) plus settlement slack: a
    /// verdict that lands after expiry is useless, and the timeout is what turns it into a refusal.
    uint256 internal constant REQUEST_TIMEOUT = 300;

    /// @dev The answer domain. The agent is asked for a probability, and anything outside this
    /// range is a broken answer rather than a confident one.
    int256 internal constant MIN_SCORE = 0;
    int256 internal constant MAX_SCORE = 100;

    /// @dev The coin-flip line, used to decide which way a validator voted.
    int256 internal constant COIN_FLIP = 50;

    /// @dev The venue publishes strikes in hundredths of a dollar, so every price this contract
    /// reasons about is normalised to that scale before it is compared with one.
    uint8 internal constant PRICE_SCALE_DECIMALS = 2;

    /// @dev A fetched price this far from the window's opening price is not a price. Over a window
    /// measured in minutes the spot cannot be an order of magnitude from the strike, so a reading
    /// outside the band is a validator that parsed an error body, hit a rate limit, or read the
    /// wrong asset — none of which the median should be asked to absorb.
    uint256 internal constant PRICE_SANITY_MULTIPLE = 10;

    /// @dev Ceiling on a raw fetched value before rescaling, so a garbage response cannot overflow
    /// the scale conversion and revert the callback along with the router notification.
    uint256 internal constant MAX_RAW_PRICE = 1e36;

    /// @dev How much outcome history survives the gap between the two stages. Must equal
    /// `PromptLib.MAX_OUTCOMES` — anything the prompt would not render is a storage word bought for
    /// nothing — and is restated here because Solidity will not size an array from another unit's
    /// constant. `test_pending_history_matches_the_prompt_window` fails if the two drift apart.
    uint256 internal constant PENDING_OUTCOMES = 5;

    /// @dev The default committee instruction. It is deliberately blunt about the output format,
    /// because a validator that answers in prose produces a result this contract must discard, and
    /// it names what the strike actually is: these windows open at the strike, so the distance the
    /// prompt carries is the entire move the committee is being asked to extrapolate.
    string internal constant DEFAULT_SYSTEM_PROMPT = "You price short-dated binary crypto markets. The strike is the price the window opened at "
        "and the spot is the price now, so the distance between them is the move so far. Given the "
        "facts, reply with a single integer from 0 to 100: the probability in percent that the "
        "settlement price is strictly above the strike at expiry. 50 means a coin flip. Reply with "
        "the number only, no words, no symbols.";

    // ─────────────────────────────────────────────────────────────────────────
    // Deadline guard
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Floor on the slack a window must have left before the brain will spend on it.
    /// @dev Matches `LucidTypes.MIN_WINDOW_SLACK`: below this the venue rejects the order anyway,
    /// so a verdict bought here could never be traded even if it arrived instantly.
    uint256 public constant MIN_SLACK = 90;

    /// @notice Ceiling on the required slack.
    /// @dev Without it a run of slow committees would ratchet the requirement past the length of
    /// every window the venue rolls, and the brain would quietly stop working while looking healthy.
    uint256 public constant MAX_SLACK = 600;

    /// @notice The latency each stage is assumed to take before it has ever been observed.
    /// @dev Sixty seconds each. The live committee has answered in about a second and has also
    /// taken forty, and the cost of the two errors is not symmetric: assuming it is fast buys a
    /// verdict that expires before it can be used, assuming it is slow only skips a window. So the
    /// seed is deliberately pessimistic and the measurements walk it down.
    uint64 internal constant SEED_LATENCY = 60;

    /// @notice Observed round-trip of the price stage, in seconds, as an exponential moving average.
    uint64 public feedLatencyEma;

    /// @notice Observed round-trip of the verdict stage, in seconds, as an exponential moving average.
    uint64 public verdictLatencyEma;

    // ─────────────────────────────────────────────────────────────────────────
    // Wiring
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Somnia's agent platform. Verified live on Shannon at
    /// 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776.
    IAgentRequester public immutable PLATFORM;

    /// @notice The router that fans verdicts out to desks.
    address public router;

    /// @notice The JSON API Request agent a `JsonApi` feed is sent to.
    uint256 public feedAgentId;

    /// @notice The Price Oracle agent a `PriceOracle` feed is sent to.
    uint256 public oracleAgentId;

    /// @notice How stale a Price Oracle reading may be, in milliseconds, before it is discarded.
    uint64 public maxFeedAgeMillis;

    /// @notice How few exchanges a Price Oracle reading may rest on before it is discarded.
    uint8 public minSources;

    /// @notice The committee's standing instruction.
    /// @dev Held in storage, not code, so it can be tuned by transaction. Prompt quality is the one
    /// part of this system that improves with observation, and redeploying the brain would orphan
    /// every stored verdict and force the router to be re-pointed.
    string public systemPrompt;

    /// @notice How many validators are asked to score the window.
    uint8 public committeeSize;

    /// @notice How many usable answers a verdict needs before a desk may act on it.
    uint8 public committeeThreshold;

    /// @notice How many validators are asked to fetch the price.
    uint8 public feedCommitteeSize;

    /// @notice How many of them must answer before the platform finalises the price request.
    uint8 public feedThreshold;

    /// @notice Which committee agent an asset's spot price is fetched with.
    ///
    /// @dev `PriceOracle` is the default because it is a strictly better input: a median across
    /// seven exchanges, with the source count and the refresh time attached, instead of one venue's
    /// REST endpoint taken on faith. It also removes a failure this protocol has already had to
    /// design around — a single venue geo-blocking part of a validator set costs a committee member
    /// on every request, which is why the JSON feed points at Coinbase rather than Binance in the
    /// first place. A median cannot be geo-blocked out of existence.
    ///
    /// @dev `JsonApi` remains because the Price Oracle agent is undocumented and, as of the
    /// registry read above, exists on Shannon and not on mainnet. Somnia may retire it, move its
    /// id, or ship it to mainnet under another one; none of those may be allowed to stop this
    /// protocol pricing a window. So the better feed is the default and the documented one is one
    /// owner transaction away, per asset, with no redeploy that would orphan a stored verdict.
    enum FeedKind {
        PriceOracle,
        JsonApi
    }

    /// @notice Where one asset's spot price is fetched from.
    /// @dev Storage, never a constant. DreamDEX settles these windows against its own Prophecy
    /// Oracle, so any external price series is a *different* one: it can lead, lag or simply
    /// disagree with the number the market resolves on. That basis risk is real and cannot be
    /// engineered away here — what can be engineered is the ability to repoint the feed the hour it
    /// starts mattering, without a redeploy that would orphan every stored verdict.
    /// @dev Both halves are kept side by side rather than in a union, so an asset can carry a live
    /// `PriceOracle` symbol *and* an armed `JsonApi` endpoint. Falling back is then a one-field
    /// change made in the minute it is needed, not a configuration written under pressure.
    struct Feed {
        FeedKind kind;
        string symbol;
        string url;
        string selector;
        uint8 decimals;
    }

    mapping(bytes32 assetKey => Feed) internal _feeds;

    /// @dev Everything stage two needs, carried across the gap between the two callbacks. Only the
    /// three market fields the prompt actually reads are kept, plus the history tail the prompt
    /// renders, because this is written on every request and Somnia charges accordingly.
    ///
    /// `feedKind` and `decimals` are snapshots of the feed as it stood when the request went out,
    /// not lookups against current storage. The owner can repoint a feed while a request is in
    /// flight, and a `getPrices` response decoded as a bare uint — or a price rescaled by the wrong
    /// exponent — does not fail loudly. It produces a number, and the committee prices the window
    /// against it. The two extra bytes fit in the slot `expiry` already opened.
    struct Pending {
        bytes32 marketId;
        bytes32 assetKey;
        uint256 strike;
        uint64 expiry;
        uint64 requestedAt;
        uint32 pBookBps;
        uint8 outcomeCount;
        FeedKind feedKind;
        uint8 decimals;
        uint16[PENDING_OUTCOMES] outcomes;
    }

    /// @dev A stage-two request in flight. `expiry` rides along so a verdict can be judged late
    /// without a second lookup, and `requestedAt` is what the latency average is measured from.
    struct PendingVerdict {
        bytes32 marketId;
        uint64 expiry;
        uint64 requestedAt;
    }

    mapping(uint256 requestId => Pending) internal _pendingPrice;
    mapping(uint256 requestId => PendingVerdict) internal _pendingVerdict;

    mapping(bytes32 marketId => LucidTypes.Verdict) internal _verdicts;

    /// @notice The platform is the only address allowed to deliver a committee result.
    error NotPlatform();
    /// @notice Only the router or the owner may spend the brain's float on a request.
    error NotAuthorized();
    /// @notice The brain does not hold enough native currency to pay the committee.
    error Underfunded(uint256 needed, uint256 available);
    /// @notice A committee must have at least one member and a threshold it can actually reach.
    error BadCommittee(uint8 size, uint8 threshold);
    /// @notice A callback arrived for a request this contract did not make, or already answered.
    error UnknownRequest(uint256 requestId);
    /// @notice The agent platform address is required at construction.
    error ZeroPlatform();
    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice The sweep recipient rejected the transfer.
    error SweepFailed();
    /// @notice A feed needs whatever its kind is actually fetched with, and a scale this contract
    /// can normalise: a symbol for `PriceOracle`, an endpoint and a selector for `JsonApi`.
    error BadFeed();
    /// @notice A reading guard that admits everything admits a stale or single-source price.
    error BadFeedGuard(uint64 maxAgeMillis, uint8 minSources);

    event VerdictRequested(
        bytes32 indexed marketId, uint256 indexed requestId, uint8 size, uint8 threshold, uint256 deposit
    );
    /// @dev `scores` carries every raw validator answer, including the ones discarded as
    /// out-of-range, so the committee vote can be shown exactly as it came in.
    event VerdictReceived(
        bytes32 indexed marketId,
        uint256 indexed requestId,
        uint16 probUpBps,
        uint8 responded,
        uint8 agreed,
        bool ok,
        int256[] scores
    );
    event PriceRequested(
        bytes32 indexed marketId, uint256 indexed requestId, bytes32 indexed assetKey, uint256 deposit
    );
    /// @dev `prices` carries every raw validator reading, including the ones discarded, so a
    /// disagreeing feed can be seen rather than inferred from a moved median.
    event PriceReceived(
        bytes32 indexed marketId, uint256 indexed requestId, uint256 spot, uint8 used, uint256[] prices
    );
    /// @notice No usable price came back, so no verdict was bought.
    event PriceUnusable(bytes32 indexed marketId, uint256 indexed requestId);
    /// @notice Readings the Price Oracle guards threw away, and which guard threw each one away.
    /// @dev Emitted only when a guard actually fired. A median that quietly thinned out to one
    /// exchange, or that stopped refreshing, is the exact degradation these guards exist to catch,
    /// and catching it silently would leave the operator reading a healthy-looking log.
    event PriceGuardRejected(bytes32 indexed marketId, uint256 indexed requestId, uint8 stale, uint8 thin);
    /// @notice The window was already too short to survive both stages, so nothing was spent.
    event WindowTooTight(bytes32 indexed marketId, uint256 secondsLeft, uint256 requiredSlack);
    /// @notice The price landed, but the window can no longer take the verdict stage.
    event LateAbort(bytes32 indexed marketId, uint256 secondsLeft, uint256 needed);
    /// @notice The verdict arrived after the window closed. Recorded, never tradeable.
    event VerdictTooLate(bytes32 indexed marketId, uint256 expiry, uint256 arrivedAt);
    /// @notice The asset has no configured price feed, so the window cannot be priced honestly.
    event NoFeed(bytes32 indexed marketId, bytes32 indexed assetKey);
    /// @notice The float ran out between the two stages.
    event StageTwoUnfunded(bytes32 indexed marketId, uint256 needed, uint256 available);
    /// @dev `stage` is 1 for the price fetch and 2 for the verdict.
    event LatencyObserved(uint8 indexed stage, uint256 observed, uint256 ema);
    event RouterCallFailed(bytes32 indexed marketId, uint256 indexed requestId);
    event PromptUpdated(string system);
    event CommitteeUpdated(uint8 size, uint8 threshold);
    event FeedCommitteeUpdated(uint8 size, uint8 threshold);
    event FeedUpdated(
        bytes32 indexed assetKey, FeedKind kind, string symbol, string url, string selector, uint8 decimals
    );
    event FeedAgentUpdated(uint256 agentId);
    event OracleAgentUpdated(uint256 agentId);
    event FeedGuardsUpdated(uint64 maxFeedAgeMillis, uint8 minSources);
    event RouterUpdated(address router);
    event Swept(address indexed to, uint256 amount);

    /// @param owner_ The address allowed to tune the prompt, committee, feeds and router.
    /// @param platform_ Somnia's agent platform for this chain.
    constructor(address owner_, address platform_) Ownable(owner_) {
        if (platform_ == address(0)) revert ZeroPlatform();
        PLATFORM = IAgentRequester(platform_);
        systemPrompt = DEFAULT_SYSTEM_PROMPT;
        committeeSize = 3;
        committeeThreshold = 2;
        feedCommitteeSize = 3;
        feedThreshold = 2;
        feedAgentId = DEFAULT_FEED_AGENT_ID;
        oracleAgentId = DEFAULT_ORACLE_AGENT_ID;
        maxFeedAgeMillis = DEFAULT_MAX_FEED_AGE_MILLIS;
        minSources = DEFAULT_MIN_SOURCES;
        feedLatencyEma = SEED_LATENCY;
        verdictLatencyEma = SEED_LATENCY;

        // Both halves of each asset are seeded, so the fallback is armed rather than merely
        // possible. `BTC/USDT` and `ETH/USDT` are the agent's own pair spellings, read off the
        // token list its image ships; a symbol it does not track comes back as a reading with no
        // sources, which the guards below discard rather than trade on.
        //
        // The JSON half points at Coinbase rather than the venue's own price feed, which is GraphQL
        // over POST: the JSON API agent takes a url and a selector and nothing else, so a query that
        // must travel in a request body is unreachable to it. Coinbase over Binance because
        // validators are spread across jurisdictions and Binance answers some of them with a
        // geo-block, which costs a committee member on every single request. Two decimals on both
        // halves to match the venue's strike scale.
        _setFeed(
            LucidTypes.ASSET_BTC,
            FeedKind.PriceOracle,
            "BTC/USDT",
            "https://api.coinbase.com/v2/prices/BTC-USD/spot",
            "data.amount",
            2
        );
        _setFeed(
            LucidTypes.ASSET_ETH,
            FeedKind.PriceOracle,
            "ETH/USDT",
            "https://api.coinbase.com/v2/prices/ETH-USD/spot",
            "data.amount",
            2
        );
    }

    /// @notice Accepts the native-currency float the committee is paid from.
    /// @dev One funded brain serves every desk, so a desk never has to hold the chain's gas token.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice What one full verdict costs right now: both committee calls.
    /// @dev The router funds this in one payment at request time, but only the first stage is spent
    /// then. The rest stays as float and pays for stage two from inside the price callback, where
    /// there is no caller to attach value to. A brain that is funded for exactly one stage will
    /// therefore buy a price and then refuse the verdict, which is why `requestVerdict` checks for
    /// both up front. Keep the brain funded; `sweep` recovers whatever is left over.
    /// @return weiNeeded The value the platform will take across both stages.
    function quote() external view returns (uint256 weiNeeded) {
        return _quoteStage1() + _quoteStage2();
    }

    /// @notice What the price fetch costs at the current feed committee size.
    /// @return The value the platform takes for stage one.
    function quoteStage1() external view returns (uint256) {
        return _quoteStage1();
    }

    /// @notice What the verdict inference costs at the current committee size.
    /// @dev Paid out of the brain's float from inside `handlePrice`, where there is no caller to
    /// attach value to, so the brain must be holding it by then.
    /// @return The value the platform takes for stage two.
    function quoteStage2() external view returns (uint256) {
        return _quoteStage2();
    }

    /// @notice How much of a window must remain before the brain will start spending on it.
    /// @dev Both stages have to finish *and* leave the desk time to trade, so the requirement is
    /// twice the measured round trip plus thirty seconds of execution room, clamped at both ends.
    /// It is self-calibrating on purpose: a fixed constant would either refuse every window on a
    /// slow day or buy unusable verdicts on a fast one, and which of those is happening is exactly
    /// what the contract can measure and a deployer cannot guess.
    /// @return The required remaining seconds, between `MIN_SLACK` and `MAX_SLACK`.
    function requiredSlack() public view returns (uint256) {
        uint256 needed = (uint256(feedLatencyEma) + uint256(verdictLatencyEma)) * 2 + 30;
        if (needed < MIN_SLACK) return MIN_SLACK;
        if (needed > MAX_SLACK) return MAX_SLACK;
        return needed;
    }

    /// @notice The last verdict recorded for a market.
    /// @param marketId The venue's market identifier.
    /// @return The verdict. A market that was never asked about reads back with ok = false, which
    /// is the same answer a desk gets when the committee failed, and is the safe default.
    function verdictOf(bytes32 marketId) external view returns (LucidTypes.Verdict memory) {
        return _verdicts[marketId];
    }

    /// @notice The price feed configured for one asset.
    /// @param assetKey The venue's asset hash, as in `LucidTypes.ASSET_BTC`.
    /// @return The kind, symbol, endpoint, selector and scale stage one will fetch with. A feed
    /// missing the field its own kind is fetched by is unconfigured, and windows on it are refused
    /// rather than priced blind.
    function feedOf(bytes32 assetKey) external view returns (Feed memory) {
        return _feeds[assetKey];
    }

    /// @notice Decodes one Price Oracle reading out of a raw committee response.
    /// @dev External, and reached only through `this.`, purely as a revert boundary: `abi.decode`
    /// reverts on a truncated or malformed response and panics on an empty array, and inside
    /// `handlePrice` either would take the router notification down along with the bad answer. The
    /// `try` around this call is what turns a broken reading into a discarded one.
    /// @param result One validator's raw `getPrices` return data.
    /// @return price The median for the single symbol that was asked about.
    /// @return numSources How many exchanges that median was taken over.
    /// @return lastUpdated When it was last refreshed, as a unix timestamp in milliseconds.
    function decodeOracleReading(bytes calldata result)
        external
        pure
        returns (uint256 price, uint8 numSources, uint64 lastUpdated)
    {
        (uint256[] memory prices, uint8[] memory sources, uint64[] memory updated) =
            abi.decode(result, (uint256[], uint8[], uint64[]));
        // One symbol goes out, so one reading comes back. Anything shorter is a runner that
        // answered without observing the pair it was asked about.
        return (prices[0], sources[0], updated[0]);
    }

    /// @notice Which market a pending verdict request belongs to, or zero once it is answered.
    /// @param requestId The platform request id returned by the verdict stage.
    /// @return The market id, or zero.
    function marketOfRequest(uint256 requestId) external view returns (bytes32) {
        return _pendingVerdict[requestId].marketId;
    }

    /// @notice Which market a pending price request belongs to, or zero once it is answered.
    /// @param requestId The platform request id returned by `requestVerdict`.
    /// @return The market id, or zero.
    function marketOfPriceRequest(uint256 requestId) external view returns (bytes32) {
        return _pendingPrice[requestId].marketId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Stage 1 — price
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Start the two-stage committee run for one market window.
    /// @dev Restricted to the router and the owner because each call spends the shared float. This
    /// fires the price fetch only; the verdict is bought from inside `handlePrice` once a usable
    /// price exists, so the brain must hold the full `quote()` when this is called even though only
    /// part of it leaves now.
    ///
    /// A refusal is not a revert. When the window cannot take both stages the brain records a
    /// verdict with ok = false, tells the router so the desk can say why it stood down, and returns
    /// zero having spent nothing. Callers that distinguish "asked" from "refused" should read the
    /// returned id rather than the absence of a revert.
    /// @param marketId The venue's market identifier, used to key the verdict when it lands.
    /// @param m The market the committee is asked about.
    /// @param pBookBps The book-implied UP probability at request time, in bps of probability.
    /// @param recentOutcomes Past window results, oldest first; any non-zero entry means UP.
    /// @return requestId The platform request the price will arrive under, or zero if refused.
    function requestVerdict(
        bytes32 marketId,
        LucidTypes.MarketInfo calldata m,
        uint256 pBookBps,
        uint16[] calldata recentOutcomes
    ) external payable returns (uint256 requestId) {
        if (msg.sender != router && msg.sender != owner()) revert NotAuthorized();

        uint256 slack = requiredSlack();
        uint256 secondsLeft = m.expiry > block.timestamp ? m.expiry - block.timestamp : 0;
        if (secondsLeft < slack) {
            _refuse(marketId, 0);
            emit WindowTooTight(marketId, secondsLeft, slack);
            return 0;
        }

        Feed memory f = _feeds[m.assetKey];
        if (!_configured(f)) {
            // Without a spot price the committee would be asked the unanswerable question again,
            // and would answer 50. Refusing is the honest outcome, and it is loud.
            _refuse(marketId, 0);
            emit NoFeed(marketId, m.assetKey);
            return 0;
        }

        uint8 size = feedCommitteeSize;
        uint256 deposit = _quoteStage1();
        // Both stages are checked here, not just this one. Paying for a price the brain cannot
        // then act on is the one way this contract can burn float and produce nothing.
        uint256 total = deposit + _quoteStage2();
        if (address(this).balance < total) revert Underfunded(total, address(this).balance);

        bytes memory payload;
        uint256 agentId;
        if (f.kind == FeedKind.PriceOracle) {
            // One symbol per request: the brain prices one window at a time, and asking for pairs
            // it will not read would be paying the committee to carry them.
            string[] memory symbols = new string[](1);
            symbols[0] = f.symbol;
            payload = abi.encodeWithSelector(IPriceOracleAgent.getPrices.selector, symbols, f.decimals);
            agentId = oracleAgentId;
        } else {
            payload = abi.encodeWithSelector(IJsonApiAgent.fetchUint.selector, f.url, f.selector, f.decimals);
            agentId = feedAgentId;
        }

        requestId = PLATFORM.createAdvancedRequest{value: deposit}(
            agentId,
            address(this),
            IAgentPriceConsumer.handlePrice.selector,
            payload,
            size,
            feedThreshold,
            // Threshold, not Majority: every validator fetches the price a moment apart and gets a
            // slightly different number, so requiring byte-identical results would fail almost
            // every request. The platform delivers all of them and the median below is the
            // consensus this contract actually wants.
            IAgentRequester.ConsensusType.Threshold,
            REQUEST_TIMEOUT
        );

        _storePending(requestId, marketId, m, pBookBps, recentOutcomes, f);
        emit PriceRequested(marketId, requestId, m.assetKey, deposit);
    }

    /// @notice Receives the committee's price readings and, if the window still allows it, buys the
    /// verdict they make answerable.
    /// @dev Reached only from the platform. Every early exit here still records a verdict and still
    /// notifies the router, because a desk that was told a verdict was coming must be told when it
    /// is not. Nothing in this function reverts on a bad committee: a revert would unwind the
    /// refusal along with the bad answer and leave the desk waiting on silence.
    /// @param requestId The price request being answered.
    /// @param responses One reading per validator in the subcommittee.
    /// @param status The platform's own verdict on whether the request succeeded at all.
    function handlePrice(
        uint256 requestId,
        IAgentRequester.Response[] memory responses,
        IAgentRequester.ResponseStatus status,
        IAgentRequester.Request memory
    ) external override {
        if (msg.sender != address(PLATFORM)) revert NotPlatform();

        Pending memory p = _pendingPrice[requestId];
        if (p.marketId == bytes32(0)) revert UnknownRequest(requestId);
        // Answered once. A replayed callback must not buy a second inference on the same window.
        delete _pendingPrice[requestId];

        feedLatencyEma = _observe(1, feedLatencyEma, p.requestedAt);

        PriceTally memory t;
        if (status == IAgentRequester.ResponseStatus.Success) {
            t = _tallyPrices(responses, p);
        } else {
            t.prices = new uint256[](0);
        }
        emit PriceReceived(p.marketId, requestId, t.median, t.used, t.prices);
        if (t.stale != 0 || t.thin != 0) emit PriceGuardRejected(p.marketId, requestId, t.stale, t.thin);

        if (t.median == 0) {
            _refuse(p.marketId, requestId);
            emit PriceUnusable(p.marketId, requestId);
            return;
        }

        // Only the second stage is still ahead, so only the second stage's latency is charged
        // against what remains. Re-checking here rather than trusting the check at request time is
        // what saves the inference deposit: the price fetch may have taken the whole budget.
        uint256 needed = uint256(verdictLatencyEma) * 2 + 30;
        uint256 secondsLeft = p.expiry > block.timestamp ? p.expiry - block.timestamp : 0;
        if (secondsLeft < needed) {
            _refuse(p.marketId, requestId);
            emit LateAbort(p.marketId, secondsLeft, needed);
            return;
        }

        uint256 deposit = _quoteStage2();
        if (address(this).balance < deposit) {
            // An empty float is an operator problem, but reverting here would make it a desk
            // problem: the callback would fail, the platform would record it as a failed delivery,
            // and nobody would ever be told why the verdict never came.
            _refuse(p.marketId, requestId);
            emit StageTwoUnfunded(p.marketId, deposit, address(this).balance);
            return;
        }

        _requestInference(p, t.median, deposit);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Stage 2 — verdict
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Receives the committee's answers and turns them into a verdict.
    /// @dev Reached only from the platform. The verdict is stored before the router is called, and
    /// the router call is caught, so neither a hostile committee nor a broken router can leave the
    /// protocol without a recorded answer.
    /// @param requestId The platform request being answered.
    /// @param responses One entry per validator in the subcommittee.
    /// @param status The platform's own verdict on whether the request succeeded at all.
    function handleResponse(
        uint256 requestId,
        IAgentRequester.Response[] memory responses,
        IAgentRequester.ResponseStatus status,
        IAgentRequester.Request memory
    ) external override {
        if (msg.sender != address(PLATFORM)) revert NotPlatform();

        PendingVerdict memory pv = _pendingVerdict[requestId];
        bytes32 marketId = pv.marketId;
        if (marketId == bytes32(0)) revert UnknownRequest(requestId);
        // Answered once. A replayed callback must not overwrite a verdict a desk has already traded on.
        delete _pendingVerdict[requestId];

        verdictLatencyEma = _observe(2, verdictLatencyEma, pv.requestedAt);

        int256[] memory scores;
        int256 median;
        uint8 responded;
        uint8 agreed;
        if (status == IAgentRequester.ResponseStatus.Success) {
            (scores, median, responded, agreed) = _tally(responses);
        } else {
            // Failed or timed out. Whatever the individual entries say, the platform did not reach
            // consensus, so there is nothing here a desk is entitled to trade on.
            scores = new int256[](0);
        }

        // A late answer is not a wrong answer. It is recorded in full, with its scores, because it
        // is what calibrates the latency average that stops the next one being late — but it is
        // never marked tradeable, because the window it describes has already settled.
        bool late = block.timestamp > pv.expiry;
        if (late) emit VerdictTooLate(marketId, pv.expiry, block.timestamp);

        LucidTypes.Verdict memory v = LucidTypes.Verdict({
            probUpBps: uint16(uint256(median)) * 100,
            responded: responded,
            agreed: agreed,
            ok: !late && responded >= committeeThreshold,
            requestId: requestId
        });
        _verdicts[marketId] = v;

        emit VerdictReceived(marketId, requestId, v.probUpBps, responded, agreed, v.ok, scores);
        _notifyRouter(marketId, requestId, v);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner controls
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Replace the committee's standing instruction.
    /// @param system The new system prompt.
    function setPrompt(string calldata system) external onlyOwner {
        systemPrompt = system;
        emit PromptUpdated(system);
    }

    /// @notice Resize the verdict committee and the agreement it must reach.
    /// @param size How many validators to ask.
    /// @param threshold How many usable answers make a verdict actionable.
    function setCommittee(uint8 size, uint8 threshold) external onlyOwner {
        if (size == 0 || threshold == 0 || threshold > size) revert BadCommittee(size, threshold);
        committeeSize = size;
        committeeThreshold = threshold;
        emit CommitteeUpdated(size, threshold);
    }

    /// @notice Resize the price committee.
    /// @dev Sized separately from the verdict committee because the two answer different questions.
    /// A price is cheap and benefits from more readings to take a median over; an inference costs
    /// more than twice as much per validator.
    /// @param size How many validators fetch the price.
    /// @param threshold How many must answer before the platform finalises the request.
    function setFeedCommittee(uint8 size, uint8 threshold) external onlyOwner {
        if (size == 0 || threshold == 0 || threshold > size) revert BadCommittee(size, threshold);
        feedCommitteeSize = size;
        feedThreshold = threshold;
        emit FeedCommitteeUpdated(size, threshold);
    }

    /// @notice Point one asset at a price source, and choose which agent reads it.
    /// @dev Both halves of the feed are written together, so the fallback stays armed: switching an
    /// asset from `PriceOracle` to `JsonApi` is then a repeat of this call with a different kind
    /// rather than an endpoint chosen under pressure. The JSON endpoint is fetched by the validator
    /// set, not by this contract, so it must answer a plain unauthenticated GET with JSON. See
    /// `FeedKind` for why the undocumented agent is the default, and `Feed` for why any of this is
    /// repointable rather than fixed.
    /// @param assetKey The venue's asset hash, as in `LucidTypes.ASSET_BTC`.
    /// @param kind Which agent stage one asks. `PriceOracle` needs `symbol`; `JsonApi` needs `url`
    /// and `selector`.
    /// @param symbol The Price Oracle pair, in the agent's own `BASE/QUOTE` form, e.g. `BTC/USDT`.
    /// @param url The endpoint the JSON API agent fetches.
    /// @param selector Dot-notation path to the price inside the response, e.g. `data.amount`.
    /// @param decimals Fixed-point scale the agent should return the value in.
    function setFeed(
        bytes32 assetKey,
        FeedKind kind,
        string calldata symbol,
        string calldata url,
        string calldata selector,
        uint8 decimals
    ) external onlyOwner {
        _setFeed(assetKey, kind, symbol, url, selector, decimals);
    }

    /// @notice Point the price stage at a different JSON API agent.
    /// @dev Somnia calls the agent platform a prototype and does not guarantee ids across releases.
    /// A wrong id costs a deposit and a timeout, not a redeploy.
    /// @param agentId The registered agent id to invoke for `JsonApi` feeds.
    function setFeedAgent(uint256 agentId) external onlyOwner {
        feedAgentId = agentId;
        emit FeedAgentUpdated(agentId);
    }

    /// @notice Point the price stage at a different Price Oracle agent.
    /// @dev Separate from `setFeedAgent` because the two agents answer in different shapes, and one
    /// setter for both would let an operator repoint a `PriceOracle` feed at the JSON agent with a
    /// single mistyped id. The registry lists this agent on Shannon and not on mainnet, so a
    /// mainnet deployment is expected to arrive here — or at `setFeed` with `JsonApi`.
    /// @param agentId The registered agent id to invoke for `PriceOracle` feeds.
    function setOracleAgent(uint256 agentId) external onlyOwner {
        oracleAgentId = agentId;
        emit OracleAgentUpdated(agentId);
    }

    /// @notice Tune what counts as a usable Price Oracle reading.
    /// @dev Read live rather than snapshotted onto the request, unlike the feed kind: the kind
    /// decides how bytes are *interpreted* and must match the request that produced them, while
    /// these two decide what this protocol is willing to *trade on*, and tightening them should
    /// take effect on the answer already in flight.
    /// @param maxAgeMillis How old a median may be, in milliseconds. Zero would admit anything.
    /// @param minSources_ How many exchanges it must rest on. Zero would admit a reading with none.
    function setFeedGuards(uint64 maxAgeMillis, uint8 minSources_) external onlyOwner {
        if (maxAgeMillis == 0 || minSources_ == 0) revert BadFeedGuard(maxAgeMillis, minSources_);
        maxFeedAgeMillis = maxAgeMillis;
        minSources = minSources_;
        emit FeedGuardsUpdated(maxAgeMillis, minSources_);
    }

    /// @notice Point the brain at the router that owns desk fan-out.
    /// @param router_ The router address, or the zero address to detach.
    function setRouter(address router_) external onlyOwner {
        router = router_;
        emit RouterUpdated(router_);
    }

    /// @notice Recover the committee float this contract holds.
    /// @dev One verdict costs both stages at the current committee sizes, and on testnet that float
    /// is genuinely scarce — a brain that can only be funded is a brain whose float is destroyed the
    /// moment the prompt is retired or the deployment is replaced. Nothing here is anybody else's
    /// money: the platform takes its deposit at request time, so whatever is left is the operator's.
    /// @param to Recipient of the swept float.
    /// @param amount How much to send, at most the current balance.
    function sweep(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = address(this).balance;
        if (amount > balance) revert Underfunded(amount, balance);

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SweepFailed();
        emit Swept(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev deposit = platform floor for this committee size + the per-validator reward.
    function _quoteStage1() internal view returns (uint256) {
        uint256 size = feedCommitteeSize;
        return PLATFORM.getAdvancedRequestDeposit(size) + FEED_PER_AGENT_COST * size;
    }

    function _quoteStage2() internal view returns (uint256) {
        uint256 size = committeeSize;
        return PLATFORM.getAdvancedRequestDeposit(size) + LLM_PER_AGENT_COST * size;
    }

    function _setFeed(
        bytes32 assetKey,
        FeedKind kind,
        string memory symbol,
        string memory url,
        string memory selector,
        uint8 decimals
    ) internal {
        // An eighteen-decimal ceiling keeps the rescale below from ever overflowing.
        if (decimals > 18) revert BadFeed();
        // Each kind is validated on the field it is fetched by, and only that field, because the
        // other half is an armed fallback rather than a requirement. A missing field is how an
        // unconfigured asset is recognised, so it cannot also be a valid setting.
        if (kind == FeedKind.PriceOracle) {
            if (bytes(symbol).length == 0) revert BadFeed();
        } else if (bytes(url).length == 0 || bytes(selector).length == 0) {
            revert BadFeed();
        }

        _feeds[assetKey] = Feed({kind: kind, symbol: symbol, url: url, selector: selector, decimals: decimals});
        emit FeedUpdated(assetKey, kind, symbol, url, selector, decimals);
    }

    /// @dev Records the context stage two will be built from. The prompt reads three market fields
    /// and the tail of the history, so that is what is kept; carrying the whole `MarketInfo` across
    /// the callback gap would cost several more storage words per request for fields no committee
    /// ever sees.
    function _storePending(
        uint256 requestId,
        bytes32 marketId,
        LucidTypes.MarketInfo calldata m,
        uint256 pBookBps,
        uint16[] calldata recentOutcomes,
        Feed memory f
    ) internal {
        Pending storage p = _pendingPrice[requestId];
        p.marketId = marketId;
        p.assetKey = m.assetKey;
        p.strike = m.strike;
        p.expiry = m.expiry;
        p.requestedAt = uint64(block.timestamp);
        // The shape the answer will arrive in, fixed now. Reading it back off storage in the
        // callback would let a mid-flight repoint decide how a response already in flight is
        // decoded, and both wrong readings that produces look exactly like prices.
        p.feedKind = f.kind;
        p.decimals = f.decimals;
        // Clamped on the way in rather than on the way out, so the stored fact is the one the
        // committee will be shown and a bad book reading cannot widen a storage slot.
        p.pBookBps = uint32(pBookBps > LucidTypes.BPS ? LucidTypes.BPS : pBookBps);

        uint256 n = recentOutcomes.length;
        uint256 start = n > PENDING_OUTCOMES ? n - PENDING_OUTCOMES : 0;
        uint8 count;
        for (uint256 i = start; i < n; ++i) {
            p.outcomes[count++] = recentOutcomes[i];
        }
        p.outcomeCount = count;
    }

    /// @dev Fires the inference and records what `handleResponse` will need to judge it.
    function _requestInference(Pending memory p, uint256 spot, uint256 deposit) internal {
        LucidTypes.MarketInfo memory m;
        m.marketId = p.marketId;
        m.assetKey = p.assetKey;
        m.strike = p.strike;
        m.expiry = p.expiry;

        uint16[] memory recent = new uint16[](p.outcomeCount);
        for (uint256 i; i < p.outcomeCount; ++i) {
            recent[i] = p.outcomes[i];
        }

        uint8 size = committeeSize;
        uint8 threshold = committeeThreshold;

        bytes memory payload = abi.encodeWithSelector(
            ILLMInferenceAgent.inferNumber.selector,
            PromptLib.build(m, p.pBookBps, recent, block.timestamp, spot),
            systemPrompt,
            MIN_SCORE,
            MAX_SCORE,
            false
        );

        uint256 requestId = PLATFORM.createAdvancedRequest{value: deposit}(
            AGENT_ID,
            address(this),
            IAgentConsumer.handleResponse.selector,
            payload,
            size,
            threshold,
            IAgentRequester.ConsensusType.Threshold,
            REQUEST_TIMEOUT
        );

        _pendingVerdict[requestId] =
            PendingVerdict({marketId: p.marketId, expiry: p.expiry, requestedAt: uint64(block.timestamp)});
        emit VerdictRequested(p.marketId, requestId, size, threshold, deposit);
    }

    /// @dev Records an unusable verdict and tells the router about it. Every abort path in this
    /// contract runs through here, so there is exactly one definition of what a refusal looks like
    /// to a desk, and none of them can forget the notification.
    function _refuse(bytes32 marketId, uint256 requestId) internal {
        LucidTypes.Verdict memory v =
            LucidTypes.Verdict({probUpBps: 0, responded: 0, agreed: 0, ok: false, requestId: requestId});
        _verdicts[marketId] = v;
        _notifyRouter(marketId, requestId, v);
    }

    function _notifyRouter(bytes32 marketId, uint256 requestId, LucidTypes.Verdict memory v) internal {
        address r = router;
        if (r == address(0)) return;
        try ILucidRouter(r).onVerdict(marketId, v) {}
        catch {
            // The verdict is already stored, so a desk can still read it. Surfacing the failure
            // beats reverting: a revert here would roll the verdict back and lose it entirely.
            emit RouterCallFailed(marketId, requestId);
        }
    }

    /// @dev Folds one observation into a stage's moving average: `ema = (ema * 3 + observed) / 4`.
    /// The sample is capped at `MAX_SLACK` first, because a single pathological round trip — a
    /// callback delivered an hour late by a stalled runner — would otherwise poison the average and
    /// refuse every window for the next dozen requests over one bad night.
    function _observe(uint8 stage, uint64 ema, uint64 requestedAt) internal returns (uint64) {
        uint256 observed = block.timestamp > requestedAt ? block.timestamp - requestedAt : 0;
        if (observed > MAX_SLACK) observed = MAX_SLACK;

        uint64 next = uint64((uint256(ema) * 3 + observed) / 4);
        emit LatencyObserved(stage, observed, next);
        return next;
    }

    /// @dev Reduces the raw price readings to a median, normalised to the venue's hundredths scale.
    /// `used` counts the readings that survived; a zero median means none did, and the caller turns
    /// that into a refusal rather than into a guess.
    ///
    /// The kind and the scale come off the pending request, never off `_feeds`: the owner may have
    /// repointed the asset since this request went out, and decoding a `getPrices` response as a
    /// bare uint would not fail — it would produce a number.
    ///
    /// `stale` and `thin` count the readings the Price Oracle guards discarded, so the caller can
    /// say which guard fired rather than reporting a thinner median as if it were the whole thing.
    function _tallyPrices(IAgentRequester.Response[] memory responses, Pending memory p)
        internal
        view
        returns (PriceTally memory t)
    {
        uint256[] memory raw = new uint256[](responses.length);
        uint256[] memory usable = new uint256[](responses.length);
        uint256 rawCount;
        uint256 usableCount;

        // The window opened at the strike, so the strike is the only reference this contract has
        // for what a plausible price looks like right now, and it is a good one.
        uint256 low = p.strike / PRICE_SANITY_MULTIPLE;
        uint256 high = p.strike * PRICE_SANITY_MULTIPLE;

        for (uint256 i; i < responses.length; ++i) {
            if (responses[i].status != IAgentRequester.ResponseStatus.Success) continue;

            uint256 value;
            if (p.feedKind == FeedKind.PriceOracle) {
                Reading memory r = _readOracle(responses[i].result);
                if (r.isStale) ++t.stale;
                if (r.isThin) ++t.thin;
                if (!r.ok) continue;
                value = r.value;
            } else {
                // Anything shorter than a word cannot hold a uint256 and would revert the decode,
                // taking the whole callback and the router notification down with it.
                if (responses[i].result.length < 32) continue;
                value = abi.decode(responses[i].result, (uint256));
            }

            if (value > MAX_RAW_PRICE) continue;

            value = _toHundredths(value, p.decimals);
            raw[rawCount++] = value;
            if (value == 0 || value < low || value > high) continue;
            usable[usableCount++] = value;
        }

        t.prices = new uint256[](rawCount);
        for (uint256 i; i < rawCount; ++i) {
            t.prices[i] = raw[i];
        }

        if (usableCount == 0) return t;

        t.used = uint8(usableCount);
        t.median = _medianUint(usable, usableCount);
    }

    /// @dev One validator's Price Oracle response, decoded and judged.
    ///
    /// A median is only worth preferring to a single endpoint while it is still a median of
    /// something recent. Both guards are therefore hard rejections rather than warnings: a reading
    /// that fails one is discarded exactly like a zero, and if every reading is discarded the
    /// caller refuses the window through the zero-spend path instead of trading on a guess.
    ///
    /// @dev The whole reduction of one price committee. A struct rather than a tuple because the
    /// EVM's stack will not hold this many live values at once without `via_ir`, which this
    /// project does not compile with.
    /// @param prices Every reading that decoded, on the venue's scale, discarded ones included.
    /// @param median The consensus price, or zero when nothing survived.
    /// @param used How many readings the median was taken over.
    /// @param stale How many readings the age guard threw away.
    /// @param thin How many readings the source-count guard threw away.
    struct PriceTally {
        uint256[] prices;
        uint256 median;
        uint8 used;
        uint8 stale;
        uint8 thin;
    }

    /// @dev Returned as a struct rather than as four values, for the same reason as `PriceTally`.
    /// @param value The raw median, still on the feed's own scale.
    /// @param ok Whether the reading survived decoding and both guards.
    /// @param isStale Whether it was thrown away for age.
    /// @param isThin Whether it was thrown away for resting on too few exchanges.
    struct Reading {
        uint256 value;
        bool ok;
        bool isStale;
        bool isThin;
    }

    function _readOracle(bytes memory result) internal view returns (Reading memory r) {
        uint256 sources;
        uint256 lastUpdated;
        // Gas-capped, and through `this.` rather than inline, so a malformed or hostile response
        // costs a discarded reading instead of the whole callback. See `DECODE_GAS`.
        try this.decodeOracleReading{gas: DECODE_GAS}(result) returns (uint256 price, uint8 n, uint64 updated) {
            (r.value, sources, lastUpdated) = (price, n, updated);
        } catch {
            return Reading({value: 0, ok: false, isStale: false, isThin: false});
        }

        if (sources < minSources) return Reading({value: 0, ok: false, isStale: false, isThin: true});

        // The agent reports milliseconds. A reading stamped in the future is a clock the chain
        // cannot arbitrate, so it is treated as fresh rather than as evidence of anything — the
        // guard exists to catch a feed that stopped, not to referee two clocks.
        uint256 nowMillis = block.timestamp * 1000;
        if (nowMillis > lastUpdated && nowMillis - lastUpdated > maxFeedAgeMillis) {
            return Reading({value: 0, ok: false, isStale: true, isThin: false});
        }

        r.ok = true;
    }

    /// @dev Whether a feed carries the one field its own kind is actually fetched by. An asset
    /// whose feed does not is refused rather than priced blind.
    function _configured(Feed memory f) internal pure returns (bool) {
        return f.kind == FeedKind.PriceOracle ? bytes(f.symbol).length != 0 : bytes(f.url).length != 0;
    }

    /// @dev Puts a fetched price on the venue's scale. The strike arrives in hundredths of a dollar
    /// and the feed is configured with whatever scale its endpoint is asked for, so comparing the
    /// two without this would compute a distance off by orders of magnitude and hand the committee
    /// a market that has apparently moved 99%.
    function _toHundredths(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals > PRICE_SCALE_DECIMALS) return value / (10 ** (decimals - PRICE_SCALE_DECIMALS));
        if (decimals < PRICE_SCALE_DECIMALS) return value * (10 ** (PRICE_SCALE_DECIMALS - decimals));
        return value;
    }

    /// @dev Reduces the raw responses to a median score plus the counts that describe how it was
    /// reached. `agreed` counts the usable answers that fell on the same side of the coin-flip line
    /// as the median, which is the number a reader wants when asking how split the committee was.
    function _tally(IAgentRequester.Response[] memory responses)
        internal
        pure
        returns (int256[] memory scores, int256 median, uint8 responded, uint8 agreed)
    {
        uint256 n = responses.length;
        int256[] memory raw = new int256[](n);
        int256[] memory usable = new int256[](n);
        uint256 rawCount;
        uint256 usableCount;

        for (uint256 i; i < n; ++i) {
            if (responses[i].status != IAgentRequester.ResponseStatus.Success) continue;
            // Anything shorter than a word cannot hold an int256 and would revert the decode,
            // taking the whole callback and the router notification down with it.
            if (responses[i].result.length < 32) continue;

            int256 score = abi.decode(responses[i].result, (int256));
            raw[rawCount++] = score;
            // Out of range is not a strong opinion, it is a broken answer. Keeping it would let one
            // validator drag the committee, which is the exact failure the median exists to stop.
            if (score < MIN_SCORE || score > MAX_SCORE) continue;
            usable[usableCount++] = score;
        }

        scores = new int256[](rawCount);
        for (uint256 i; i < rawCount; ++i) {
            scores[i] = raw[i];
        }

        if (usableCount == 0) return (scores, 0, 0, 0);

        responded = uint8(usableCount);
        median = _median(usable, usableCount);

        bool up = median >= COIN_FLIP;
        for (uint256 i; i < usableCount; ++i) {
            if ((usable[i] >= COIN_FLIP) == up) ++agreed;
        }
    }

    /// @dev Median, not mean: one validator answering 0 or 100 moves an average by a third of the
    /// committee's weight but cannot move the middle at all. With an even count the two central
    /// answers are averaged, which keeps the result an integer score in the same 0..100 domain the
    /// committee answers in. Sorts `a[0..n)` in place; n is the committee size, so it is tiny.
    function _median(int256[] memory a, uint256 n) internal pure returns (int256) {
        for (uint256 i = 1; i < n; ++i) {
            int256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = key;
        }
        if (n % 2 == 1) return a[n / 2];
        return (a[n / 2 - 1] + a[n / 2]) / 2;
    }

    /// @dev The same middle-of-the-committee reduction over prices. Separate from `_median` only
    /// because a price cannot be negative and a score can.
    function _medianUint(uint256[] memory a, uint256 n) internal pure returns (uint256) {
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = key;
        }
        if (n % 2 == 1) return a[n / 2];
        return (a[n / 2 - 1] + a[n / 2]) / 2;
    }
}
