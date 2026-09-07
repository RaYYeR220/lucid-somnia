# Lucid

**Live interface:** https://lucid-somnia.vercel.app — reads Somnia Shannon directly, no wallet needed to look around.

Autonomous trading desks for **DreamDEX Event Contracts** on Somnia.

Event Contracts are short-dated binary markets: will BTC be above the price this window opened at
when the window closes. The venue opens one, settles it against an oracle, and recycles the pool.
Lucid trades the four cadences its mandate recognises — 60, 300, 900 and 3600 seconds.

Every comparable product is a process on somebody's laptop holding an API key. A Lucid desk is a
contract, and the three jobs that normally need a server are done by Somnia validators.

| job | how it is normally done | how Lucid does it |
| --- | --- | --- |
| keeper | cron, worker, open browser tab | on-chain reactivity subscription, precompile `0x0100` |
| brain | an off-chain model behind an API key | a validator committee, verdict and receipts on chain |
| data | a server fetches a price endpoint | a second validator committee, on-chain price oracle |

There is no bot key. There is no process to restart. Turn every machine we own off and the desks
keep reacting, because the thing reacting is the chain.

The safety spine is one sentence: **the model only ever proposes; a policy contract disposes.**
Every failure mode — committee unavailable, low confidence, no observable book, over cap, drawdown
breached, window too short to finish in time — becomes an explicit on-chain `Refused(reason)` and no
trade. Refusing loudly is the product.

---

## Why a contract owns the orders

From a Somnia engineer, answering another builder in the public builders' channel on 25 August,
about running unattended execution on Event Contracts:

> The OperatorPermissionsRegistry is spot-only… A BinaryPool has no operator gate at all, so
> there's currently no way to grant a bot bounded permission to place or cancel EC orders. The
> shape that works today is making a contract the order owner: it holds the orders and collateral,
> your bot key only triggers it, and withdrawal stays behind whatever rule you write into it.

That is exactly `LucidDesk`. Lucid goes one step further: there is no bot key at all. The trigger
is a reactivity subscription, and the only key in the system belongs to the desk owner, who uses it
to deposit, set the mandate, arm, and withdraw.

---

## Architecture

```
 ┌─ DreamDEX Event Contracts ──────────────────────────────────────────────┐
 │  BinaryMarketsModule 0x3ecC694C…  ·  one BinaryPool per window          │
 │  ERC-6909 outcome legs  ·  tUSDC collateral  ·  Prophecy Oracle         │
 └────────────┬─────────────────────────────────────────────▲─────────────┘
       MarketCreated                                        │
              │                                  mintSet · placeBinaryOrder
              ▼                                   · finalizeMarket · redeem
 ┌─ Somnia reactivity precompile 0x0100 ─────────┐          │
 │  log subscription on the venue                 │         │
 │  Schedule one-shots: decision, then settlement │         │
 └────────────┬───────────────────────────────────┘         │
              │  validator-executed synthetic transaction,  │
              │  same block as the event, msg.sender=0x0100 │
              ▼                                             │
 ┌─ LucidRouter ─────────────────────────────────┐          │
 │  the only contract that talks to 0x0100        │         │
 │  holds the 32 SOMI subscription bond           │         │
 │  fan-out bounded at 32 desks per firing        │         │
 └────────────┬──────────────────────┬────────────┘         │
              │ requestVerdict       │ onSettlement         │
              ▼                      │                      │
 ┌─ LucidBrain ──────────────────────┼────────────┐         │
 │  stage 1 → price-oracle committee  │            │        │
 │     cross-exchange median, source count,        │        │
 │     staleness stamp — guarded, not trusted      │        │
 │  stage 2 → LLM-inference committee              │        │
 │     probability the window closes above strike  │        │
 │     per-validator receipts recorded on chain    │        │
 └────────────┬──────────────────────┼────────────┘         │
              │ onVerdict            │                      │
              ▼                      ▼                      │
 ┌─ LucidDesk — one per user, non-custodial ──────┐         │
 │                                                 │        │
 │  PolicyLib.gate(policy, state, market,          │        │
 │                 verdict, book, stake, equity)   │        │
 │        │                        │               │        │
 │   Refusal.None            any other reason      │        │
 │        │                        │               │        │
 │        ▼                        ▼               │        │
 │   AiEdge / Maker          Refused(reason)       │        │
 │        │                  no trade, logged      │        │
 └────────┼────────────────────────────────────────┘        │
          └───────────────────────────────────────────────────
```

