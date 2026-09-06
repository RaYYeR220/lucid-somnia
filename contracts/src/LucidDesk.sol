// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILucidDesk, ILucidRouter} from "./interfaces/ILucid.sol";
import {IBinaryMarket, IBinaryModule, IBinaryPool, IERC20Faucet, IERC6909Min} from "./interfaces/IDreamDex.sol";
import {PolicyLib} from "./lib/PolicyLib.sol";
import {LucidTypes} from "./types/LucidTypes.sol";

/// @title LucidDesk
/// @notice One user's autonomous trading desk on DreamDEX Event Contracts. It holds that user's
/// collateral and outcome legs, and it trades only under the mandate its owner set once.
/// @dev Three invariants define this contract, and the suite asserts each of them directly.
///
/// It is non-custodial: only the owner can move collateral in or out, and nothing here can send
/// money anywhere except the venue and the owner.
///
/// It never reverts while the router is driving it. `onVerdict`, `onSettlement` and
/// `onLeaderTrade` run inside a single reactivity handler that fans out to every armed desk in
/// the block, so one desk raising would strand every other user's turn. Failures become a
/// `Refused` log and a return, and every venue call is wrapped.
///
/// It refuses out loud. The agent committee proposes a direction and `PolicyLib` disposes; a
/// mandate that quietly shrank an oversized order could never be observed saying no, so the cap
/// is a veto rather than a clamp and the refusal is a first-class product surface.
contract LucidDesk is ILucidDesk {
    // -- errors ----------------------------------------------------------------

    /// @notice A clone may be initialised once. A second call is an attempted takeover, and on
    /// the implementation contract itself it is always this.
    error AlreadyInitialized();
    /// @notice Only the router drives a desk, because only the router holds the subscription.
    error NotRouter();
    /// @notice Only the owner configures a desk or moves its collateral.
    error NotOwner();
    /// @notice A constructor-style argument was the zero address.
    error ZeroAddress();
    /// @notice The collateral token reported a failed transfer.
    error TransferFailed();

    // -- events ----------------------------------------------------------------

    /// @notice A window reached this desk and was evaluated.
    event Considered(bytes32 indexed marketId, uint32 intervalSec, bytes32 assetKey);
    /// @notice The committee's answer for a window, recorded before the mandate is applied.
    event VerdictReceived(bytes32 indexed marketId, uint16 probUpBps, uint16 pBookBps, uint8 responded);
    /// @notice An order actually reached the venue and the venue accepted it.
    event Executed(bytes32 indexed marketId, uint8 kind, uint256 price, uint256 quantity, uint128 orderId);
    /// @notice The desk declined to trade, and exactly why.
    event Refused(bytes32 indexed marketId, LucidTypes.Refusal reason, uint16 probUpBps, uint16 pBookBps);
    /// @notice A window closed, was redeemed, and the result was booked.
    event Settled(bytes32 indexed marketId, int256 pnl, uint256 equityAfter);
    /// @notice The owner turned the desk on or off.
    event ArmedSet(bool on);
    /// @notice The owner replaced the mandate.
    event PolicySet(LucidTypes.Policy policy);

    // -- constants -------------------------------------------------------------

    /// @dev Half-width of the maker quote, in raw collateral units: 0.02 of one contract either
    /// side of fair. Wide enough to survive a one-tick book on a venue whose spreads are usually
    /// empty, narrow enough that both legs stay inside the 0..1 price range at any sane fair.
    uint256 internal constant SPREAD = 20_000;

    /// @dev Orders die a few seconds before the window does. `expireTimestampNs` must not exceed
    /// the market expiry, and the venue's own indexer lags, so the slack is deliberate.
    uint64 internal constant EXPIRY_SLACK = 5;

    /// @dev `expireTimestampNs` is in NANOseconds. Passing seconds reverts `OrderAlreadyExpired`.
    uint64 internal constant NS_PER_SEC = 1e9;

    // -- storage ---------------------------------------------------------------

    /// @notice What this desk still holds in one window, valued at what it actually cost.
    struct Holding {
        uint128 cost;
        bool open;
    }

    address internal _owner;
    bool internal _initialized;
    /// @dev Whether the mandate has been set once since deployment. See `setPolicy`.
    bool internal _policyBootstrapped;

    address internal _router;
    address internal _brain;
    /// @dev Whoever deployed this clone, which in practice is `LucidFactory`.
    address internal _deployer;

    LucidTypes.Policy internal _policy;
    LucidTypes.DeskState internal _state;

    /// @notice Collateral currently committed to open windows, at cost.
    /// @dev Equity counts it, so opening a position does not look like a drawdown and trip the
    /// risk halt on a desk that has done nothing wrong.
    uint256 public openNotional;

    /// @notice Pools this desk has already granted its one-time allowances to.
    mapping(address => bool) public approved;

    /// @notice What this desk holds per market window.
    mapping(bytes32 => Holding) public held;

    // -- modifiers -------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != _router) revert NotRouter();
        _;
    }

    /// @dev Desks are ERC-1167 clones, so all state is set in `initialize` and the implementation
    /// contract must never be usable. Locking it here means an attacker who finds the bare
    /// implementation can neither own it nor point it at their own router.
    constructor() {
        _initialized = true;
    }

    // -- lifecycle -------------------------------------------------------------

    /// @notice Bind a fresh clone to its owner, its router and its brain. Callable once.
    /// @param owner_ The only address that may configure this desk or move its collateral.
    /// @param router_ The only address that may drive this desk.
    /// @param brain_ The agent-committee wrapper whose verdicts reach this desk via the router.
    function initialize(address owner_, address router_, address brain_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || router_ == address(0)) revert ZeroAddress();

        _initialized = true;
        _owner = owner_;
        _router = router_;
        _brain = brain_;
        _deployer = msg.sender;
    }

    /// @notice The address whose money this is.
    function owner() external view returns (address) {
        return _owner;
    }

    /// @notice The router that drives this desk.
    function router() external view returns (address) {
        return _router;
    }

    /// @notice The agent-committee wrapper behind this desk's verdicts.
    function brain() external view returns (address) {
        return _brain;
    }

    /// @notice The mandate this desk trades under.
    function policy() external view returns (LucidTypes.Policy memory) {
        return _policy;
    }

    /// @notice The risk accounting this desk enforces against that mandate.
    function state() external view returns (LucidTypes.DeskState memory) {
        return _state;
    }

    /// @notice Free collateral plus whatever is committed to open windows, at cost.
    function equity() external view returns (uint256) {
        return _equity();
    }

    // -- owner controls --------------------------------------------------------

    /// @notice Replace the mandate.
    /// @dev The deployer is allowed exactly one call, and only before any mandate exists, because
    /// a clone is deployed and configured in the same transaction before its owner can send one.
    /// Every later change is the owner's alone, and no path here can move collateral.
    /// @param p The new mandate.
    function setPolicy(LucidTypes.Policy calldata p) external {
        if (msg.sender != _owner) {
            if (msg.sender != _deployer || _policyBootstrapped) revert NotOwner();
        }
        _policyBootstrapped = true;
        _policy = p;
        emit PolicySet(p);
        _syncArmed(p.armed);
    }

    /// @dev The router iterates its own list of armed desks, so a desk that only flips its local
    /// flag is invisible to the fan-out and silently never trades. This path is best-effort only
    /// because the factory sets the opening policy before it registers the desk with the router;
    /// `arm` makes it definitive, and does so loudly.
    function _syncArmed(bool on) private {
        // The code check is not belt-and-braces: Solidity emits an `extcodesize` guard for a
        // typed external call, and that guard reverts OUTSIDE the try/catch, so `try` alone does
        // not make this safe against a router address with no code behind it.
        if (_router.code.length == 0) return;
        try ILucidRouter(_router).setDeskArmed(address(this), on) {} catch {}
    }

    /// @notice Turn the desk on or off without discarding the rest of the mandate.
    /// @param on True to let the desk trade.
    function arm(bool on) external onlyOwner {
        _policy.armed = on;
        emit ArmedSet(on);
        // Deliberately NOT best-effort. Arming is an explicit instruction, and a desk that arms
        // itself without reaching the router is registered, funded, and silently never traded —
        // the worst possible outcome to discover from a receipt that says success. It also keeps
        // gas estimation honest: an estimator that sees a swallowed revert converges on the cheap
        // failing path and hands the wallet a limit too small for the call to actually land.
        ILucidRouter(_router).setDeskArmed(address(this), on);
    }

    /// @notice Pull collateral in from the owner. Requires a prior ERC-20 approval.
    /// @param amount Raw 6-decimal collateral units.
    function deposit(uint256 amount) external onlyOwner {
        if (!IERC20Faucet(LucidTypes.COLLATERAL).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
        _raiseHighWaterMark();
    }

    /// @notice Send collateral back to the owner. Nothing else in this contract can pay them out,
    /// and nothing at all can pay anyone else.
    /// @param amount Raw 6-decimal collateral units.
    function withdraw(uint256 amount) external onlyOwner {
        if (!IERC20Faucet(LucidTypes.COLLATERAL).transfer(_owner, amount)) revert TransferFailed();

        // Taking money out is not a loss. Leaving the mark where it was would read as a drawdown
        // and halt a desk that traded perfectly well.
        uint256 eq = _equity();
        if (eq < _state.highWaterMark) _state.highWaterMark = _toU64(eq);
    }

    /// @notice Mint testnet collateral straight into the desk.
    /// @dev The Shannon faucet is callable by contracts and caps each call at 10 000 tUSDC, which
    /// is what makes a hands-off demo possible without an EOA in the loop.
    /// @param amount Raw 6-decimal collateral units, at most the faucet's per-call cap.
    function fundFromFaucet(uint256 amount) external onlyOwner {
        IERC20Faucet(LucidTypes.COLLATERAL).faucet(amount);
        _raiseHighWaterMark();
    }

    // -- router-driven surface -------------------------------------------------

    /// @notice The cheap filter the router runs before spending anything on a verdict.
    /// @dev A view, so it rolls the day on a copy: the persisted roll happens in `onVerdict`.
    /// @param m The candidate window.
    /// @return True when this desk would want a committee verdict for this window.
    function preCheck(LucidTypes.MarketInfo calldata m) external view onlyRouter returns (bool) {
        LucidTypes.DeskState memory s = PolicyLib.rollDay(_state, block.timestamp);
        // A window opens and closes on wall-clock time, so block time is the only clock this
        // desk has. A validator nudging it by seconds cannot manufacture an edge here: the
        // gate only widens or narrows the 90-second slack it already demands before expiry.
        // forge-lint: disable-next-line(block-timestamp)
        return PolicyLib.preCheck(_policy, s, m, block.timestamp) == LucidTypes.Refusal.None;
    }

    /// @notice Act on a committee verdict for one window. Never reverts.
    /// @param m The window.
    /// @param v The committee's answer.
    /// @param pBookBps The book-implied UP probability, on the verdict's 0..10000 scale.
    function onVerdict(LucidTypes.MarketInfo calldata m, LucidTypes.Verdict calldata v, uint256 pBookBps)
        external
        onlyRouter
    {
        emit Considered(m.marketId, m.intervalSec, m.assetKey);
        emit VerdictReceived(m.marketId, v.probUpBps, _bps16(pBookBps), v.responded);

        // The roll is persisted BEFORE the gate reads it. `PolicyLib` deliberately never rolls
        // the day itself, so a stale `dayKey` would charge yesterday's spending against today's
        // budget and silently halve the desk.
        LucidTypes.DeskState memory s = PolicyLib.rollDay(_state, block.timestamp);
        _state = s;

        // One balance read serves both the gate and the sizing: this runs inside a gas-metered
        // handler, and the two values must describe the same instant anyway.
        uint256 free = _free();
        uint256 equity_ = free + openNotional;
        uint256 intended = _intendedStake(equity_, _absDiff(v.probUpBps, pBookBps));

        LucidTypes.Refusal r = PolicyLib.gate(_policy, s, m, v, pBookBps, intended, equity_, block.timestamp);
        if (r != LucidTypes.Refusal.None) {
            emit Refused(m.marketId, r, v.probUpBps, _bps16(pBookBps));
            return;
        }

        uint256 stake = _min(intended, free);
        if (stake == 0) {
            emit Refused(m.marketId, LucidTypes.Refusal.InsufficientFunds, v.probUpBps, _bps16(pBookBps));
            return;
        }

        if (_policy.strategy == uint8(LucidTypes.Strategy.Maker)) {
            _make(m, stake, v.probUpBps, _bps16(pBookBps));
        } else {
            uint8 kind = v.probUpBps > pBookBps ? LucidTypes.BUY_YES : LucidTypes.BUY_NO;
            _take(m, kind, stake, v.probUpBps, _bps16(pBookBps));
        }
    }

    /// @notice Copy one trade a followed desk took, under this desk's own mandate. Never reverts.
    /// @dev A follower copies a direction, not a probability, so the synthetic verdict states the
    /// leader's side at full conviction: the edge test compares a committee to a book and has no
    /// meaning here. Every limit that protects money — the per-window cap, the daily budget, the
    /// open-window count, the loss streak, the drawdown floor — is the follower's own, which is
    /// what lets a smaller desk refuse a trade its leader took.
    /// @param m The window the leader traded.
    /// @param kind The leg the leader bought, using the venue's kind encoding.
    /// @param stake The leader's notional, already scaled by the follow ratio.
    function onLeaderTrade(LucidTypes.MarketInfo calldata m, uint8 kind, uint256 stake) external onlyRouter {
        emit Considered(m.marketId, m.intervalSec, m.assetKey);

        LucidTypes.DeskState memory s = PolicyLib.rollDay(_state, block.timestamp);
        _state = s;

        LucidTypes.Verdict memory v = LucidTypes.Verdict({
            probUpBps: kind == LucidTypes.BUY_YES ? LucidTypes.BPS : 0,
            responded: 0,
            agreed: 0,
            ok: true,
            requestId: 0
        });
        uint16 pBookBps = LucidTypes.BPS / 2;

        uint256 free = _free();
        LucidTypes.Refusal r =
            PolicyLib.gate(_policy, s, m, v, pBookBps, stake, free + openNotional, block.timestamp);
        if (r != LucidTypes.Refusal.None) {
            emit Refused(m.marketId, r, v.probUpBps, pBookBps);
            return;
        }

        uint256 sized = _min(stake, free);
        if (sized == 0) {
            emit Refused(m.marketId, LucidTypes.Refusal.InsufficientFunds, v.probUpBps, pBookBps);
            return;
        }

        _take(m, kind, sized, v.probUpBps, pBookBps);
    }

    /// @notice Close out one settled window: finalize it if nobody has, redeem what pays, and
    /// book the result. Never reverts.
    /// @param m The window that has expired.
    function onSettlement(LucidTypes.MarketInfo calldata m) external onlyRouter {
        Holding memory h = held[m.marketId];
        if (!h.open) return;

        // Finalizing is permissionless and idempotent-by-failure: somebody else getting there
        // first is the expected case on a busy venue, not an error.
        try IBinaryModule(LucidTypes.MODULE).finalizeMarket(m.marketId) {} catch {}

        uint256[] memory nums;
        try IBinaryMarket(m.market).payoutNumerators() returns (uint256[] memory n) {
            nums = n;
        } catch {
            // Not resolved yet. Leave the holding open rather than booking a loss the desk
            // never took; the position is still redeemable later.
            return;
        }
        if (nums.length < 2) return;

        // An all-zero payout vector is not a loss, it is an unresolved window. The venue has been
        // observed finalizing markets with no outcome while its oracle was not publishing — for
        // about an hour, across every market of both assets, before recovering on its own. Booking
        // that as a total loss would close a position that is still redeemable and, worse, would
        // walk the desk into its own loss-streak halt on the back of someone else's outage.
        if (nums[0] == 0 && nums[1] == 0) return;

        uint256 before = _free();
        // The winner is the argmax of the payout vector, but a VOIDED window pays both legs half,
        // so the test that matters per leg is a non-zero numerator rather than equality with the
        // argmax. A zero-payout leg is skipped: it would pay nothing, and the gas is metered
        // inside a handler shared with every other desk.
        _redeemLeg(m, 0, m.yesId, nums[0]);
        _redeemLeg(m, 1, m.noId, nums[1]);

        // Measured, never predicted: a losing redemption succeeds and pays zero, and a voided one
        // pays half, so the only honest source of truth is the collateral that actually arrived.
        // casting to 'int256' is safe because every term is a 6-decimal collateral balance,
        // some twenty orders of magnitude below the signed range.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 pnl = int256(_free()) - int256(before) - int256(uint256(h.cost));

        delete held[m.marketId];
        openNotional = openNotional > h.cost ? openNotional - h.cost : 0;
        if (_state.openMarkets != 0) _state.openMarkets -= 1;

        if (pnl < 0) {
            if (_state.consecutiveLosses != type(uint8).max) _state.consecutiveLosses += 1;
        } else {
            _state.consecutiveLosses = 0;
        }

        _raiseHighWaterMark();

        emit Settled(m.marketId, pnl, _equity());
    }

    // -- execution -------------------------------------------------------------

    /// @dev Book parameters, read once per window because the venue can change them mid-life.
    struct BookParams {
        uint256 tick;
        uint256 minQty;
        uint256 lot;
    }

    /// @dev Cross the book for `stake` worth of one leg with an IOC order, which is what the
    /// venue's own app uses. A resting limit order on a book this thin would simply never fill.
    function _take(LucidTypes.MarketInfo calldata m, uint8 kind, uint256 stake, uint16 pAi, uint16 pBook)
        private
    {
        _ensureApprovals(m.pool);

        (LucidTypes.Refusal r, uint256 price, uint256 quantity) = _sizeOrder(m.pool, kind, stake);
        if (r != LucidTypes.Refusal.None) return _refuse(m.marketId, r, pAi, pBook);

        uint256 before = _free();
        (bool placed, uint128 id) = _place(m.pool, kind, price, quantity, m.expiry, LucidTypes.ORDER_MARKET);
        if (!placed) return _refuse(m.marketId, LucidTypes.Refusal.VenueRejected, pAi, pBook);

        _book(m.marketId, _spentSince(before), stake);
        emit Executed(m.marketId, kind, price, quantity, id);
    }

    /// @dev Price and size one taker order against the live book.
    /// @dev The venue quotes the YES side for every kind, so a NO contract costs the complement of
    /// the YES price. Sizing a NO leg off the YES price directly would escrow far more than the
    /// mandate allowed, which is the one arithmetic slip that could break the cap guarantee.
    function _sizeOrder(address pool, uint8 kind, uint256 stake)
        private
        view
        returns (LucidTypes.Refusal, uint256, uint256)
    {
        (bool okParams, BookParams memory bp) = _bookParams(pool);
        if (!okParams) return (LucidTypes.Refusal.VenueRejected, 0, 0);

        (bool okPrice, uint256 price) = _crossPrice(pool, kind, bp.tick);
        if (!okPrice) return (LucidTypes.Refusal.VenueRejected, 0, 0);

        uint256 unitCost = kind == LucidTypes.BUY_YES ? price : LucidTypes.ONE - price;
        uint256 quantity = _floorTo(stake * LucidTypes.ONE / unitCost, bp.lot);
        if (quantity == 0 || quantity < bp.minQty) {
            return (LucidTypes.Refusal.InsufficientFunds, 0, 0);
        }

        return (LucidTypes.Refusal.None, price, quantity);
    }

    /// @dev Quote both sides around the committee's fair value. Minting a complete set needs no
    /// counterparty at all, which is the only way to work a book that is usually empty: the desk
    /// pays `size` collateral, receives `size` of each leg, and sells them back at a spread.
    function _make(LucidTypes.MarketInfo calldata m, uint256 stake, uint16 pAi, uint16 pBook) private {
        _ensureApprovals(m.pool);

        (bool okParams, BookParams memory bp) = _bookParams(m.pool);
        if (!okParams) return _refuse(m.marketId, LucidTypes.Refusal.VenueRejected, pAi, pBook);

        uint256 size = _floorTo(stake, bp.lot);
        if (size == 0 || size < bp.minQty) {
            return _refuse(m.marketId, LucidTypes.Refusal.InsufficientFunds, pAi, pBook);
        }

        uint256 before = _free();
        try IBinaryPool(m.pool).mintSet(address(this), address(this), size) {}
        catch {
            return _refuse(m.marketId, LucidTypes.Refusal.VenueRejected, pAi, pBook);
        }

        // The set is a position whether or not either quote rests, so it is booked immediately;
        // otherwise settlement would find legs it has no cost basis for.
        _book(m.marketId, _spentSince(before), stake);

        uint256 fair = uint256(pAi) * LucidTypes.ONE / LucidTypes.BPS;
        uint256 ask = _clampPrice(_ceilTo(fair + SPREAD, bp.tick), bp.tick);
        // The NO quote is `(ONE - fair) + SPREAD` in NO terms; the venue wants the YES side of it.
        uint256 bid = _clampPrice(_ceilTo(fair > SPREAD ? fair - SPREAD : 0, bp.tick), bp.tick);

        // POST_ONLY reverts `PostOnlyWouldCross` on the venue, so a leg that cannot rest must not
        // take the other leg down with it: half a quote still earns.
        _rest(m, LucidTypes.SELL_YES, ask, size, pAi, pBook);
        _rest(m, LucidTypes.SELL_NO, bid, size, pAi, pBook);
    }

    /// @dev One resting maker leg, reported honestly whichever way it goes.
    function _rest(
        LucidTypes.MarketInfo calldata m,
        uint8 kind,
        uint256 price,
        uint256 quantity,
        uint16 pAi,
        uint16 pBook
    ) private {
        (bool placed, uint128 id) =
            _place(m.pool, kind, price, quantity, m.expiry, LucidTypes.ORDER_POST_ONLY);
        if (placed) {
            emit Executed(m.marketId, kind, price, quantity, id);
        } else {
            emit Refused(m.marketId, LucidTypes.Refusal.VenueRejected, pAi, pBook);
        }
    }

    /// @dev The only place an order is sent. `placeBinaryOrder` returns `false` WITHOUT reverting
    /// on a silent rejection, so both the returned flag and a hard revert have to be handled or
    /// the desk would log an `Executed` for an order that never existed.
    function _place(
        address pool,
        uint8 kind,
        uint256 price,
        uint256 quantity,
        uint64 expiry,
        uint8 orderType
    ) private returns (bool, uint128) {
        if (expiry <= EXPIRY_SLACK) return (false, 0);
        uint64 expireNs = uint64(uint256(expiry - EXPIRY_SLACK) * NS_PER_SEC);

        try IBinaryPool(pool).placeBinaryOrder(
            kind, price, quantity, expireNs, orderType, 0, address(0), 0, 0
        ) returns (bool ok, uint128 id) {
            return (ok, id);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Grant the venue everything it will ever need on this pool, once.
    /// @dev The 6909 grants are per operator rather than per id, so one call covers every market
    /// and both legs forever; they live here anyway so the whole setup is one guarded step. The
    /// flag is only raised once every grant landed, so a failed approval is retried next window
    /// instead of permanently disabling the pool.
    function _ensureApprovals(address pool) private {
        if (approved[pool]) return;

        bool ok = true;
        // Buys and mintSet pull collateral from the desk.
        try IERC20Faucet(LucidTypes.COLLATERAL).approve(pool, type(uint256).max) returns (bool r) {
            ok = ok && r;
        } catch {
            ok = false;
        }
        // Sells and burnSet move outcome legs out of the desk.
        try IERC6909Min(LucidTypes.OUTCOME_TOKEN).setOperator(pool, true) returns (bool r) {
            ok = ok && r;
        } catch {
            ok = false;
        }
        // Redemption is routed through the module, not the pool.
        try IERC6909Min(LucidTypes.OUTCOME_TOKEN).setOperator(LucidTypes.MODULE, true) returns (bool r) {
            ok = ok && r;
        } catch {
            ok = false;
        }

        approved[pool] = ok;
    }

    /// @dev Redeem one leg, if it is worth anything and the desk still holds some of it.
    function _redeemLeg(LucidTypes.MarketInfo calldata m, uint8 idx, uint256 outcomeId, uint256 numerator)
        private
    {
        if (numerator == 0) return;

        uint256 bal = IERC6909Min(LucidTypes.OUTCOME_TOKEN).balanceOf(address(this), outcomeId);
        if (bal == 0) return;

        try IBinaryModule(LucidTypes.MODULE).redeem(m.operatorId, m.venueId, m.marketId, idx, bal) {} catch {}
    }

    // -- pricing ---------------------------------------------------------------

    /// @dev Read the live tick, minimum and lot. They are per pool and the venue does change
    /// them, so caching them across windows would eventually place an off-tick order.
    function _bookParams(address pool) private view returns (bool, BookParams memory bp) {
        try IBinaryPool(pool).getOrderBookParameters() returns (uint256 tick, uint256 minQty, uint256 lot) {
            if (tick == 0 || tick >= LucidTypes.ONE) return (false, bp);
            bp = BookParams({tick: tick, minQty: minQty, lot: lot});
            return (true, bp);
        } catch {
            return (false, bp);
        }
    }

    /// @dev The price that crosses the opposing side of the book by one tick.
    /// @dev The venue quotes the YES price for every kind, so buying NO means lifting the YES
    /// BID side and buying YES means lifting the ask. Rounding is always up: for a BUY_YES that
    /// keeps the order crossing, and for a BUY_NO it only ever makes the NO leg cheaper, so
    /// neither direction can silently overpay. An empty opposing side is refused rather than
    /// priced off a guess, because an IOC into an empty book can only fail.
    function _crossPrice(address pool, uint8 kind, uint256 tick) private view returns (bool, uint256) {
        bool wantsAsk = kind == LucidTypes.BUY_YES;

        try IBinaryPool(pool).getBookLevels(!wantsAsk, 1) returns (IBinaryPool.Level[] memory levels) {
            if (levels.length == 0 || levels[0].price == 0) return (false, 0);

            uint256 best = levels[0].price;
            uint256 raw = wantsAsk ? best + tick : (best > tick ? best - tick : 0);
            return (true, _clampPrice(_ceilTo(raw, tick), tick));
        } catch {
            return (false, 0);
        }
    }

    /// @dev The venue requires `0 < price < oneCollateral`, so a crossed or degenerate book is
    /// pulled back to the last usable tick on either end rather than rejected outright.
    function _clampPrice(uint256 price, uint256 tick) private pure returns (uint256) {
        uint256 ceiling = LucidTypes.ONE - tick;
        if (price > ceiling) return ceiling;
        if (price < tick) return tick;
        return price;
    }

    function _ceilTo(uint256 x, uint256 unit) private pure returns (uint256) {
        if (unit == 0) return x;
        return (x + unit - 1) / unit * unit;
    }

    function _floorTo(uint256 x, uint256 unit) private pure returns (uint256) {
        if (unit == 0) return x;
        return x / unit * unit;
    }

    // -- accounting ------------------------------------------------------------

    /// @dev Size by conviction and let the mandate veto. The stake is deliberately NOT clipped to
    /// the cap before the gate sees it: a cap that quietly shrank the order would trade every
    /// time and could never be observed refusing, and the refusal is the point of this contract.
    /// A 38-point disagreement between the committee and the book stakes 38% of equity; a
    /// 3-point one stakes 3%.
    function _intendedStake(uint256 equity_, uint256 edgeBps) private pure returns (uint256) {
        return equity_ * edgeBps / LucidTypes.BPS;
    }

    /// @dev Record what a window actually cost and charge the mandated stake against the budget.
    /// The budget is charged the intended stake rather than the measured fill, which keeps the
    /// daily limit conservative when an IOC order only partially fills.
    function _book(bytes32 marketId, uint256 cost, uint256 stake) private {
        Holding storage h = held[marketId];
        if (!h.open) {
            h.open = true;
            _state.openMarkets += 1;
        }
        // casting to 'uint128' is safe because the cost is what the venue actually escrowed,
        // which the gate already bounded by a uint64 per-window cap.
        // forge-lint: disable-next-line(unsafe-typecast)
        h.cost += uint128(cost);
        openNotional += cost;
        // casting to 'uint64' is safe because the gate refused any stake above the uint64 cap.
        // forge-lint: disable-next-line(unsafe-typecast)
        _state.spentToday += uint64(stake);
    }

    /// @dev The mark measures trading performance, so it also has to follow the money the owner
    /// adds: a mark left behind by a deposit would put the drawdown floor far below the capital
    /// actually at risk, and the risk halt would never fire when it should.
    function _raiseHighWaterMark() private {
        uint256 eq = _equity();
        if (eq > _state.highWaterMark) _state.highWaterMark = _toU64(eq);
    }

    function _refuse(bytes32 marketId, LucidTypes.Refusal reason, uint16 pAi, uint16 pBook) private {
        emit Refused(marketId, reason, pAi, pBook);
    }

    function _free() private view returns (uint256) {
        return IERC20Faucet(LucidTypes.COLLATERAL).balanceOf(address(this));
    }

    function _equity() private view returns (uint256) {
        return _free() + openNotional;
    }

    /// @dev Collateral that left the desk since `before`, guarded because a venue that refunded
    /// more than it took must not underflow the whole handler.
    function _spentSince(uint256 before) private view returns (uint256) {
        uint256 now_ = _free();
        return before > now_ ? before - now_ : 0;
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Probabilities are logged as uint16 bps; a caller passing something absurd should not
    /// wrap around into a plausible-looking number in the UI.
    function _bps16(uint256 bps) private pure returns (uint16) {
        // casting to 'uint16' is safe because the ternary has already excluded every value
        // that would not fit.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bps > LucidTypes.BPS ? LucidTypes.BPS : uint16(bps);
    }

    /// @dev Saturating, because `DeskState` stores equity in a uint64 and a truncated mark would
    /// read as a catastrophic drawdown rather than an implausible balance.
    function _toU64(uint256 x) private pure returns (uint64) {
        // casting to 'uint64' is safe because the ternary saturates anything larger.
        // forge-lint: disable-next-line(unsafe-typecast)
        return x > type(uint64).max ? type(uint64).max : uint64(x);
    }
}
