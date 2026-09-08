# Reviewing Lucid

**Three minutes, if you only have three:** https://youtu.be/b-o_-8mEyKU

**Live interface:** https://lucid-somnia.vercel.app — reads Somnia Shannon directly, no wallet needed to look around.

**Feedback report:** [SDK_FEEDBACK.md](SDK_FEEDBACK.md) — seventeen findings on the Event Contracts
and Reactivity stack, each with a reproduction. Four are failures that produce no error, no revert
and no log; the rest cost between half a day and a day each to work out.

A guided path through this repository, in order, with the exact command for each step and what you
should see. It runs end to end in about five minutes.

**No wallet. No private key. No funds. No install beyond Node 20+ and Foundry.** Every step below
is a read: the verification script signs nothing and calls no state-changing method, the CLI's read
commands never look for a key, and the evaluation harness is an observer that costs nothing.

---

## The one-paragraph version

Lucid is a protocol of autonomous trading desks for DreamDEX Event Contracts, and the whole point is
where the automation lives. A desk is a contract. The keeper is an on-chain reactivity subscription
on Somnia's `0x0100` precompile, so a handler runs as a synthetic transaction in the same block as
the venue's `MarketCreated` — no cron, no worker, no process of ours. The brain is a committee of
Somnia validators that returns a probability on chain with per-validator receipts, and the spot
price it reasons from is fetched by a second committee through Somnia's on-chain price-oracle agent,
so even the input never touches a server we run. On top of that sits the part that matters: the
committee only ever proposes, and a policy contract disposes. Every way this can go wrong —
committee unreachable, answer malformed, no observable book, over the per-window cap, drawdown
breached, window too short to finish in time — resolves to an explicit `Refused(reason)` on chain
and no trade. The refusals are the product surface, not the error path.

---

## 1. Audit the live deployment

```bash
bash contracts/verify-onchain.sh
```

A minute or two. It reads `contracts/deployed.json`, then checks about forty claims against the
chain using ordinary RPC calls plus one query to DreamDEX's public market indexer. It holds no key
and signs nothing, so you can point it at the deployment with an empty wallet and no trust in us.
The last line prints the totals and the exit code follows them.

Every line carries the value it observed — a bare PASS proves nothing you can re-derive. A claim the
chain cannot answer is reported `SKIP`, never assumed true, and the exit code treats a skip as a
failure, because a green line for something nobody looked at is worse than a red one.

What each section is for:

| section | what it settles |
| --- | --- |
| 1 | Every address in `deployed.json` carries runtime code, with byte counts. |
| 2 | Both bonded contracts are above the 32 SOMI reactivity floor, with the margins printed. |
| 3 | A live subscription delivers to the router — emitter, topic, handler and gas limit all match — whichever of the two owns it. |
| 4/5 | `MarketSeen` and `SettlementScheduled` logs from the last few minutes — the router is reacting *right now*, with nothing of ours running. |
| 6 | The router's wiring matches `deployed.json` contract by contract. |
| 7–9 | The demo desk is registered and armed, holds real tUSDC, and its mandate is printed in words rather than as two bitmasks. |
| 10 | The brain's quote is re-derived from the platform's own deposit function: stage 1 + stage 2 = 0.36 SOMI. |
| 11–12 | The failover watcher's mode, health view and spending guards, pointed at our own `MarketCreator`. |
| 13 | Our own permissionlessly-registered series actually gets resolved by the venue's oracle. |

The interesting one is **4/5**. Those logs are emitted by handlers that Somnia validators executed
as synthetic transactions. Nothing was listening. Nothing was polling.

Section 11 may print a note that the market creator's float is under the roll floor; that is the
guard reporting itself honestly, not a failure. Read any `FAIL` or `SKIP` line — the script tells
you exactly which read produced it.

---

## 2. Open the contracts on the explorer

All eight Lucid contracts are source-verified on Blockscout, along with the demo desk clone. The
`MarketCreator` row is a DreamDEX deployment we registered permissionlessly, so its source is
theirs, not ours.

<!-- addresses:start -->
<!-- Written by scripts/sync-addresses.mjs from contracts/deployed.json. Do not edit by hand. -->

