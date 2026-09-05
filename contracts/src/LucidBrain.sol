// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAgentRequester, IAgentConsumer, ILLMInferenceAgent} from "./interfaces/IAgentRequester.sol";
import {ILucidBrain, ILucidRouter} from "./interfaces/ILucid.sol";
import {LucidTypes} from "./types/LucidTypes.sol";
import {PromptLib} from "./lib/PromptLib.sol";

/// @title LucidBrain
/// @notice Asks Somnia's validator committee to score one market window, and reduces the answers
/// to a single verdict the rest of the protocol can act on.
/// @dev This is the protocol's only trust boundary with something that is not deterministic code,
/// so every path through it ends in a stored verdict and a router notification. There is no path
/// that ends in silence: a desk waiting on a verdict that never arrives would sit exposed with no
/// way to say why, which is strictly worse than a refusal.
contract LucidBrain is ILucidBrain, IAgentConsumer, Ownable {
    /// @notice The pre-deployed LLM Inference base agent every Somnia validator can run.
    uint256 public constant AGENT_ID = 12847293847561029384;

    /// @notice The platform's reward per validator, on top of its own deposit floor.
    uint256 internal constant PER_AGENT_COST = 0.07 ether;

    /// @notice Seconds the platform waits for the committee before reporting a timeout.
    /// @dev Sized against the shortest window the venue rolls (60s) plus settlement slack: a
    /// verdict that lands after expiry is useless, and the timeout is what turns it into a refusal.
    uint256 internal constant REQUEST_TIMEOUT = 300;

    /// @dev The answer domain. The agent is asked for a probability, and anything outside this
    /// range is a broken answer rather than a confident one.
    int256 internal constant MIN_SCORE = 0;
    int256 internal constant MAX_SCORE = 100;

    /// @dev The coin-flip line, used to decide which way a validator voted.
    int256 internal constant COIN_FLIP = 50;

    /// @dev The default committee instruction. It is deliberately blunt about the output format,
    /// because a validator that answers in prose produces a result this contract must discard.
    string internal constant DEFAULT_SYSTEM_PROMPT = "You price short-dated binary crypto markets. Given the facts, reply with a single integer "
        "from 0 to 100: the probability in percent that the settlement price is strictly above the "
        "strike at expiry. 50 means a coin flip. Reply with the number only, no words, no symbols.";

    /// @notice Somnia's agent platform. Verified live on Shannon at
    /// 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776.
    IAgentRequester public immutable PLATFORM;

    /// @notice The router that fans verdicts out to desks.
    address public router;

    /// @notice The committee's standing instruction.
    /// @dev Held in storage, not code, so it can be tuned by transaction. Prompt quality is the one
    /// part of this system that improves with observation, and redeploying the brain would orphan
    /// every stored verdict and force the router to be re-pointed.
    string public systemPrompt;

    /// @notice How many validators are asked.
    uint8 public committeeSize;

    /// @notice How many usable answers a verdict needs before a desk may act on it.
    uint8 public committeeThreshold;

    /// @notice Which market a pending platform request belongs to. Cleared once answered.
    mapping(uint256 requestId => bytes32 marketId) public marketOfRequest;

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
    event RouterCallFailed(bytes32 indexed marketId, uint256 indexed requestId);
    event PromptUpdated(string system);
    event CommitteeUpdated(uint8 size, uint8 threshold);
    event RouterUpdated(address router);

    /// @param owner_ The address allowed to tune the prompt, committee and router.
    /// @param platform_ Somnia's agent platform for this chain.
    constructor(address owner_, address platform_) Ownable(owner_) {
        if (platform_ == address(0)) revert ZeroPlatform();
        PLATFORM = IAgentRequester(platform_);
        systemPrompt = DEFAULT_SYSTEM_PROMPT;
        committeeSize = 3;
        committeeThreshold = 2;
    }

    /// @notice Accepts the native-currency float the committee is paid from.
    /// @dev One funded brain serves every desk, so a desk never has to hold the chain's gas token.
    receive() external payable {}

    /// @notice What one verdict costs right now, at the current committee size.
    /// @return weiNeeded The exact value the platform will take for the request.
    function quote() external view returns (uint256 weiNeeded) {
        return _quote(committeeSize);
    }

    /// @notice The last verdict recorded for a market.
    /// @param marketId The venue's market identifier.
    /// @return The verdict. A market that was never asked about reads back with ok = false, which
    /// is the same answer a desk gets when the committee failed, and is the safe default.
    function verdictOf(bytes32 marketId) external view returns (LucidTypes.Verdict memory) {
        return _verdicts[marketId];
    }

    /// @notice Ask the committee to score one market window.
    /// @dev Restricted to the router and the owner because each call spends the shared float.
    /// @param marketId The venue's market identifier, used to key the verdict when it lands.
    /// @param m The market the committee is asked about.
    /// @param pBookBps The book-implied UP probability at request time, in bps of probability.
    /// @param recentOutcomes Past window results, oldest first; any non-zero entry means UP.
    /// @return requestId The platform request this verdict will arrive under.
    function requestVerdict(
        bytes32 marketId,
        LucidTypes.MarketInfo calldata m,
        uint256 pBookBps,
        uint16[] calldata recentOutcomes
    ) external payable returns (uint256 requestId) {
        if (msg.sender != router && msg.sender != owner()) revert NotAuthorized();

        uint8 size = committeeSize;
        uint8 threshold = committeeThreshold;
        uint256 deposit = _quote(size);
        if (address(this).balance < deposit) revert Underfunded(deposit, address(this).balance);

        bytes memory payload = abi.encodeWithSelector(
            ILLMInferenceAgent.inferNumber.selector,
            PromptLib.build(m, pBookBps, recentOutcomes, block.timestamp),
            systemPrompt,
            MIN_SCORE,
            MAX_SCORE,
            false
        );

        requestId = PLATFORM.createAdvancedRequest{value: deposit}(
            AGENT_ID,
            address(this),
            IAgentConsumer.handleResponse.selector,
            payload,
            size,
            threshold,
            IAgentRequester.ConsensusType.Threshold,
            REQUEST_TIMEOUT
        );

        marketOfRequest[requestId] = marketId;
        emit VerdictRequested(marketId, requestId, size, threshold, deposit);
    }

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

        bytes32 marketId = marketOfRequest[requestId];
        if (marketId == bytes32(0)) revert UnknownRequest(requestId);
        // Answered once. A replayed callback must not overwrite a verdict a desk has already traded on.
        delete marketOfRequest[requestId];

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

        LucidTypes.Verdict memory v = LucidTypes.Verdict({
            probUpBps: uint16(uint256(median)) * 100,
            responded: responded,
            agreed: agreed,
            ok: responded >= committeeThreshold,
            requestId: requestId
        });
        _verdicts[marketId] = v;

        emit VerdictReceived(marketId, requestId, v.probUpBps, responded, agreed, v.ok, scores);

        address r = router;
        if (r == address(0)) return;
        try ILucidRouter(r).onVerdict(marketId, v) {}
        catch {
            // The verdict is already stored, so a desk can still read it. Surfacing the failure
            // beats reverting: a revert here would roll the verdict back and lose it entirely.
            emit RouterCallFailed(marketId, requestId);
        }
    }

    /// @notice Replace the committee's standing instruction.
    /// @param system The new system prompt.
    function setPrompt(string calldata system) external onlyOwner {
        systemPrompt = system;
        emit PromptUpdated(system);
    }

    /// @notice Resize the committee and the agreement it must reach.
    /// @param size How many validators to ask.
    /// @param threshold How many usable answers make a verdict actionable.
    function setCommittee(uint8 size, uint8 threshold) external onlyOwner {
        if (size == 0 || threshold == 0 || threshold > size) revert BadCommittee(size, threshold);
        committeeSize = size;
        committeeThreshold = threshold;
        emit CommitteeUpdated(size, threshold);
    }

    /// @notice Point the brain at the router that owns desk fan-out.
    /// @param router_ The router address, or the zero address to detach.
    function setRouter(address router_) external onlyOwner {
        router = router_;
        emit RouterUpdated(router_);
    }

    /// @dev deposit = platform floor for this committee size + the per-validator reward.
    function _quote(uint8 size) internal view returns (uint256) {
        return PLATFORM.getAdvancedRequestDeposit(size) + PER_AGENT_COST * size;
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
}