The same settlement firing also drives three things that are not about our own desks:
`LucidKeeper` runs DreamDEX's permissionless upkeep for the whole venue, `LucidRelay` redeems
pre-signed exits for anybody who queued one, and `LucidSeries` rolls a replacement window if the
venue's own scheduler has gone quiet.

---

## The eight contracts

| contract | responsibility |
| --- | --- |
| `LucidRouter` | The protocol's only subscriber to `0x0100`; decodes venue logs, fans out to desks, schedules wake-ups, holds the bond. |
| `LucidDesk` | One user's non-custodial desk: holds their tUSDC and outcome legs, executes under a mandate it cannot talk its way past. |
| `PolicyLib` | A pure, total, never-reverting function from (mandate, state, market, verdict, money) to one refusal reason. |
| `LucidBrain` | The two-stage committee wrapper: price first, then inference — every failure path still ends in a stored verdict. |
| `LucidFactory` | Clones desks (ERC-1167), registers them with the router, and holds the publish/follow copy-trade graph. |
| `LucidKeeper` | Runs the venue's five permissionless upkeep calls for every settled market, not only ours. Takes no fee, holds no funds. |
| `LucidRelay` | Universal auto-redeem: anybody signs an EIP-712 exit once, and it is executed for them after settlement. No owner. |
| `LucidSeries` | Failover market creation — rolls our own window when DreamDEX's scheduler stops rolling theirs. |

`PolicyLib` is an internal library compiled into `LucidDesk`; the other seven are deployed
separately. Source is in [`contracts/src`](contracts/src). The natspec carries the reasoning —
most of the non-obvious constants in this codebase are there because something measured on Shannon
said so, and each one says which measurement.

---

## How one window flows

1. DreamDEX rolls a new window. `BinaryMarketsModule` emits `MarketCreated`.
2. The reactivity precompile runs `LucidRouter.onEvent` as a synthetic transaction **in the same
   block**. No cron, no worker, no listener of ours.
3. The router decodes the log, ignores markets from other venues, emits `MarketSeen`, and asks each
   armed desk's `preCheck` whether it wants the window. This costs nothing but gas — no committee
   is paid to tell a desk what its own mandate already knows.
4. If at least one desk wants it, the router books a `Schedule` one-shot part-way into the window
   (`decisionPointBps`, default 5,000 — halfway) rather than asking immediately. These windows
   settle against the price they *opened* at, so at `tradingStart` spot equals strike and "will it
   close above the strike" is a question with no content. A committee asked an empty question
   answers 50, which is exactly what the first live run produced, three validators agreeing on
   nothing. Waiting lets spot move away from the strike so there is a real distance to reason about.
5. At the decision point the router calls `LucidBrain.requestVerdict`, splitting the fee across the
   desks that will actually pay it, and refusing outright if the window has less time left than the
   brain's self-measured `requiredSlack()`.
6. **Stage one**: the brain asks a validator committee for spot through Somnia's on-chain
   price-oracle agent. It gets one reading per validator, each with a source count and an age, and
   discards any that is stale or thin before taking the median. Even the input never passes through
   a server of ours.
7. **Stage two**: with spot in hand, the brain asks the LLM-inference committee for the probability
   that the window closes above the strike. Three validators, `Threshold` consensus, per-validator
   receipts stored on chain. The result is reduced to a median and a count of who answered.
8. The verdict goes back through the router to every desk holding the window. `PolicyLib.gate` runs
   in a fixed order — mandate, market, risk, committee answer, evidence, money — and the first
   failure wins. Pass and the desk trades. Fail and it emits `Refused(reason)` with the committee's
   probability and the book's, and stops.
9. The router had already booked a second `Schedule` one-shot for `expiry + 5s`. When it fires the
   desk finalizes the market if nobody has, redeems what pays, books the P&L, moves its high-water
   mark and loss streak, and the keeper, relay and series hooks run behind it.

Every step above is a transaction on Somnia. The only thing off-chain in this repository is a
read-only CLI, a read-only evaluation harness, and this file.

---

## The two strategies

