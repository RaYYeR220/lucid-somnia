// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";
import {PolicyLib} from "../src/lib/PolicyLib.sol";
import {PolicyHarness} from "./PolicyLib.t.sol";

/// @notice Drives the gate with adversarial inputs and records every property violation it sees.
/// @dev The handler records rather than asserts, so a single campaign surfaces all the ways the
/// gate can be wrong instead of stopping at the first one. It deliberately inherits only
/// `StdUtils`: inheriting `Test` would hand the fuzzer every forge-std entry point as a target.
contract PolicyGateHandler is StdUtils {
    PolicyHarness internal immutable HARNESS;

    uint256 public gateCalls;
    uint256 public plausiblePasses;
    uint256 public cleanPasses;

    bool public sawRevert;
    bool public sawCapBreach;
    bool public sawBudgetBreach;
    bool public sawTradeWithoutHeadroom;
    bool public sawMaxStakeMismatch;
    bool public sawStaleDayKey;
    bool public sawUnclearedSpend;
    bool public sawEdgeTradeWithoutBook;
    bool public sawMakerRefusedForNoBook;
    uint256 public unobservedMakerPasses;

    constructor(PolicyHarness harness_) {
        HARNESS = harness_;
    }

    /// @notice Total nonsense: every field is unconstrained. Only the no-revert property applies.
    function fuzzChaos(uint256 seed, uint256 pBookBps, uint256 stake, uint256 equity, uint256 nowTs) external {
        seed = _decorrelate(seed);

        gateCalls++;
        // Built inline rather than into named locals: this frame has no room left for them, and
        // nothing here needs to look at the inputs again once the gate has answered.
        try HARNESS.gate(
            _chaosPolicy(seed),
            _chaosState(seed),
            _market(_word(seed, 20) % 4, _word(seed, 21) % 5, uint64(_word(seed, 22))),
            _verdict(uint16(_word(seed, 23)), _word(seed, 24) % 2 == 0),
            pBookBps,
            _word(seed, 26) % 2 == 0,
            stake,
            equity,
            nowTs
        ) returns (LucidTypes.Refusal) {}
        catch {
            sawRevert = true;
        }
    }

    /// @notice A desk that is already allowed to trade this market, with only the money and the
    /// risk dials left in play. This is the entry point that reaches the branch where the gate
    /// says yes, so the properties about permitted trades are not vacuous.
    /// @dev The mandate dials that merely gate access (armed, asset, cadence, window) are held
    /// open here on purpose. Left random they refuse almost every draw, and the interesting
    /// branch never runs. `fuzzChaos` is where those refusals get their coverage.
    function fuzzPlausible(uint256 seed, uint256 stake, uint256 equity, uint256 nowTs) external {
        seed = _decorrelate(seed);
        nowTs = bound(nowTs, 1_000_000_000, 2_000_000_000);
        stake = bound(stake, 0, 300e6);
        equity = bound(equity, 0, 4000e6);

        gateCalls++;
        _plausibleGate(seed, stake, equity, nowTs);
    }

    /// @dev Split out of `fuzzPlausible`, and every input built inline, because this frame has no
    /// room for named locals. The inputs are pure functions of the seed, so rebuilding two of them
    /// for `_record` costs gas and nothing else.
    function _plausibleGate(uint256 seed, uint256 stake, uint256 equity, uint256 nowTs) private {
        try HARNESS.gate(
            _plausiblePolicy(seed),
            _plausibleState(seed, nowTs),
            _market(_word(seed, 14) % 2, _word(seed, 15) % 4, _u64(nowTs + 120 + (_word(seed, 16) % 600))),
            _verdict(uint16(_word(seed, 17) % 10_001), _word(seed, 18) % 8 != 0),
            _word(seed, 19) % 10_001,
            // Half the draws present a book nobody quoted, which is the venue's usual state. The
            // other half keep the paying branch populated, so the properties stay non-vacuous.
            _word(seed, 26) % 2 == 0,
            stake,
            equity,
            nowTs
        ) returns (LucidTypes.Refusal r) {
            _record(_plausiblePolicy(seed), _plausibleState(seed, nowTs), r, stake, _word(seed, 26) % 2 == 0);
        } catch {
            sawRevert = true;
        }
    }

    /// @dev What one permitted-or-refused answer says about the properties under test.
    function _record(
        LucidTypes.Policy memory p,
        LucidTypes.DeskState memory s,
        LucidTypes.Refusal r,
        uint256 stake,
        bool bookObserved
    ) private {
        bool isMaker = p.strategy == uint8(LucidTypes.Strategy.Maker);

        // A maker needs no counterparty, so an empty book must never be the reason it stands down.
        // This is the half of the property a refusal-only check would miss.
        if (isMaker && r == LucidTypes.Refusal.NoBook) sawMakerRefusedForNoBook = true;

        if (r != LucidTypes.Refusal.None) return;
        plausiblePasses++;
        if (!bookObserved) {
            // An edge desk may never trade against a price nobody quoted.
            if (!isMaker) sawEdgeTradeWithoutBook = true;
            else unobservedMakerPasses++;
        }

        if (stake > p.maxStakePerWindow) sawCapBreach = true;
        if (uint256(s.spentToday) + stake > p.dailyBudget) sawBudgetBreach = true;
        if (stake > 0 && HARNESS.maxStake(p, s) == 0) sawTradeWithoutHeadroom = true;
    }

    /// @notice Everything except the money is already clean, so `maxStake` must be the exact
    /// boundary between a trade and a refusal.
    function fuzzCleanStake(uint64 cap, uint64 budget, uint64 spent, uint256 stake, uint256 nowTs) external {
        nowTs = bound(nowTs, 1_000_000_000, 2_000_000_000);
        stake = bound(stake, 1, type(uint64).max);

        LucidTypes.Policy memory p = _cleanPolicy(cap, budget);
        LucidTypes.DeskState memory s = _cleanState(spent, nowTs);
        LucidTypes.MarketInfo memory m = _market(0, 0, _u64(nowTs + 300));
        LucidTypes.Verdict memory v = _verdict(5000, true);

        gateCalls++;
        // The book is quoted here on purpose: this entry point exists to pin `maxStake` as the
        // exact boundary between a trade and a refusal, and an unobserved book would move that
        // boundary for reasons that have nothing to do with the money.
        try HARNESS.gate(p, s, m, v, 5000, true, stake, 0, nowTs) returns (LucidTypes.Refusal r) {
            bool traded = r == LucidTypes.Refusal.None;
            if (traded) cleanPasses++;
            if (traded != (stake <= HARNESS.maxStake(p, s))) sawMaxStakeMismatch = true;
            if (traded && stake > p.maxStakePerWindow) sawCapBreach = true;
            if (traded && uint256(s.spentToday) + stake > p.dailyBudget) sawBudgetBreach = true;
            if (traded && HARNESS.maxStake(p, s) == 0) sawTradeWithoutHeadroom = true;
        } catch {
            sawRevert = true;
        }
    }

    /// @notice A maker on a book nobody quoted, with only the money left in play.
    ///
    /// This is the branch the `NoBook` refusal must never reach, and it is driven here directly
    /// rather than left to a one-in-four draw inside `fuzzPlausible`. An exemption that no campaign
    /// ever exercises proves exactly as little as a missing one, and a guard that depends on the
    /// generator getting lucky reports the generator rather than the code.
    function fuzzMakerNoBook(uint64 cap, uint64 budget, uint64 spent, uint256 stake, uint256 nowTs)
        external
    {
        nowTs = bound(nowTs, 1_000_000_000, 2_000_000_000);
        stake = bound(stake, 1, type(uint64).max);

        gateCalls++;
        // Built inline for the same reason as `fuzzChaos`: the frame has no room for named locals.
        try HARNESS.gate(
            _cleanMakerPolicy(cap, budget),
            _cleanState(spent, nowTs),
            _market(0, 0, _u64(nowTs + 300)),
            _verdict(5000, true),
            0,
            false,
            stake,
            0,
            nowTs
        ) returns (LucidTypes.Refusal r) {
            if (r == LucidTypes.Refusal.NoBook) sawMakerRefusedForNoBook = true;
            if (r != LucidTypes.Refusal.None) return;

            unobservedMakerPasses++;
            if (stake > cap) sawCapBreach = true;
            if (uint256(spent) + stake > budget) sawBudgetBreach = true;
        } catch {
            sawRevert = true;
        }
    }

    function fuzzRollDay(uint64 dayKey, uint64 spentToday, uint256 nowTs) external {
        LucidTypes.DeskState memory s = _cleanState(spentToday, 0);
        s.dayKey = dayKey;

        try HARNESS.rollDay(s, nowTs) returns (LucidTypes.DeskState memory rolled) {
            uint64 today = _u64(nowTs / 1 days);
            if (rolled.dayKey != today) sawStaleDayKey = true;
            if (today != dayKey && rolled.spentToday != 0) sawUnclearedSpend = true;
            if (today == dayKey && rolled.spentToday != spentToday) sawUnclearedSpend = true;
        } catch {
            sawRevert = true;
        }
    }

    // -- input construction ----------------------------------------------------

    /// @dev One independent word per field: bit-slicing a single seed correlates the fields and
    /// leaves whole corners of the input space unreachable.
    function _word(uint256 seed, uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, index)));
    }

    /// @dev Narrowing helper. Every timestamp this handler builds is bounded far inside uint64,
    /// and the one caller that passes an unbounded value is deliberately mirroring the same
    /// truncation `rollDay` performs, so its result has to agree bit for bit.
    function _u64(uint256 value) private pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }

    /// @dev The fuzzer draws arguments from a dictionary of interesting values, so a raw seed
    /// repeats a handful of words and rebuilds the same handful of desks all campaign. Folding
    /// the call counter in makes consecutive draws independent again.
    function _decorrelate(uint256 seed) private view returns (uint256) {
        return uint256(keccak256(abi.encode(seed, gateCalls)));
    }

    function _chaosPolicy(uint256 seed) private pure returns (LucidTypes.Policy memory p) {
        p.maxStakePerWindow = uint64(_word(seed, 0));
        p.dailyBudget = uint64(_word(seed, 1));
        p.maxOpenMarkets = uint16(_word(seed, 2));
        p.maxDrawdownBps = uint16(_word(seed, 3));
        p.maxConsecutiveLosses = uint8(_word(seed, 4));
        p.minEdgeBps = uint16(_word(seed, 5));
        p.allowedAssets = uint32(_word(seed, 6));
        p.allowedCadences = uint32(_word(seed, 7));
        p.strategy = uint8(_word(seed, 8));
        p.armed = _word(seed, 9) % 2 == 0;
    }

    function _chaosState(uint256 seed) private pure returns (LucidTypes.DeskState memory s) {
        s.dayKey = uint64(_word(seed, 10));
        s.spentToday = uint64(_word(seed, 11));
        s.highWaterMark = uint64(_word(seed, 12));
        s.openMarkets = uint16(_word(seed, 13));
        s.consecutiveLosses = uint8(_word(seed, 25));
    }

    function _plausiblePolicy(uint256 seed) private pure returns (LucidTypes.Policy memory p) {
        p.maxStakePerWindow = uint64(1 + _word(seed, 0) % 400e6);
        p.dailyBudget = uint64(400e6 + _word(seed, 1) % 1600e6);
        p.maxOpenMarkets = uint16(2 + _word(seed, 2) % 6);
        p.maxDrawdownBps = uint16(_word(seed, 3) % 11_000);
        p.maxConsecutiveLosses = uint8(2 + _word(seed, 4) % 4);
        p.minEdgeBps = uint16(_word(seed, 5) % 1200);
        p.allowedAssets = 3;
        p.allowedCadences = 15;
        p.strategy = uint8(_word(seed, 8) % 2);
        p.armed = true;
    }

    function _plausibleState(uint256 seed, uint256 nowTs) private pure returns (LucidTypes.DeskState memory s) {
        s.dayKey = _u64(nowTs / 1 days);
        s.spentToday = uint64(_word(seed, 10) % 800e6);
        s.highWaterMark = uint64(_word(seed, 11) % 2000e6);
        s.openMarkets = uint16(_word(seed, 12) % 2);
        s.consecutiveLosses = uint8(_word(seed, 13) % 2);
    }

    function _cleanPolicy(uint64 cap, uint64 budget) private pure returns (LucidTypes.Policy memory p) {
        p = LucidTypes.Policy({
            maxStakePerWindow: cap,
            dailyBudget: budget,
            maxOpenMarkets: 1,
            maxDrawdownBps: 0,
            maxConsecutiveLosses: 1,
            minEdgeBps: 0,
            allowedAssets: 3,
            allowedCadences: 15,
            strategy: uint8(LucidTypes.Strategy.AiEdge),
            armed: true
        });
    }

    /// @dev The same clean mandate, run by the strategy that needs no counterparty.
    function _cleanMakerPolicy(uint64 cap, uint64 budget) private pure returns (LucidTypes.Policy memory p) {
        p = _cleanPolicy(cap, budget);
        p.strategy = uint8(LucidTypes.Strategy.Maker);
    }

    function _cleanState(uint64 spentToday, uint256 nowTs) private pure returns (LucidTypes.DeskState memory s) {
        s = LucidTypes.DeskState({
            dayKey: _u64(nowTs / 1 days),
            spentToday: spentToday,
            highWaterMark: 0,
            openMarkets: 0,
            consecutiveLosses: 0
        });
    }

    function _market(uint256 assetPick, uint256 cadencePick, uint64 expiry)
        private
        pure
        returns (LucidTypes.MarketInfo memory m)
    {
        // Two of the four draws land on a listed asset, so an unlisted one stays well represented
        // without starving every other check downstream of it.
        bytes32 assetKey = (assetPick == 0 || assetPick == 2)
            ? LucidTypes.ASSET_BTC
            : assetPick == 1 ? LucidTypes.ASSET_ETH : keccak256("SOL");

        uint32 intervalSec;
        if (cadencePick == 0) intervalSec = 60;
        else if (cadencePick == 1) intervalSec = 300;
        else if (cadencePick == 2) intervalSec = 900;
        else if (cadencePick == 3) intervalSec = 3600;
        else intervalSec = 137;

        m = LucidTypes.MarketInfo({
            marketId: keccak256(abi.encode(expiry, intervalSec)),
            market: address(0xBEEF),
            pool: address(0xCAFE),
            operatorId: 4,
            venueId: keccak256("venue"),
            yesId: 1,
            noId: 2,
            tradingStart: expiry > intervalSec ? expiry - intervalSec : 0,
            expiry: expiry,
            nonce: 1,
            strike: 100_000e6,
            assetKey: assetKey,
            intervalSec: intervalSec
        });
    }

    function _verdict(uint16 probUpBps, bool ok) private pure returns (LucidTypes.Verdict memory v) {
        v = LucidTypes.Verdict({probUpBps: probUpBps, responded: 3, agreed: 3, ok: ok, requestId: 1});
    }
}