| contract | address |
| --- | --- |
| `LucidRouter` | [`0x6aE21a20444141552648C1f8443bAf171BCCcB99`](https://shannon-explorer.somnia.network/address/0x6aE21a20444141552648C1f8443bAf171BCCcB99) |
| `LucidWatch (venue subscription)` | [`0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C`](https://shannon-explorer.somnia.network/address/0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C) |
| `LucidBrain` | [`0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25`](https://shannon-explorer.somnia.network/address/0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25) |
| `LucidDesk (clone implementation)` | [`0xa659b03e2349559f2d56D17F246e66e79467c17e`](https://shannon-explorer.somnia.network/address/0xa659b03e2349559f2d56D17F246e66e79467c17e) |
| `LucidFactory` | [`0x9c1EF0C429f1F88e8247f3539DeF8a1f8FCCEb84`](https://shannon-explorer.somnia.network/address/0x9c1EF0C429f1F88e8247f3539DeF8a1f8FCCEb84) |
| `LucidKeeper` | [`0x4757599dC9A5a089270373a66BEeeD6592788707`](https://shannon-explorer.somnia.network/address/0x4757599dC9A5a089270373a66BEeeD6592788707) |
| `LucidRelay` | [`0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A`](https://shannon-explorer.somnia.network/address/0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A) |
| `LucidSeries` | [`0x747fF3a7A6FE4912c96dCe7faA711dCB6fbd1CE4`](https://shannon-explorer.somnia.network/address/0x747fF3a7A6FE4912c96dCe7faA711dCB6fbd1CE4) |
| `MarketCreator (ours)` | [`0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2`](https://shannon-explorer.somnia.network/address/0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2) |
| `Desk Ai Edge` | [`0x822548990ce81b626a3c3684B0c85f2fd9EC9Fa7`](https://shannon-explorer.somnia.network/address/0x822548990ce81b626a3c3684B0c85f2fd9EC9Fa7) |
| `Desk Maker` | [`0x3ffbB71aec0D5459677021Ad888195042eDA4AA2`](https://shannon-explorer.somnia.network/address/0x3ffbB71aec0D5459677021Ad888195042eDA4AA2) |

- Chain: Somnia Shannon, id `50312`.
- Explorer: <https://shannon-explorer.somnia.network>
- DreamDEX venue this deployment serves: `0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f`
- Our own venue, used by the failover roller: `0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581`

<!-- addresses:end -->

Worth two minutes: open `LucidRouter` and read the natspec at the top of the contract. Nearly every
constant in this codebase exists because something measured on Shannon said so, and each one says
which measurement — the handler gas limit is 100M because at 2M the chain charged for the handler
and never executed it, and the desk stipend is 8M because one live `onVerdict` estimated at
1,314,773 gas when the first version budgeted 1M for it.

---

## 3. Read a real refusal

The refusals are the product. Open the demo desk's log tab on the explorer:

```
https://shannon-explorer.somnia.network/address/<demoDesk>?tab=logs
```

Or watch them arrive live, with no key:

```bash
cd kit && npm install && npm run build
npx lucid watch <demoDesk>
```

Or pull them straight off the chain (Somnia caps `eth_getLogs` at 1000 blocks and mints a block
roughly every 100 ms, so one call covers about 90 seconds of history):

```bash
RPC=https://api.infra.testnet.somnia.network
TIP=$(cast block-number --rpc-url $RPC)
cast logs --rpc-url $RPC --from-block $((TIP-900)) --to-block $TIP \
  --address <demoDesk> 'Refused(bytes32,uint8,uint16,uint16)'
```

The second field is the reason. It is an enum, and the values are append-only on purpose — a
renumbering would silently retitle every refusal in every log line ever emitted, which is the one
change nobody outside could notice.

| # | reason | means |
| --- | --- | --- |
| 1 | `NotArmed` | The owner has the desk switched off. |
| 2 | `AssetNotAllowed` | Outside the mandate's asset mask. |
| 3 | `CadenceNotAllowed` | Outside the mandate's window-length mask. |
| 4 | `WindowTooShort` | Under 90 seconds left; the venue would reject the order anyway. |
| 5 | `CapExceeded` | Over the per-window notional cap. |
| 6 | `DailyBudgetExceeded` | Over the UTC-day budget. |
| 7 | `MaxOpenReached` | Already holding the maximum number of open windows. |
| 8 | `RiskHalt` | Drawdown floor breached, or the consecutive-loss limit hit. |
| 9 | `AiUnavailable` | The committee failed, timed out, or never answered. |
| 10 | `AiMalformed` | The committee answered outside the valid range. |
| 11 | `LowEdge` | The committee and the book agree; there is nothing to trade. |
| 12 | `VenueRejected` | The pool refused the order, including the silent `false` return. |
| 13 | `NoCredit` | The desk's prepaid gas credit ran out. |
| 14 | `InsufficientFunds` | Free collateral cannot fund even the minimum lot. |
| 15 | `NoBook` | No side of the book quoted, so there is no market price to measure an edge against. |

Note what `NoBook` is *not*: a default of 50%. An empty book is the absence of a price, not a price,
and handing `AiEdge` a made-up midpoint would open a position on an invented disagreement. The desk
logs an out-of-range sentinel in the book field instead, so a reader who does not know about it sees
an obviously impossible number rather than a plausible lie.

The router's own `Skipped(desk, marketId, reason)` events are the other half of the trail:
`NO_CREDIT`, `NO_GAS`, `ROUTER_FLOAT`, `NO_VERDICT`, `SCHEDULE_FAILED` and the rest each name the
component that actually failed. That precision was bought the expensive way — an early live run
logged `VERDICT_FAILED` and pointed at the committee, which had in fact answered correctly; the real
cause was a gas stipend sized from mainnet intuition on a chain whose gas schedule is five to ten
times higher.

The captured transaction links from the final recorded run are collected in
[PROOF.md](PROOF.md).

---

## 4. Run the test suite

```bash
bash contracts/setup.sh     # forge install: forge-std + OpenZeppelin v5.4.0
cd contracts && forge test
```

No network, no key. Over 400 test functions across 15 suites; the summary line at the bottom must
read `0 failed` for every one. One of those suites is an invariant campaign on `PolicyLib`, run
with `fail_on_revert = true` and a pinned fuzz seed so a review reproduces exactly what we saw.

The three worth opening:

- `contracts/test/PolicyLib.invariant.t.sol` — the mandate cannot be talked past. Spend never
  exceeds the caps, a halted desk stays halted, and no path reaches execution without a passing
  verdict. The suite also asserts its own generator actually reached the branch under test, so a
  vacuous green is caught.
- `contracts/test/LucidRouter.t.sol` — the fan-out rules. A desk that reverts, runs away, has no
  code or has no credit must be skipped **by name** without taking the other desks in the same
  firing down with it. A revert inside a reactivity handler discards the whole firing and the router
  is charged for the gas regardless, so this is the file where that rule is enforced.
- `contracts/test/LucidWatch.t.sol` — the only suite here written against a defect in a contract
  that was already deployed. `test_router_armVenue_is_bricked_by_a_reap` reproduces the revert that
  took this deployment down on 2026-09-08, and the test beside it runs the identical setup through
  the contract that replaced it. Neither could be written until `MockPrecompile` stopped being
  kinder than the chain, which is why the bug shipped in the first place.

---

## 5. Run the evaluation

```bash
cd eval && npm install && npm run eval
```

Read-only and pre-registered: the control count and seed were fixed before any number was looked at
and have not changed since. It is an **observer, not a replayer** — it reads the verdicts the brain
already wrote on chain, joins each to how that window actually settled from the public indexer, and
grades only the ones whose answer did not exist yet when the verdict was written. Re-asking the
committee about a settled window would price it with today's spot and return something that looks
like a result and is not one.

It prints Brier score, directional accuracy with an exact binomial p-value, a calibration table, and
two negative controls on the identical sample: a constant 50% forecaster and 20,000 coin-flip twins.
Whatever it says is what [EVAL.md](eval/EVAL.md) reports, including where that is a negative result.

---

## 6. Optional: the client

Every read command works with no key at all.

```bash
cd kit && npm install && npm run build
npx lucid status                  # addresses, router balance vs the 32 SOMI floor, subscriptions
npx lucid subs <router>           # decode the router's reactivity subscriptions into English
npx lucid markets                 # live windows a desk could still enter
npx lucid desk status <demoDesk>  # owner, mandate, equity, armed-at-router flag
```

`lucid subs` is the quickest way to see that the automation is a subscription rather than a service:
it turns four opaque topics into a sentence naming the emitter, the handler and the gas limit.

---

## Where to look in the source

| question | file |
| --- | --- |
| How does anything get woken up? | `contracts/src/LucidRouter.sol`, `_onEvent` → `_onMarketCreated` → `_onDecision` → `_onSchedule` |
| Who owns the subscription that wakes it, and why is that not the router? | `contracts/src/LucidWatch.sol`, and [PROOF.md section 12](PROOF.md#12-the-router-bricked-itself-and-what-replaced-it) |
| What can a desk never be talked into? | `contracts/src/lib/PolicyLib.sol`, `gate` |
| How is the committee asked, and what if it fails? | `contracts/src/LucidBrain.sol`, `requestVerdict` → `handlePrice` → `handleResponse` |
| How does a trade actually reach the venue? | `contracts/src/LucidDesk.sol`, `_take`, `_make`, `_place` |
| What is real and what is a mock? | [MOCKS.md](MOCKS.md) |
| Which claims are evidenced, and how? | [CLAIMS.md](CLAIMS.md) |
| What broke while building this? | [SDK_FEEDBACK.md](SDK_FEEDBACK.md) |
