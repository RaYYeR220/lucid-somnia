# SDK and documentation feedback — DreamDEX Event Contracts on Somnia

Notes from three days of building a third-party protocol directly on the Event Contracts stack:
Solidity contracts that hold collateral, mint complete sets, place binary orders, redeem after
settlement, and are woken by Somnia's on-chain reactivity precompile rather than by a server.
Everything below was hit while building, and every number is measured, not estimated. Where we are
inferring a cause rather than reporting an observation, it says so.

Nothing here is a request for features. Most of it is a request for one or two sentences in the
docs, placed where a builder is standing when they hit the problem.

## What this was run against

- Chain: Somnia Shannon testnet, `50312`. RPC `https://api.infra.testnet.somnia.network`.
- `@somnia-chain/markets-sdk` 0.29.0, `@somnia-chain/reactivity-contracts` 0.2.1.
- Foundry 1.7.1, solc 0.8.30, 200 optimizer runs.
- `BinaryMarketsModule` `0x3ecC694Cef705358864a646142ac17A90E29e388`,
  `OutcomeToken6909` `0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9`,
  tUSDC `0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E` (6 decimals).
- Reactivity precompile `0x0100`. Agent platform `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`.
- Indexer `https://dev.smk.somnia.host/v1/graphql`.
- Live sample pool used for book reads: `0x9df243eab4fbcbcefee61b8069cebac50d022133`.

## The five highest-value changes