/// @notice The properties that must hold for every input the gate will ever see on-chain.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 256
/// forge-config: default.invariant.fail-on-revert = true
contract PolicyLibInvariantTest is Test {
    PolicyGateHandler internal handler;

    function setUp() public {
        handler = new PolicyGateHandler(new PolicyHarness());
        targetContract(address(handler));
    }

    /// A revert inside a router-driven fan-out would strand every other desk in the same call,
    /// so the gate has to answer even when its inputs are garbage.
    function invariant_gateNeverReverts() public view {
        assertFalse(handler.sawRevert(), "gate reverted");
    }

    function invariant_aPermittedTradeRespectsTheWindowCap() public view {
        assertFalse(handler.sawCapBreach(), "permitted a stake above the window cap");
    }

    function invariant_aPermittedTradeRespectsTheDailyBudget() public view {
        assertFalse(handler.sawBudgetBreach(), "permitted a stake above the daily budget");
    }

    function invariant_zeroMaxStakeMeansNoTrade() public view {
        assertFalse(handler.sawTradeWithoutHeadroom(), "permitted a trade with zero headroom");
    }

    function invariant_maxStakeIsTheExactBoundary() public view {
        assertFalse(handler.sawMaxStakeMismatch(), "maxStake disagrees with the gate");
    }

    /// An edge is a distance from the market's price, so a desk that trades on edge may never be
    /// permitted to trade when there was no market price to measure against.
    function invariant_noEdgeTradeAgainstAnUnobservedBook() public view {
        assertFalse(handler.sawEdgeTradeWithoutBook(), "permitted an edge trade against a price nobody quoted");
    }

    /// The other half of the same rule, and the one that is easy to break by over-tightening it: a
    /// maker mints a complete set and rests both legs, which needs no counterparty. An empty book is
    /// precisely the state it exists for, and it must still be let through.
    function invariant_makerIsNeverRefusedForAnEmptyBook() public view {
        assertFalse(handler.sawMakerRefusedForNoBook(), "a maker was refused for having no book to quote against");
    }

    function invariant_rollDayAlwaysLandsOnToday() public view {
        assertFalse(handler.sawStaleDayKey(), "rollDay left a stale day key");
    }

    function invariant_rollDayClearsSpendExactlyOnDayChange() public view {
        assertFalse(handler.sawUnclearedSpend(), "rollDay mishandled the daily spend");
    }

    /// Guards against a vacuous campaign: the properties above say what must hold when the gate
    /// permits a trade, and they prove nothing if no run ever got a trade permitted.
    function afterInvariant() public view {
        assertGt(handler.gateCalls(), 0, "gate was never called");
        assertGt(handler.cleanPasses(), 0, "no input ever cleared the gate");
        assertGt(handler.plausiblePasses(), 0, "no mixed-policy input ever cleared the gate");
        assertGt(
            handler.unobservedMakerPasses(),
            0,
            "no maker ever cleared the gate on an empty book, so the exemption proves nothing"
        );
    }
}