**`AiEdge` — takes liquidity.** Compares the committee's probability against the book-implied
probability and trades the difference, sized in proportion to it: a 38-point disagreement stakes
38% of equity, a 3-point one stakes 3%, and anything below `minEdgeBps` is `Refused(LowEdge)`. If
no side of the book quoted at all, the desk gets `Refused(NoBook)` rather than a fabricated default
— an empty book is the absence of a market price, not a market price of zero, and inventing one
would manufacture a large edge against a number nobody quoted.

**`Maker` — provides liquidity.** Mints a complete set (`mintSet`: collateral in, one UP and one
DOWN leg out), which needs **no counterparty at all**, then rests both legs `POST_ONLY` around the
committee's fair value. This is the strategy that works on this venue, because the books here are
usually empty — most live windows have zero trades. `Maker` is deliberately exempt from the
`NoBook` refusal: an empty book is the case it exists for.

---

## Quickstart

Foundry and Node 20+. Nothing else.

All four blocks run from the repository root.

```bash
# 1. dependencies (forge-std + OpenZeppelin; Somnia's reactivity contracts are vendored in-tree)
bash contracts/setup.sh

# 2. the test suite — no network, no key
(cd contracts && forge test)

# 3. audit the live deployment — no wallet, no key, no funds
bash contracts/verify-onchain.sh

# 4. the typed client and CLI — every read command works without a key
(cd kit && npm install && npm run build && npx lucid status)
```

Deploying your own instance needs a funded key and at least 36 SOMI plus gas, because the router has
to clear the 32 SOMI subscription floor before it can subscribe to anything:

```bash
cp contracts/.env.example contracts/.env   # put a throwaway testnet key in it
bash contracts/deploy.sh                   # writes contracts/deployed.json
node scripts/sync-addresses.mjs            # refreshes the tables in this file and JUDGES.md
```

---

## Live deployment

<!-- addresses:start -->
<!-- Written by scripts/sync-addresses.mjs from contracts/deployed.json. Do not edit by hand. -->