1. Put Somnia's real gas costs in the docs, with a worked number. It is the root cause of two of
   the blocking items below and it silently invalidates every gas budget a builder brings
   from mainnet. See [B3](#b3--somnias-gas-costs-are-far-above-mainnet-and-this-is-not-stated-anywhere).
2. Document the Hasura indexer as a product surface, or say plainly in the Event Contracts docs
   that `api.dreamdex.io/v0` is spot-only and the indexer is the answer. See
   [D1](#d1--there-is-no-restwebsocket-api-for-event-contracts-and-the-docs-do-not-say-so).
3. Document a minimum working reactivity `gasLimit`, or make the precompile refuse one that is too
   low. See [B1](#b1--a-reactivity-handler-with-a-2000000-gas-limit-is-charged-in-full-and-never-executes).
4. Make `unsubscribe` a no-op on an id the precompile no longer holds, or give owners a way to see
   that a subscription was reaped. As it stands, a contract that runs out of float can be left
   permanently unable to re-subscribe. See
   [B4](#b4--a-reaped-subscription-is-silent-and-cancelling-it-reverts-which-can-permanently-brick-the-owner).
5. State what a reactivity subscription actually costs: it is billed per matching log, matching is
   on topics and emitter only, and on a busy emitter that is the dominant expense of the whole
   protocol. Ours pays for ~230 firings an hour to act on 12. See
   [S9](#s9--a-subscription-filters-on-topics-and-emitter-never-on-content-so-a-venue-wide-watch-bills-you-for-every-market-on-the-venue).

---

# Blocking

Four failures that produce no error, no revert, and no log — the transaction looks like a success
and the work did not happen. Three are fixable with documentation alone; the fourth
([B4](#b4--a-reaped-subscription-is-silent-and-cancelling-it-reverts-which-can-permanently-brick-the-owner))
we think needs a one-line change to the precompile, because no amount of documentation gets a
bricked contract back.

## B1 — A reactivity handler with a 2,000,000 gas limit is charged in full and never executes

**Expected.** A handler subscribed with `gasLimit: 2_000_000` either runs, or runs out of gas and
fails visibly.

**Observed.** The subscription fires. The subscription owner is debited for the full limit
(~0.014 STT at the time). The handler produces no state change, no logs, and no surfaced revert.
From outside it is indistinguishable from "the event never matched my filter" or "my handler was
never called" — which is where we spent the time, checking topics and emitter addresses on a
subscription that was in fact firing correctly every time.

The same handler bytecode, same subscription, same event, at `gasLimit: 3_000_000` and
`5_000_000`: executes normally.

**Reproduction.** Subscribe twice to the same emitter with the same handler, changing only
`gasLimit`:

```solidity
// handler body — one SSTORE and one event, well under 2M on any EVM we had used before
function _onEvent(address emitter, bytes32[] calldata topics, bytes calldata data) internal override {
    lastEmitter = emitter;
    emit Fired(topics[0], data.length);
}
```

```solidity
ISomniaReactivityPrecompile(0x0100).subscribe(SubscriptionData({
    // ... emitter, topics, handler address and selector identical in both cases ...
    gasLimit: 2_000_000,   // charged, never executes
    priorityFeePerGas: 1 gwei,
    maxFeePerGas: 20 gwei,
    isGuaranteed: false,
    isCoalesced: false
}));
```

Then check `somnia_reactivityGetSubscriptionInfo(id)` and the owner's balance: the firing happened
and was billed. Repeat with `gasLimit: 3_000_000` and the handler's `Fired` log appears.

**Impact.** This is the worst possible failure shape for the primitive reactivity is being marketed
for. A builder's first reactivity handler is small, so 2M looks generous, and the failure presents
as a filter bug. It also bills for every attempt, so a debugging loop is expensive.

**Cause.** We did not diagnose it — we only bracketed it. *Inference:* something in the synthetic
transaction's fixed overhead consumes the budget before the handler frame starts, and the
threshold sits somewhere between 2M and 3M. We did not bisect further because 5M+ was correct for
us anyway.

**Suggestion.** State a minimum in the reactivity docs next to `gasLimit(1..200M)` — even
"below ~3,000,000 a handler may be billed without executing; do not go under 5,000,000" would have
saved the afternoon. Better: have `subscribe` revert on a `gasLimit` below the floor, the way it
already enforces the 200M ceiling. Best: surface a distinguishable outcome for an out-of-gas
handler so `getSubscriptionInfo` or the RPC can tell "never fired" from "fired and died".

**Note on billing asymmetry, which the docs should also state.** The owner pays for gas *burned*,
not for the limit reserved. Headroom that is never touched is free; a handler that runs out is
billed the whole limit *and* loses the firing. So the correct advice is "over-provision", not
"tune it". Our production subscriptions ship `gasLimit = 100_000_000`
([`contracts/src/LucidRouter.sol`](contracts/src/LucidRouter.sol), `HANDLER_GAS_LIMIT`), and that
costs nothing.

## B2 — `eth_estimateGas` under-estimates a transaction whose `try/catch` wraps an expensive call

**Expected.** `eth_estimateGas` returns a limit under which the transaction does what it does when
sent with plenty of gas.

**Observed.** When a function wraps an expensive external call in `try/catch`, the estimator
converges on the *cheap reverting branch*. The transaction then lands with `status: 0x1`, having
silently taken the `catch` path. The inner state change never happened, the receipt says success,
and the only tell is a missing log.

**Reproduction.** The shape is:

```solidity
function arm(bool on) external onlyOwner {
    _policy.armed = on;                                    // cheap, always succeeds
    emit PolicySet(_policy);
    // expensive, and deliberately non-reverting
    try ILucidRouter(_router).setDeskArmed(address(this), on) {} catch {}
}
```

Measured on Shannon against live state, same call, same contract:

```
$ cast send $DESK "arm(bool)" true --rpc-url $SHANNON
  status   0x1
  gasUsed  386389
  logs     [PolicySet]                      <- the router call took the catch branch

$ cast send $DESK "arm(bool)" true --gas-limit 3000000 --rpc-url $SHANNON
  status   0x1
  gasUsed  265034
  logs     [PolicySet, DeskArmed]           <- the router call actually ran
```

The successful run is *cheaper* than the failed one, because the failed one burned the whole
sub-call stipend before reverting into the catch.

**Impact.** Any wallet, script, or SDK path that trusts `eth_estimateGas` will do this. It is
particularly bad on Somnia specifically because of B3: the gap between "cheap branch" and
"expensive branch" is enormous here, so the estimator has a wide window in which to pick wrong. And
`try/catch` is not an exotic pattern on this chain — it is *mandatory* inside reactivity handlers,
which must never revert, so every serious reactivity consumer will contain exactly this shape.

**Cause.** *Inference:* the binary-search estimator has no way to distinguish "reverted" from
"reverted and was caught", so any limit at which the inner call reverts still yields
`status: 0x1` and is accepted as sufficient.

**Suggestion.** Two things, both cheap:
- A line in the Somnia developer docs: `eth_estimateGas` is not reliable for transactions
  containing `try/catch`; pass an explicit `--gas-limit`, or estimate with a floor.
- In the SDK and bot kit, apply a multiplier to estimates by default and document it, rather than
  passing the raw estimate through.

Our own fix, which is a reasonable thing to recommend generally: a user-initiated instruction is
never allowed to swallow a revert — only handler-reached code paths get a `try/catch`.

## B3 — Somnia's gas costs are far above mainnet and this is not stated anywhere

**Expected.** Gas costs within the same order of magnitude as mainnet Ethereum, since the EVM
semantics are the same.

**Observed.** Measured on Shannon:

- A single `SSTORE` plus one event: **~250,000 gas**.
- One of our contract entry points, `LucidDesk.onVerdict` — read the book, size an order, place it,
  write the holding — `cast estimate` against real chain state: **1,314,773 gas**.

Any gas budget carried over from mainnet intuition is wrong by roughly an order of magnitude.

**How it bit us, which is the general shape.** Our router hands each desk a fixed gas stipend for
its callback. We sized it at `DESK_GAS = 1_000_000` — generous by mainnet standards for one storage
write and one external call. Every desk call then ran out of gas, the mandatory `catch` swallowed
it, and the router logged a skip. Because the skip reason named the callee, it pointed at the agent
committee, which had in fact answered correctly (3/3 validators, `ok = true`). We spent real time
debugging a component that was working.

**Impact.** This is the single most useful thing you could add to the docs for new builders. It is
upstream of B1 and B2, and it silently breaks:

- reactivity `gasLimit` values chosen by mainnet feel,
- fixed `{gas: N}` stipends on external calls,
- any batching loop sized by "how many of these fit in a block on mainnet",
- multicall and keeper batch sizes. For scale, our 64-entry redemption relay measured **~16.5M gas**
  for a full queue — more than a handler is typically given.

**Suggestion.** One paragraph in the Somnia developer docs with two or three measured reference
points (`SSTORE` + event, a plain ERC-20 transfer, a typical order placement), and an explicit
"do not port gas budgets from Ethereum mainnet". Put the same paragraph at the top of the
reactivity page, where `gasLimit` is a required field a builder has to guess at.

**Two lessons we shipped as code, offered as generic advice:**
- Derive stipends from `gasleft()`, not from constants. See `_stipend` in
  [`contracts/src/LucidRouter.sol`](contracts/src/LucidRouter.sol).
- A skip or failure reason must name the component that actually failed. "The callee reverted" and
  "we did not give the callee enough gas" are indistinguishable from a `catch`, and a label that
  blames the callee sends the reader to debug the wrong contract.

## B4 — A reaped subscription is silent, and cancelling it reverts, which can permanently brick the owner

**Expected.** A contract that falls below `SUBSCRIPTION_OWNER_MINIMUM_BALANCE`, is topped back up,
and re-subscribes, ends up where it started.

**Observed.** It can end up unable to subscribe again, for good, with any balance.

Three behaviours compose into that:

1. The chain removes a subscription from an owner that has run its balance down, and the owner is
   not told — there is no callback, no flag on the subscription, and nothing readable from the
   owner's own storage changes. It goes on holding an id.

   **What triggers the removal is not established, and an earlier version of this report said it
   was the 32 SOMI floor.** That is more than we observed. What we observed is two points: a
   contract at 0.68 SOMI had lost its subscription, and a second contract sat at 7.65 SOMI for
   nineteen hours with its subscription still live and still delivering. So the trigger is
   somewhere below the floor the docs name, and it may not be a balance threshold at all — running
   out of money to pay a firing would produce the same two observations. The floor itself is
   enforced at `subscribe` time; `SomniaExtensions._subscribe` checks it and reverts, which is
   visible in the library.

   Either way the hazard is the same and the fix below is the same: an owner can lose a
   subscription without being told, and then cannot cancel the id it is still holding.
2. `somnia_reactivityGetSubscriptionInfo(id)` for a reaped id returns `{"result":[]}` — an empty
   array, not an error and not a row with a status. So the "it is gone" signal exists, but only over
   RPC, and only if you already suspect it.
3. `ISomniaReactivityPrecompile.unsubscribe(id)` **reverts** for an id the precompile no longer
   holds, and `SomniaExtensions.unsubscribe` turns that into `UnsubscribeFailed()`.

Any contract that does the natural thing — cancel the old subscription before creating the new one,
which is what you must do to avoid two live subscriptions on the same filter — now has a
re-subscribe path that reverts forever. Ours did:

```
$ cast call $ROUTER 'armVenue(address,bytes32)' $MODULE $VENUE --from $OWNER
Error: execution reverted, data: "0x13e7ce5d"      # UnsubscribeFailed()

$ cast balance $ROUTER                              # 40 SOMI, well over the floor
$ curl -s $RPC -d '{"method":"somnia_reactivityGetSubscriptions","params":["'$ROUTER'"]}'
{"result":[]}
```

**Reproduction.** Deploy a handler contract with a `rearm()` that cancels `lastId` and subscribes
again. Fund it to 33 SOMI, arm it against a busy emitter, and let the firings drain it to near
zero. Top it back up to any amount and call `rearm()`: it reverts, and there is no state on the
contract you can change to get past it. Draining it is the part that takes patience — dropping the
balance just under 32 is not sufficient, which is the correction in point 1 above.

**Impact.** For us this was the most expensive single failure in the project, and unlike B1 and B2
it was not recoverable by understanding it. Running out of float is not an exotic state for a
reactivity contract — it is the ordinary end of a funding round, and the docs correctly describe
the floor as a balance to maintain. What they do not say is that crossing it can be terminal for
the contract's ability to subscribe at all. Our desks bind to their router permanently, so
redeploying the router would have stranded live collateral; we shipped a second bonded contract
that owns the subscription and names the original as its handler, which works only because the
precompile lets a subscription name a handler other than its owner and `SomniaEventHandler` does
not check who owns the subscription behind a callback. Not every architecture has that escape.

**Suggestion**, in the order we would want them:

1. Make `unsubscribe` a no-op — or return `false` — for an id that is not live, rather than
   reverting. A cancel whose goal is "this id is not delivering to me any more" has already
   succeeded. This is a one-line change and it removes the whole failure class.
2. Failing that, expose the liveness of an id in a way a *contract* can read: a
   `isSubscriptionLive(uint256) returns (bool)` view on `0x0100`. Today the only source is an RPC
   method returning an empty array, which no contract can consult before deciding whether to
   cancel.
3. Document it either way. One sentence next to `SUBSCRIPTION_OWNER_MINIMUM_BALANCE` — "a
   subscription removed for insufficient balance cannot be cancelled afterwards; guard your
   re-subscribe path" — would have turned an outage into a paragraph.

**Note for other builders reading this before it is fixed.** Wrap the cancel in a low-level call
and ignore the failure:

```solidity
(bool ok,) = address(0x0100).call(
    abi.encodeWithSelector(ISomniaReactivityPrecompile.unsubscribe.selector, id)
);
// `ok == false` means the id was already gone. Record it; do not revert on it.
```

There is a second lesson underneath this one that is not Somnia's problem but is worth stating: our
test double for the precompile accepted `unsubscribe` for any id at all, so the failing path was
unreachable in 402 passing tests. A mock that is kinder than the chain does not make a contract
safer.

---

# Sharp edges

Things that are correct as designed, cost time to discover, and would each be fixed by a sentence
in the docs.

## S1 — `try/catch` does not catch Solidity's `extcodesize` check

**Expected.** `try Foo(addr).bar() {} catch {}` cannot take down the calling frame.

**Observed.** It can. When the called function returns data, solc emits an `extcodesize` guard
before the call and runs the return-data decoder in the *caller's* frame after it. Both of those
revert *outside* the `catch`. So a typed call to an address with no code reverts past the wrapper.

```solidity
// NOT safe: reverts uncatchably if `router` has no code
try ILucidRouter(router).setDeskArmed(address(this), on) {} catch {}

// safe
if (router.code.length == 0) return;
try ILucidRouter(router).setDeskArmed(address(this), on) {} catch {}
```

**Why this matters more on Somnia than elsewhere.** A reactivity handler must never revert: the
chain executes it as a synthetic transaction, so a revert does not fail one item of work, it
discards the entire fan-out for everything else in the same firing — and the subscription owner is
billed for the gas regardless. `try/catch` is the obvious tool for that, and it is not sufficient
on its own. Every external target in our handler path is `code.length`-checked first
([`contracts/src/LucidKeeper.sol`](contracts/src/LucidKeeper.sol),
[`contracts/src/LucidRouter.sol`](contracts/src/LucidRouter.sol)).

**The asymmetry, which is the nastier half.** A call to a code-less address that expects *no*
return data reads as a **silent success**. So the same missing-code bug is a hard revert in one
place and a phantom completion in another. We hit this in our keeper: an upkeep call into an empty
address would have been counted as upkeep performed. Where it mattered we dropped to a low-level
`staticcall` and decoded manually, so a malformed answer stays contained:

```solidity
(bool ok, bytes memory ret) = MODULE.staticcall{gas: READ_GAS}(
    abi.encodeCall(IBinaryModule.markets, (marketId))
);
if (!ok || ret.length < 32) return 0;
return abi.decode(ret, (uint256));   // first tuple field is the whole answer we need
```

**Suggestion.** A "writing a handler that cannot revert" section on the reactivity page, with these
three rules: check `code.length` before every typed external call; give every call an explicit gas
stipend (a reverting call returns its gas, a *looping* one takes 63/64 of what is left); prefer
low-level calls where you only need one field of a large tuple.

## S2 — `placeBinaryOrder` returns `(bool success, uint128 id)` and a `false` does not revert

**Expected.** A failed order placement reverts.

**Observed.** It returns `(false, 0)` and the transaction succeeds. This is easy to treat as
success — especially from a `try/catch`, where the empty success branch and the false-return branch
look identical, and especially through the SDK, where a reverted write does not throw either.

**Impact.** A strategy can believe it holds a position it never opened. On a thin book that state
persists silently until settlement, when it becomes a P&L discrepancy with no transaction to
point at.

**Suggestion.** Document the assert-on-`OrderPlaced` pattern prominently — on the order-entry page,
not in a footnote — and ideally ship it as a helper in the SDK so the correct thing is the default:

```
OrderPlaced topic0
0xd90f62f61ee2f606b132cfdfd883ddd079228b6fd6bffd9d7cf848daf824639d
```

Worth documenting alongside it: `OrderFilled` fires *before* the taker's `OrderPlaced` in the same
transaction, which surprises anyone parsing receipts in order. And `POST_ONLY` *does* revert
(`PostOnlyWouldCross`), so the two entry paths have opposite failure conventions — that contrast is
the thing to spell out.

## S3 — `abi.decode(logData, (T))` fails for a dynamic struct

**Expected.** Given the non-indexed body of a log and a struct matching its layout, `abi.decode`
decodes it.

**Observed.** It reverts on every real log, if the struct is dynamic. `abi.decode(x, (T))` reads
`x` as the encoding of the one-element tuple `(T)`, and when `T` is dynamic that encoding begins
with an offset word pointing at the struct. Raw log data is the bare tuple of non-indexed arguments
with no such word. The decoder has to be handed one:

```solidity
// reverts — MarketCreatedData holds two strings and a bytes, so it is dynamic
abi.decode(data, (MarketCreatedData));

// works
abi.decode(bytes.concat(bytes32(uint256(0x20)), data), (MarketCreatedData));
```

**Impact.** Small in absolute terms, universal in reach: the reactivity precompile hands a
subscriber `(address emitter, bytes32[] topics, bytes data)` rather than decoded arguments, so
*every* on-chain consumer of an event body meets this on its first handler. `MarketCreated` on
`BinaryMarketsModule` is dynamic (17 non-indexed fields, three of them dynamic), so it is the first
event anyone building on Event Contracts will try to decode.

**Suggestion.** One line and one snippet on the reactivity page, where the handler calldata layout
is described. Our version, with the reasoning written out, is in
[`contracts/src/lib/MarketDecoder.sol`](contracts/src/lib/MarketDecoder.sol) — it is four lines and
it is the sort of thing that belongs in the SDK's Solidity surface.

Related and worth documenting in the same place: decoding a 17-field event into named locals
overflows the stack. Decode straight into the struct.

## S4 — The indexer's `clobStatus` lags, and the terminal status is `Finalized`, never `Resolved`

**Expected.** A row with `clobStatus: "Trading"` can be traded.

**Observed.** The indexer lags the chain by seconds to minutes. A row still reading `Trading` is
routinely already past its expiry; `placeBinaryOrder` then reverts `OrderAlreadyExpired`. Filtering
on wall-clock time against `expiry` is the only signal that does not lie:

```graphql
# lies
where: { clobStatus: { _eq: "Trading" } }

# works
where: {
  marketType: { _eq: "BINARY" }
  expiry:     { _gt: $nowPlusSlack }
  finalized:  { _eq: false }
}
```

We apply the same cut twice on purpose — server-side to keep the response small, and again locally
after parsing, so a slow round trip cannot hand back a window that expired in flight
([`kit/src/markets.ts`](kit/src/markets.ts)).

**Second half, which is silent.** The terminal status is `"Finalized"`. `"Resolved"` does not exist
in the indexer. A filter written against `"Resolved"` returns an empty list forever, with no error —
Hasura has no reason to complain about a string that matches nothing. This is easy to read as "no
markets have settled yet". Note that `4 Resolved` *is* a valid value of the on-chain
`BinaryMarket.status()` enum, which makes the mismatch actively misleading rather than merely
undocumented.

**Suggestion.** Document the status values the indexer actually emits, next to the on-chain
`status()` enum, and say which one differs. And add a line saying `clobStatus` is eventually
consistent and must not be used as a trading gate.

## S5 — `tickSize` / `lotSize` / `minQuantity` come back `null` on binary market rows

**Expected.** The market row carries the book parameters, since it carries thirty-odd other fields.

**Observed.** On binary rows all three are `null`. The real values are on the pool:

```
$ cast call $POOL "getOrderBookParameters()((uint256,uint256,uint256))" --rpc-url $SHANNON
(1000, 1000, 1000)          # tick, minQuantity, lot — Shannon
```

Mainnet reads `1e15` for all three. The bot kit's default of `MM_LOT=1` disagrees with the chain's
`1000`. A quantity that is not lot-aligned, or a price that is not tick-aligned, is rejected — so a
builder who takes the row's `null` as "no constraint", or the kit's `1` as the truth, gets
rejections that look like a pricing bug.

They are also per-pool and the venue does change them, so they must be read per window rather than
cached across windows.

**Suggestion.** Either populate the three fields on binary rows, or document on the market-schema
page that they are spot-only and point at `getOrderBookParameters()`. And change the bot kit's
default to read from the pool rather than shipping a constant that is wrong on both networks.

## S6 — `winningOutcome()` was removed and now reverts; the winner is the argmax of `payoutNumerators()`

**Expected.** `winningOutcome()` on the market contract, since it is still referenced around.

**Observed.** It reverts. The winner is the argmax of `payoutNumerators()`.

**The part that catches you after you fix that.** A **voided** window pays *both* legs half. So a
per-leg redemption test written as "is this leg the argmax" redeems one leg of a voided market and
silently abandons the other. The correct per-leg test is a **non-zero numerator**:

```solidity
// wrong on a voided window
if (idx == argmax(nums)) _redeemLeg(...);

// right — each leg redeems iff its own numerator is non-zero
_redeemLeg(m, 0, m.yesId, nums[0]);
_redeemLeg(m, 1, m.noId,  nums[1]);
```

Compounding it: redeeming a losing leg **succeeds and pays 0** — no revert. So neither the naive
argmax test nor the receipt tells you anything. The only honest source of truth for P&L is the
collateral balance before and after
([`contracts/src/LucidDesk.sol`](contracts/src/LucidDesk.sol), `onSettlement`).

**Suggestion.** Remove `winningOutcome()` from any remaining docs and replace it with the payout
vector, with the void case spelled out: winner pays `amount * (10000 - settlementFeeBps) / 10000`,
voided pays `amount / 2` on *both* legs, loser pays `0` without reverting.

## S7 — A market can be `finalized: true` with no outcome, and `payoutNumerators()` then returns all zeros

**Expected.** `finalized` implies an outcome.

**Observed.** On 28 August, roughly 15:00–16:00 UTC, markets finalized without one:
`Market.finalized: true`, `winningOutcome: null`, at the worst point 12 of the last 12 finalized
markets across both assets. `OracleAnswer` entries stopped publishing for about 50 minutes in the
same window, so anything pricing off oracle values went blind at the same time. It recovered on its
own. (Reported in the builders' channel at the time; the platform side of it is not the point of
this entry.)

**Why it is a docs item and not an incident report.** The on-chain shape of that state is
`payoutNumerators()` returning **all zeros**, and a strategy reading a zero for the leg it holds
will book a total loss. That is wrong twice: the position is still redeemable later, and a desk
with a loss-streak circuit breaker will trip itself on the back of someone else's outage. Our guard:

```solidity
// An all-zero payout vector is not a loss, it is an unresolved window.
if (nums[0] == 0 && nums[1] == 0) return;   // leave the holding open
```

**Suggestion.** Either give this state a distinct status so it is not `Finalized`, or document the
all-zero payout vector explicitly on the settlement page: "an all-zero vector means not-yet-resolved,
not a loss; do not close a position on it". One sentence prevents a whole class of wrong accounting.

---

## S8 — The permissionless upkeep calls are genuinely open, and every one we have made from a contract has reverted

**Expected.** `finalizeMarket`, `syncSettlement`, `releasePool`, `pokeOracle` and a market's own
`voidExpired` take no allowlist, so a third-party contract that wakes on settlement can carry its own
upkeep. The access control really is open — that part is true and it is the reason this entry is here
rather than in Blocking.

**Observed.** A contract that attempts all five after every settlement firing has landed none of
them. Its six counters — finalized, released, synced, poked, voided, failures — read
`0 0 0 0 0 1362` at 2026-09-07 05:58 UTC: five zeros against 1 362 reverted attempts, over roughly
260 markets. The contract is wired correctly and the calls are not wrong. Simulated **from that same
contract's address** against an expired market with `isResolved()` true and `status()` 4, which the
indexer still lists as `finalized: false`:

| call | result |
| --- | --- |
| `finalizeMarket(bytes32)` | succeeds |
| `syncSettlement(bytes32)` | succeeds |
| `pokeOracle(uint256)` | succeeds |
| `releasePool(bytes32)` | reverts `0xdf88ba21` |
| `voidExpired()` | reverts `0xe064752b`, args `(2, 4)` — correct, a resolved market is not void |

So three of the five would go through if made at that moment, and in production none of them ever
has. **We cannot yet explain the gap**, and we are not guessing at one in writing: our first
confident explanation was wrong (`settlementWindow()` reads 86 400 — a day — and is evidently the
oracle's deadline to answer, not a period a market must sit through before it may be finalized).

**Reproduction.** Pick any expired market the indexer reports as `finalized: false`, read its
`market` address and `oracleQuestionId` out of `markets(marketId)`, and simulate each call with
`--from` set to the calling contract:

```bash
cast call --from $CALLER $MODULE 'finalizeMarket(bytes32)' $MARKET_ID --rpc-url $RPC
cast call --from $CALLER $MODULE 'releasePool(bytes32)'    $MARKET_ID --rpc-url $RPC
cast call --from $CALLER $MARKET 'voidExpired()'                      --rpc-url $RPC
```

**Suggestion.** Two sentences would close most of this. First, publish the custom-error selectors for
the upkeep surface — `0xdf88ba21` and `0xe064752b(uint8,uint8)` are unresolvable from the docs, and a
four-byte selector with no ABI is the difference between a diagnosis and a guess. Second, state the
precondition each call needs and the earliest moment it is satisfiable, relative to `expiry` and to
the oracle's answer. A third-party keeper has to decide *when* to fire; right now that timing has to
be discovered by burning gas on reverts, which is exactly what the counter above is a record of.

## S9 — A subscription filters on topics and emitter, never on content, so a venue-wide watch bills you for every market on the venue

**Expected.** Some way to pay only for the logs a protocol actually acts on.

**Observed.** `SubscriptionFilter` is `{eventTopics[4], origin, emitter}`. Topics 1-3 can pin
*indexed* arguments, and for `MarketCreated` the indexed fields are `marketId`, `market` and `pool`
— three values that do not exist until the log does. Everything a subscriber would want to filter
on (asset, cadence, venue) is in the non-indexed body. So a protocol that serves one venue must
subscribe to the module's whole log stream and discard most of it inside the handler, having paid
for the handler.

Measured on our deployment on 2026-09-08, with both desks armed and their mandate closed so nothing
was traded:

| | |
| --- | --- |
| markets the venue created | ~230/hour |
| markets any desk wanted | 12/hour |
| cost of the log subscription alone | 2.8 SOMI/hour |
| cost of the whole protocol, trading nothing | 4.7 SOMI/hour |

So **95% of the firings we pay for are for markets we decline in the first twenty lines of the
handler**, and simply being armed costs 113 SOMI/day before a single trade. On mainnet gas that is
not a rounding error, and it is the number that decides whether a reactive protocol is viable at
all.

**Impact.** Not a bug — the filter is documented and behaves as specified. The problem is that the
cost model is not derivable from the docs. A builder reads "subscribe to an event" and budgets for
the events they care about; the bill is for the events the *emitter* produces. We only found the
real number by watching a balance for ten minutes with the desks switched off, which is not a
technique the docs suggest.

**Suggestion**, cheapest first:

1. One paragraph in the reactivity docs: a subscription is billed per matching log, matching is on
   topics and emitter only, and on a busy emitter that is your dominant cost. Show the arithmetic
   once with a real emitter.
2. A `getSubscriptionCost(id)` view, or a cumulative `spent` field on `getSubscriptionInfo`. Today
   the only way to know what a subscription costs is to diff the owner's balance and attribute it
   yourself — and if the owner holds several subscriptions, you cannot attribute it at all.
3. If it is ever on the roadmap: one non-indexed word to match on, or a `maxFiringsPerBlock`. Either
   would let a venue-scoped protocol pay venue-scoped costs.

**Note for other builders.** Budget from the emitter's log rate, not from your own interest in it,
and measure the floor before you measure anything else: arm the protocol with every policy closed,
watch the balance for ten minutes, and that number is what you pay to exist.

## S10 — The live cadence set changes with no announcement and nothing to query, and the shipped enum still lists the ones that are gone

**Expected.** Some way to ask which window lengths a venue is currently rolling.

**Observed.** There is none. The front-end bundle ships `INTERVAL_CADENCE_SEC` with `1m, 5m, 15m,
1h, 4h, 1d`; `4h` and `1d` are built but gated off; the docs describe the venue generically. What is
actually being rolled is discoverable only by counting recent markets on the indexer.

It moves. Earlier in the hackathon week the venue was rolling 5m, 15m and 1h. On 2026-09-08 at 15:55
UTC, of the last 298 binary markets on venue `0x1a1e6821…`: **246 were 60 s and 52 were 300 s.**
Zero 15-minute, zero 1-hour.

```bash
curl -s https://dev.smk.somnia.host/v1/graphql -H 'content-type: application/json' \
  --data '{"query":"{ Market(where:{marketType:{_eq:\"BINARY\"}}, order_by:{expiry:desc}, limit:400)
           { asset intervalSec venueId } }"}' | jq -r '.data.Market[] | "\(.asset) \(.intervalSec)"' | sort | uniq -c
```

**Impact.** We tuned a strategy's allowed-cadence mask to 15m and 1h to cut costs, deployed it, and
silently switched both desks off — there was nothing at those lengths to trade. The desks were
armed, funded, correct, and idle, and the only symptom was refusals with a reason that reads exactly
like a deliberate mandate. It cost us an hour and it would cost a less suspicious builder a lot
more, because every layer reports success.

There is a second-order version for anyone building on the cadences: 60-second windows cannot be
traded by anything that has to consult an off-chain or committee-backed price first, since the round
trip does not fit inside the window. With 15m and 1h gone, that leaves exactly one usable cadence on
the venue, and nothing anywhere says so.

**Suggestion.** Expose the live set — a `series` query on the indexer, or a documented "these are the
cadences currently rolling" line in the Event Contracts docs, updated when it changes. Failing that,
say in the docs that the shipped enum is the set of cadences the venue *can* roll rather than the
set it *is* rolling, and point at the indexer query above as the way to find out.

---

# Documentation gaps

Three things that exist, work well, and are not written down. Each cost between half a day and a
day to establish, and each was answerable in one paragraph.

## D1 — There is no REST/WebSocket API for event contracts, and the docs do not say so

**Expected.** `api.dreamdex.io/v0`, documented under the HTTP API page, covers event contracts.

**Observed.** It is spot-only. There is no REST or WebSocket surface for event contracts at all.
The real off-chain surface is the **Hasura GraphQL indexer** — testnet
`https://dev.smk.somnia.host/v1/graphql`, mainnet `https://prd.smk.somnia.host/v1/graphql` — which
is unauthenticated, unrated, has 122 query roots, a `Market` entity with 72 fields, and tables for
`Fill`, `Candle`, `Order`, `OracleQuestion`, `OracleAnswer`, `MarketResolutionEvent`,
`RedemptionRecord`, `SettlementFeeRecord`, `BuilderFeeRecord`, `Pool`, `Series`, `MarketVenue` and
more. It is excellent. It is also not documented as a product surface anywhere we could find.

**Why this is not optional.** `eth_getLogs` is capped at 1,000 blocks per query on Somnia and blocks
are ~100 ms, which is about 100 seconds of history per call. Backfilling anything from logs is not
viable. The indexer is not a convenience, it is the only way to read history — so a builder either
finds it or builds something that cannot work.

**Impact.** Documenting it would save every builder a day. We spent one finding and mapping the
indexer, and every trap in S4 and S5 is a trap only because there is no schema page to read.

**Suggestion.** A page in the Event Contracts developer docs that says: (a) the HTTP API is
spot-only; (b) here is the indexer endpoint for each network; (c) here are the entities and the ten
fields most people need; (d) here are the four traps — `marketType` is uppercase `BINARY`, terminal
`clobStatus` is `Finalized`, `Market_aggregate` does not exist, `Order` has no `pool` filter (use
`market: { venueId: { _eq: ... } }`) and `OutcomeBalance` has no `owner` filter. That is one page,
and it removes a day of archaeology per team.

## D2 — `OperatorPermissionsRegistry` is spot-only, and there is no operator gate on a BinaryPool

**Expected.** The Event Contracts equivalent of `SpotPool`'s `placeOrderFor` / `cancelOrderFor`
operator flow, so a bot key can be granted bounded permission over an owner's orders without
withdrawal authority.

**Observed.** It does not exist. `OperatorPermissionsRegistry` gates `SpotPool`'s `placeOrderFor`
and `cancelOrderFor` only. A `BinaryPool` has no operator gate at all. `placeBinaryOrderFor`
(selector `0x5d97c566`) is present in the ABI but unwired in the SDK with no known caller —
*we did not test its gating*, so treat that as unresolved rather than as an answer.

This was answered clearly and quickly in the builders' channel. It appears nowhere in the docs. It
is the first question any team building unattended execution will ask, and the answer determines
their architecture before they write a line.

**The shape that does work**, and which the docs should recommend directly: make a **contract** the
order owner. It holds the orders and the collateral, the bot key only triggers it, and withdrawal
stays behind whatever rule is written into the contract. We verified the whole loop from a contract
on Shannon — `mintSet`, `placeBinaryOrder` with `LIMIT` and `POST_ONLY` on both sides, holding
ERC-6909 legs, and `redeem` after settlement — with zero off-chain signatures. Total one-time setup:

```solidity
IERC20(collateral).approve(pool, type(uint256).max);   // buys and mintSet
IERC6909(outcomeToken).setOperator(pool,   true);      // sells and burnSet
IERC6909(outcomeToken).setOperator(module, true);      // redeem
```

**Suggestion.** A short "unattended execution" page: state that the operator registry is spot-only,
state that a BinaryPool escrows against `msg.sender` and has no operator gate, and give the
contract-as-owner pattern with those three setup calls. That is the whole answer, and it is
currently only available by asking.

## D3 — The agent registry is not documented, and there is an undocumented Price Oracle base agent

**Expected.** The base-agent docs tell you how to find a base agent's id.

**Observed.** They ship a placeholder:

```solidity
uint256 agentId = 12345678901234567890; // Replace with actual agent ID from the web app
```

with no instructions for finding the real one, no list of base agent ids, and no mention of a
registry. A builder's options are to guess, to hunt through a web app, or to ask.

**What actually answers it.** `AgentRegistry` at `0x08D1Fc808f1983d2Ea7B63a28ECD4d8C885Cd02A`
answers `getAllAgents()` and `getAgent(id)` on **both** networks, returning each agent's manifest —
name, ABI, configuration. That is how we resolved every id we used:

```
$ cast call 0x08D1Fc808f1983d2Ea7B63a28ECD4d8C885Cd02A \
    "getAgent(uint256)" 13174292974160097713 --rpc-url $SHANNON
# -> agents/json-fetch/....json, name "JSON API Request",
#    ABI: fetchUint(string url, string selector, uint8 decimals) -> uint256
```

**The part that is worth more than the fix.** The registry also lists a **Price Oracle** base agent,
id `9911223344556677889`, which appears in no documentation at all:

```solidity
function getPrices(string[] calldata symbols, uint8 decimals)
    external
    returns (uint256[] memory prices, uint8[] memory numSources, uint64[] memory lastUpdated);
```

Its manifest also carries `getPricesPacked`, `getPricesSlots` and
`getExchangePrice(string,string,uint8,uint64)`. `getAgent(9911223344556677889)` answers on Shannon
(50312) and **reverts `AgentRegistry: agent not found` on mainnet (5031)**, so it is testnet-only as
of this writing.

This is strictly better than a single REST feed for price data, and builders are currently reaching
for a REST endpoint because that is what the JSON API agent example shows. A median across
exchanges, with the **source count** and the **refresh timestamp** attached, lets a consumer refuse
a degraded reading — we gate on both (`minSources`, `maxFeedAgeMillis` in
[`contracts/src/LucidBrain.sol`](contracts/src/LucidBrain.sol)). It also removes a failure mode we
had already had to design around: a single venue geo-blocking part of a validator set costs a
committee member on *every* request, which is why our JSON feed points at one exchange rather than
another in the first place. A median cannot be geo-blocked out of existence.

Note that the packed variants drop `numSources` and `lastUpdated`, which are exactly the two fields
those guards need — worth saying in the docs, since `getPricesPacked` looks like the efficient
choice.

**Suggestion.** Three things:
- Put the `AgentRegistry` address and `getAgent` / `getAllAgents` in the base-agent docs, and
  replace the placeholder with a real id plus a one-line "or look it up yourself" example.
- Publish the base agent ids per network, and say which exist on which network. We built both feed
  paths behind an owner-settable id precisely because the registry disagrees between networks and
  Agents is labelled a prototype; that hedge should not be necessary to figure out.
- Document the Price Oracle agent. It is a better primitive than the one currently being shown.

---

# What worked well

Specifics, because these are the things we relied on and would be sorry to see change.

**`mintSet` needs no counterparty, and that is what makes strategies possible on a thin book.**
Top event-contract markets were at single-digit trade counts and most live windows at zero while we
were building. Every design that requires *taking* liquidity breaks on a book like that. `mintSet`
does not: `mintSet(yesTo, noTo, amount)` pulls collateral from `msg.sender` and hands back one UP
and one DOWN, from a contract, with no order book involved — we ran 100 tUSDC → 100 YES + 100 NO
from a contract on Shannon. Being able to split the two legs to *different* addresses is a real
design lever, not a detail. This one function is the reason a third-party strategy contract is
expressible at all, and it deserves more prominence in the docs than the order-entry path gets.

**ERC-6909 approval is per-operator, not per-id.** One `setOperator(pool, true)` covers every market
and both legs forever. Given that pools are per-window and recycled, per-id approval would have made
a contract-owned strategy pay an approval per window — which would have killed the pattern on gas
alone at Somnia's prices. The three one-time grants in D2 are the *entire* setup surface for a
contract that then trades indefinitely. That is a genuinely good design decision.

**`quoteBinaryStakeOverBook` is exactly right, and we reused its semantics rather than
reimplementing them.** It sweeps asks cheapest-first, sets the protective price at the worst level
touched, aligns up to tick, caps a tick below one collateral, and snaps quantity *down* to a whole
lot so escrow can never exceed the stake. Every one of those five decisions is one we would have got
wrong on a first pass, and the last in particular is the difference between a stake-sized order and
an overspend. This is the kind of helper that should be advertised much harder than it is — it
encodes the venue's own sizing rules, and a builder who does not find it will reinvent it badly.

**CREATE3-deterministic addresses across both chains.** The core contracts are byte-identical at the
same addresses on 5031 and 50312. One address table, no per-chain configuration, and a testnet
integration that is a real rehearsal for mainnet rather than an approximation. It also means an
address read on one network is a valid probe on the other, which is how we established that the
Price Oracle agent in D3 is testnet-only.

**The permissionless upkeep surface.** `finalizeMarket`, `releasePool`, `syncSettlement`,
`pokeOracle`, `voidExpired`, `cancelExpiredOrders`, `sweepExpiredAtLevel`, `recoverSeries`,
`captureClose` — all callable by anyone. This means a third-party protocol can carry its own
settlement path instead of waiting on someone else's keeper, which matters enormously when your
positions sit on 5-minute windows. We run all of them opportunistically after each settlement
([`contracts/src/LucidKeeper.sol`](contracts/src/LucidKeeper.sol)); in our deployment every one of
those attempts has reverted and we cannot yet say why, which is written up as
[S8](#s8--the-permissionless-upkeep-calls-are-genuinely-open-and-every-one-we-have-made-from-a-contract-has-reverted).
The permission model is not what is in the way. Opening these up was the right call and it is
under-advertised.

**`redeemFor` is relayable by anyone.** A clean EIP-712 struct, no relayer allowlist, and the only
signed struct in the whole surface. Combined with the permissionless upkeep above, it means a user
can be exited from a settled position without ever sending a transaction — which is the piece that
makes auto-claim buildable by someone other than the first-party app. One open question we could not
resolve: whether `redeemFor` honours EIP-1271. We did not test it. If it works, saying so in the
docs would unlock smart-account users for every relayer built on this.
