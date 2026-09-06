// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../types/LucidTypes.sol";

/// @title PolicyLib
/// @notice The code-enforced trading mandate: a pure, total function from
/// (policy, desk state, market, verdict, money) to a single reason the desk may or may not trade.
/// @dev Two properties matter more than anything else here and are enforced by the invariant suite.
/// First, nothing in this library reverts, ever. The desks are driven by one shared reactivity
/// handler, so a revert raised for one desk would strand every other desk in the same fan-out.
/// Second, the checks run in a fixed order and the first failure wins, so the refusal a desk emits
/// is reproducible and means the same thing in every log line the UI renders.
library PolicyLib {
    /// @dev The only window lengths the venue lists. `allowedCadences` is a bitmask over these,
    /// in this order. Solidity has no constant arrays, so the mapping lives in `cadenceBit`.
    uint32 internal constant CADENCE_1M = 60;
    uint32 internal constant CADENCE_5M = 300;
    uint32 internal constant CADENCE_15M = 900;
    uint32 internal constant CADENCE_1H = 3600;

    /// @notice The cheap pre-filter, run before the desk spends anything on an AI verdict.
    /// @dev Applies every gate check that needs neither the verdict nor a stake, plus the two
    /// spend limits that can already be evaluated. A desk with no headroom left must not pay a
    /// committee deposit to be told so afterwards. Callers that persist state should call
    /// `rollDay` first, otherwise yesterday spend still counts against today budget.
    /// @param p The owner mandate.
    /// @param s The desk risk accounting.
    /// @param m The candidate market window.
    /// @param nowTs Current block timestamp, in seconds.
    /// @return The first failing check, or `Refusal.None` when the market is worth a verdict.
    function preCheck(
        LucidTypes.Policy memory p,
        LucidTypes.DeskState memory s,
        LucidTypes.MarketInfo memory m,
        uint256 nowTs
    ) internal pure returns (LucidTypes.Refusal) {
        LucidTypes.Refusal r = _staticChecks(p, s, m, nowTs);
        if (r != LucidTypes.Refusal.None) return r;

        if (p.maxStakePerWindow == 0) return LucidTypes.Refusal.CapExceeded;
        if (s.spentToday >= p.dailyBudget) return LucidTypes.Refusal.DailyBudgetExceeded;

        return LucidTypes.Refusal.None;
    }

    /// @notice The full gate, run once the committee verdict is in and a stake has been sized.
    /// @dev Order is part of the contract with the outside world: mandate, then market, then risk,
    /// then the AI answer, then the evidence that answer is judged against, then the money. Risk
    /// state is read before the verdict so a halted desk reports why it is halted rather than
    /// blaming the committee. `NoBook` was appended to the enum but inserted into this sequence
    /// just before `LowEdge`, because it is the precondition of that check rather than a new one.
    /// Both of those checks weigh a committee against a market price, so both belong to the
    /// strategy that takes a side on that comparison; every other check here applies to any desk.
    /// @param p The owner mandate.
    /// @param s The desk risk accounting.
    /// @param m The market window being traded.
    /// @param v The committee verdict.
    /// @param pBookBps Book-implied UP probability, on the same 0..10000 scale as the verdict.
    /// @param bookObserved Whether `pBookBps` was actually read off the venue's book. False means
    /// no side of the book had a level, so there is no market price at all — not a price of zero.
    /// @param stake Intended notional, in raw 6dp collateral units.
    /// @param equity Current desk equity, in raw 6dp collateral units.
    /// @param nowTs Current block timestamp, in seconds.
    /// @return The first failing check, or `Refusal.None` when the trade may proceed.
    function gate(
        LucidTypes.Policy memory p,
        LucidTypes.DeskState memory s,
        LucidTypes.MarketInfo memory m,
        LucidTypes.Verdict memory v,
        uint256 pBookBps,
        bool bookObserved,
        uint256 stake,
        uint256 equity,
        uint256 nowTs
    ) internal pure returns (LucidTypes.Refusal) {
        LucidTypes.Refusal r = _staticChecks(p, s, m, nowTs);
        if (r != LucidTypes.Refusal.None) return r;

        if (equity < _drawdownFloor(p, s)) return LucidTypes.Refusal.RiskHalt;

        if (!v.ok) return LucidTypes.Refusal.AiUnavailable;
        if (v.probUpBps > LucidTypes.BPS) return LucidTypes.Refusal.AiMalformed;

        // Sits immediately before the edge test because it is the same question asked one step
        // earlier: an edge is a distance between the committee's probability and the market's, and
        // with no market price there is no distance to measure. A default standing in for the book
        // would hand `AiEdge` a large edge against a number nobody quoted, which is a trade opened
        // on an invented disagreement.
        //
        // `Maker` is deliberately exempt. It mints a complete set and rests both legs, which needs
        // no counterparty and no quote to price against — an empty book is the case it exists for,
        // and refusing it here would delete the one strategy that works on this venue's usual state.
        if (!bookObserved && p.strategy == uint8(LucidTypes.Strategy.AiEdge)) {
            return LucidTypes.Refusal.NoBook;
        }

        // `minEdgeBps` asks one question: is the committee far enough from the market to be worth
        // taking a side? That is the whole of what `AiEdge` is — it crosses the spread because it
        // believes the book is wrong, and a disagreement too small to pay for the crossing is not
        // a trade worth opening.
        //
        // A `Maker` is not answering that question. It quotes both sides and earns the spread it
        // charges, so it has no direction and is never betting on the committee beating the market;
        // its profit is the gap between its own two legs, which the committee's confidence does not
        // widen or narrow. Held to the edge test it is punished for the case it is best at: an
        // undecided committee sits on top of the market, measures near-zero edge and is vetoed at
        // 50%, precisely when standing on both sides earns the most. And on the empty book a maker
        // exists to quote there is no market probability to be distant from at all, so the
        // placeholder the router passes would decide the window on a number nobody quoted.
        if (p.strategy != uint8(LucidTypes.Strategy.Maker)) {
            uint256 pAi = v.probUpBps;
            uint256 edge = pAi > pBookBps ? pAi - pBookBps : pBookBps - pAi;
            if (edge < p.minEdgeBps) return LucidTypes.Refusal.LowEdge;
        }

        if (stake > p.maxStakePerWindow) return LucidTypes.Refusal.CapExceeded;
        // Safe to widen and add: the cap check above bounds `stake` by a uint64.
        if (uint256(s.spentToday) + stake > p.dailyBudget) return LucidTypes.Refusal.DailyBudgetExceeded;

        return LucidTypes.Refusal.None;
    }

    /// @notice The largest stake the mandate would accept right now.
    /// @dev Returns zero whenever no positive stake could clear `gate` on this policy and state,
    /// which is what makes it safe to use as a sizing input rather than a display value.
    /// @param p The owner mandate.
    /// @param s The desk risk accounting.
    /// @return Raw 6dp collateral units, zero when the desk cannot open a position.
    function maxStake(LucidTypes.Policy memory p, LucidTypes.DeskState memory s)
        internal
        pure
        returns (uint64)
    {
        if (!p.armed) return 0;
        if (s.openMarkets >= p.maxOpenMarkets) return 0;
        if (s.consecutiveLosses >= p.maxConsecutiveLosses) return 0;
        // A mid-day budget cut can leave a desk overspent, so this subtraction is guarded.
        if (s.spentToday >= p.dailyBudget) return 0;

        uint64 remaining = p.dailyBudget - s.spentToday;
        return p.maxStakePerWindow < remaining ? p.maxStakePerWindow : remaining;
    }

    /// @notice Maps an asset key to its bit in `Policy.allowedAssets`.
    /// @param assetKey `keccak256(bytes(symbol))` as decoded from the venue log.
    /// @return 1 for BTC, 2 for ETH, 0 for anything the desk has no mandate to trade.
    function assetBit(bytes32 assetKey) internal pure returns (uint32) {
        if (assetKey == LucidTypes.ASSET_BTC) return 1;
        if (assetKey == LucidTypes.ASSET_ETH) return 2;
        return 0;
    }

    /// @notice Maps a window length to its bit in `Policy.allowedCadences`.
    /// @param intervalSec Window length in seconds, as `expiry - tradingStart`.
    /// @return 1, 2, 4 or 8 for the four listed cadences, 0 for anything else.
    function cadenceBit(uint32 intervalSec) internal pure returns (uint32) {
        if (intervalSec == CADENCE_1M) return 1;
        if (intervalSec == CADENCE_5M) return 2;
        if (intervalSec == CADENCE_15M) return 4;
        if (intervalSec == CADENCE_1H) return 8;
        return 0;
    }

    /// @notice Advances the daily spend accounting to the UTC day containing `nowTs`.
    /// @dev Returns a copy so callers stay in control of when the new state is persisted; the
    /// gate itself never rolls the day, or a stale read would silently reopen a spent budget.
    /// @param s The desk risk accounting.
    /// @param nowTs Current block timestamp, in seconds.
    /// @return The same state with `dayKey` set to today and `spentToday` cleared if the day changed.
    function rollDay(LucidTypes.DeskState memory s, uint256 nowTs)
        internal
        pure
        returns (LucidTypes.DeskState memory)
    {
        // casting to 'uint64' is safe because a day index derived from a block timestamp needs
        // about 20 bits; a value that overflowed would already be ~500 billion years from now.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 today = uint64(nowTs / 1 days);
        if (today != s.dayKey) {
            s.dayKey = today;
            s.spentToday = 0;
        }
        return s;
    }

    // -- internals -------------------------------------------------------------

    /// @dev The checks shared by `preCheck` and `gate`, in the order both must report them.
    function _staticChecks(
        LucidTypes.Policy memory p,
        LucidTypes.DeskState memory s,
        LucidTypes.MarketInfo memory m,
        uint256 nowTs
    ) private pure returns (LucidTypes.Refusal) {
        if (!p.armed) return LucidTypes.Refusal.NotArmed;

        uint32 aBit = assetBit(m.assetKey);
        if (aBit == 0 || p.allowedAssets & aBit == 0) return LucidTypes.Refusal.AssetNotAllowed;

        uint32 cBit = cadenceBit(m.intervalSec);
        if (cBit == 0 || p.allowedCadences & cBit == 0) return LucidTypes.Refusal.CadenceNotAllowed;

        if (_tooLate(m.expiry, nowTs)) return LucidTypes.Refusal.WindowTooShort;

        if (s.openMarkets >= p.maxOpenMarkets) return LucidTypes.Refusal.MaxOpenReached;
        if (s.consecutiveLosses >= p.maxConsecutiveLosses) return LucidTypes.Refusal.RiskHalt;

        return LucidTypes.Refusal.None;
    }

    /// @dev `expiry < nowTs + MIN_WINDOW_SLACK`, rearranged so an absurd `nowTs` cannot overflow
    /// the addition. `expiry` is a uint64, so the left side is always in range.
    function _tooLate(uint64 expiry, uint256 nowTs) private pure returns (bool) {
        if (expiry < LucidTypes.MIN_WINDOW_SLACK) return true;
        return uint256(expiry - LucidTypes.MIN_WINDOW_SLACK) < nowTs;
    }

    /// @dev Equity below `hwm * (1 - maxDrawdownBps)` halts the desk. A tolerance of 100% or more
    /// is read as "never halt" rather than allowed to underflow the multiplier.
    function _drawdownFloor(LucidTypes.Policy memory p, LucidTypes.DeskState memory s)
        private
        pure
        returns (uint256)
    {
        if (p.maxDrawdownBps >= LucidTypes.BPS) return 0;
        return uint256(s.highWaterMark) * (LucidTypes.BPS - p.maxDrawdownBps) / LucidTypes.BPS;
    }
}