| contract | address |
| --- | --- |
| `LucidRouter` | [`0x6aE21a20444141552648C1f8443bAf171BCCcB99`](https://shannon-explorer.somnia.network/address/0x6aE21a20444141552648C1f8443bAf171BCCcB99) |
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

---

## Configuration

| setting | value |
| --- | --- |
| chain | Somnia Shannon, id `50312` |
| RPC | `https://api.infra.testnet.somnia.network` |
| explorer | `https://shannon-explorer.somnia.network` |
| market indexer | `https://dev.smk.somnia.host/v1/graphql` |
| collateral | tUSDC `0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E`, 6 decimals |
| venue module | `BinaryMarketsModule 0x3ecC694Cef705358864a646142ac17A90E29e388` |
| agent platform | `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776` |
| LLM inference agent | `12847293847561029384` (Qwen3-30B) |
| price oracle agent | `9911223344556677889` (Shannon only) |
| committee | 3 validators, `Threshold` consensus, 300 s timeout |
| verdict cost | 0.36 SOMI — 0.12 for the price stage, 0.24 for the inference stage |
| toolchain | solc 0.8.30, optimizer on, 200 runs, evm `cancun` |

Deploy-time environment, read from `contracts/.env`:

| variable | default | what it does |
| --- | --- | --- |
| `PRIVATE_KEY` | — | Deployer. Throwaway testnet key only. |
| `RPC` | Shannon | Node the deploy talks to. |
| `ROUTER_FUNDING` | `33ether` | Must clear the 32 SOMI subscription floor with room to spare. |
| `BRAIN_FUNDING` | `3ether` | Committee float, roughly eight verdicts. |
| `MARKET_CREATOR` | our creator | The `MarketCreator` `LucidSeries` rolls when the venue goes quiet. |

Owner-only knobs that need no redeploy: the committee's system prompt and size
(`LucidBrain.setPrompt` / `setCommittee`), the price feed per asset (`setFeed`, including which
agent reads it), the staleness and source-count guards (`setFeedGuards`), where in the window the
committee is asked (`LucidRouter.setDecisionPoint`), and the failover mode
(`LucidSeries.setMode`). Prompt quality is the one part of this system that improves with
observation, so it lives in storage rather than in code.

---

## Honest limits

**Windows shorter than the committee round trip can never be traded.** The brain measures its own
latency and publishes `requiredSlack()` — twice the observed round trip of both stages plus thirty
seconds of execution room, floored at 90 seconds and capped at 600. A window with less time left
than that is refused before anything is spent. The venue's 60-second cadence is therefore
permanently untradeable: the floor alone exceeds the whole window. A desk may still *allow* the
60-second bit in its mandate, and it will consider and refuse every one of those windows with
`WindowTooShort`. That is documented rather than silently masked, and `lucid-kit`'s
`describePolicy` says so out loud.

**Venue-wide upkeep costs about 8 SOMI per hour on this testnet.** With the keeper attached the
router schedules a settlement one-shot for every market the venue creates — 40 markets per 15
minutes observed, at roughly 0.017 SOMI per handler firing. That is a public good we pay for out of
the same bond that runs our own desks, and on a testnet float it is a real constraint, so the
keeper runs in bursts rather than continuously. Nothing about the mechanism is bursty; the funding
is.

**The router must hold 32 SOMI, and stops scheduling below it.** `SomniaExtensions` checks
`address(this).balance >= 32 ether` on whichever contract calls `subscribe`, and it re-checks on
every subscription — including each per-settlement one-shot. It is a floor to stay above for as
long as the protocol runs, not a one-time deposit. The router refuses to spend below
`SUBSCRIPTION_FLOOR + fee` and emits `Skipped(ROUTER_FLOAT)`, because dipping under would silently
disarm every subscription it owns, including wake-ups already promised to positioned desks. This is
also why there is one router rather than a subscription per desk: per-desk subscriptions would lock
32 SOMI per user, which is not a product.

**The price feed is a different series from DreamDEX's settlement oracle.** Stage one reads
Somnia's on-chain price-oracle agent; the venue settles against its own Prophecy Oracle. Those two
numbers are close but they are not the same series, so there is basis risk between what the
committee is shown and what the window actually settles on. The mitigation is that the feed is
storage, not a constant: `setFeed` repoints any asset at a different source or a different agent,
per asset, in one owner transaction, with no redeploy that would orphan a stored verdict.

**`Continuous` series mode costs about 34 SOMI per hour and is not the operating mode.** A rolled
window costs the market creator about 2.8 SOMI (two oracle questions plus the resolve reserve) and
measures 61.6M gas. Twelve windows an hour on the 300-second cadence is roughly 34 SOMI an hour,
816 a day — no testnet float survives that. `Continuous` is implemented properly, because full
independence from the venue's scheduler is a real thing to want, but the deployment runs in
`Failover`, which spends nothing at all while DreamDEX's own scheduler is healthy and starts only
when no window of the watched cadence has appeared for `stalenessSeconds`.

**Testnet only.** Shannon, chain 50312, tUSDC from a faucet. The contracts have not been audited,
and neither have the DreamDEX binary contracts they sit on — the published Hacken audit covered the
spot venue only. Nothing here should touch real money.

Three more, smaller:

- One firing considers at most 32 armed desks (`MAX_FANOUT`) and one leader at most 32 followers.
  Beyond that the tail is skipped by name, not silently dropped.
- `redeemFor` with a contract signature (EIP-1271) has never been tested on Shannon, so `LucidRelay`
  is a pre-signed-EOA-exit relay in practice. See [CLAIMS.md](CLAIMS.md).
- The committee's measured behaviour is whatever [EVAL.md](eval/EVAL.md) says it is, including where
  that is a negative result. This repository does not claim edge it has not measured.

---

## Repository

| path | what it is |
| --- | --- |
| `contracts/` | Foundry project: the eight contracts, the suite, deploy and verification scripts. |
| `kit/` | `lucid-kit` — typed viem client and the `lucid` CLI. Read commands need no key. |
| `eval/` | Pre-registered, read-only scoring harness for the committee. Signs nothing. |
| `scripts/sync-addresses.mjs` | Regenerates the address tables in this file and `JUDGES.md`. |

## Further reading

- [JUDGES.md](JUDGES.md) — review this repository in five minutes, with no wallet and no key.
- [CLAIMS.md](CLAIMS.md) — every claim made here, with its evidence tier and how to check it.
- [MOCKS.md](MOCKS.md) — exactly where the line between real and simulated runs.
- [EVAL.md](eval/EVAL.md) — what the committee actually scored, and against which controls.
- [SDK_FEEDBACK.md](SDK_FEEDBACK.md) — three blocking issues, seven sharp edges and three
  documentation gaps found building this, each with a reproduction.
- [kit/README.md](kit/README.md) — client and CLI reference.

## License

MIT. See [LICENSE](LICENSE).
