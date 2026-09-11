# Proof

**Walkthrough:** https://youtu.be/b-o_-8mEyKU

Every claim on this page is a link to something on a public chain, or a command you can run against
it. Nothing here is a screenshot and nothing here is a promise.

- **Chain** — Somnia Shannon testnet, id `50312`
- **Explorer** — <https://shannon-explorer.somnia.network>
- **RPC** — `https://api.infra.testnet.somnia.network`
- **Indexer** — `https://dev.smk.somnia.host/v1/graphql` (DreamDEX's public Hasura, unauthenticated)

Everything below was re-read off the chain on **2026-09-07, between 03:40 and 05:00 UTC**, head block
≈ 481 841 000. Addresses come from [`contracts/deployed.json`](contracts/deployed.json), which is the
authority; where anything disagrees with it, `deployed.json` and the chain are right.

The deployment moved on 2026-09-07 at 03:42 UTC: the desk implementation and the factory were
replaced, and each owner's desk was re-cloned from the new implementation. Router, brain, keeper,
relay and series are the same contracts they have been throughout. Transactions in this document that
belong to a **previous desk clone are labelled as such** — they are immutable and they still decode
exactly as described, but the desk that produced them is not the desk running now.

Related documents, not repeated here: [README.md](README.md) · [CLAIMS.md](CLAIMS.md) ·
[MOCKS.md](MOCKS.md) · [SDK_FEEDBACK.md](SDK_FEEDBACK.md) · [eval/EVAL.md](eval/EVAL.md).

---

## 1. The addresses

Runtime-code sizes are the ones `eth_getCode` returned during the run of `verify-onchain.sh`
reproduced in [section 13](#13-reproduce-it-yourself).

| what | address | one line |
| --- | --- | --- |
| `LucidRouter` | [`0x6aE21a20444141552648C1f8443bAf171BCCcB99`](https://shannon-explorer.somnia.network/address/0x6aE21a20444141552648C1f8443bAf171BCCcB99) | Handles every reactivity callback: wakes on the venue's `MarketCreated`, books the decision and settlement one-shots, fans out to armed desks. 24 112 bytes. |
| `LucidWatch` | [`0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C`](https://shannon-explorer.somnia.network/address/0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C) | Owns the venue's `MarketCreated` subscription on a bond of its own and names the router as its handler. Why it exists: [section 12](#12-the-router-bricked-itself-and-what-replaced-it). 3 626 bytes. |
| `LucidBrain` | [`0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25`](https://shannon-explorer.somnia.network/address/0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25) | Two-stage question to Somnia's on-chain agent committees: price first, then the probability verdict. 20 621 bytes. |
| `LucidDesk` (clone implementation) | [`0xa659b03e2349559f2d56D17F246e66e79467c17e`](https://shannon-explorer.somnia.network/address/0xa659b03e2349559f2d56D17F246e66e79467c17e) | The desk logic every desk clone delegates to: mandate enforcement, sizing, order placement, cancellation, settlement booking. 14 940 bytes. |
| `LucidFactory` | [`0x9c1EF0C429f1F88e8247f3539DeF8a1f8FCCEb84`](https://shannon-explorer.somnia.network/address/0x9c1EF0C429f1F88e8247f3539DeF8a1f8FCCEb84) | Mints ERC-1167 desk clones, one per owner address, and registers them with the router. 4 943 bytes. |
| `LucidKeeper` | [`0x4757599dC9A5a089270373a66BEeeD6592788707`](https://shannon-explorer.somnia.network/address/0x4757599dC9A5a089270373a66BEeeD6592788707) | Built to run the venue's permissionless upkeep (`finalizeMarket`, `releasePool`, `syncSettlement`, `pokeOracle`) for every market, not only ours. No successful call on chain yet — see [section 11](#11-honest-limits). 3 736 bytes. |
| `LucidRelay` | [`0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A`](https://shannon-explorer.somnia.network/address/0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A) | Queue of signed redemption authorisations anyone may drain, so a winner does not have to be online to be paid. 6 565 bytes. |
| `LucidSeries` | [`0x747fF3a7A6FE4912c96dCe7faA711dCB6fbd1CE4`](https://shannon-explorer.somnia.network/address/0x747fF3a7A6FE4912c96dCe7faA711dCB6fbd1CE4) | Failover: watches the venue's cadence and rolls a window on our own `MarketCreator` if the venue's scheduler stops. 5 452 bytes. |
| Desk `AiEdge` | [`0x822548990ce81b626a3c3684B0c85f2fd9EC9Fa7`](https://shannon-explorer.somnia.network/address/0x822548990ce81b626a3c3684B0c85f2fd9EC9Fa7) | Live desk, ERC-1167 clone (45 bytes), owner [`0xc84C24F7…`](https://shannon-explorer.somnia.network/address/0xc84C24F751c686568A907650FD59b1a3AC1a5E67). Takes the book when the committee disagrees with it. Holds 5 000.000000 tUSDC. |
| Desk `Maker` | [`0x3ffbB71aec0D5459677021Ad888195042eDA4AA2`](https://shannon-explorer.somnia.network/address/0x3ffbB71aec0D5459677021Ad888195042eDA4AA2) | Live desk, a *different* owner [`0x3F396B9e…`](https://shannon-explorer.somnia.network/address/0x3F396B9e1E203d95BA5Be32f4115eaa435cb9dde) — the factory allows one desk per address. Mints a complete set and quotes both sides. Holds 5 000.200000 tUSDC. |
| `MarketCreator` (ours) | [`0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2`](https://shannon-explorer.somnia.network/address/0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2) | DreamDEX's own creator contract, deployed and owned by an ordinary account of ours, running series 1 (BTC, 300 s) on our own venue. 13 903 bytes. |

The four transactions that put the current deployment on chain, all on 2026-09-07:

| UTC | block | transaction | what |
| --- | --- | --- | --- |
| 03:42:25 | 481 793 828 | [`0x33127ac5…`](https://shannon-explorer.somnia.network/tx/0x33127ac5be9fd72f575220d275ddd6a13d71c7be279df3ddcc46edab10f8ccee) | `LucidDesk` implementation deployed. |
| 03:42:34 | 481 793 917 | [`0x5bfdccd2…`](https://shannon-explorer.somnia.network/tx/0x5bfdccd2a299f302fd47f717bcf2c7647e631e39dd8c9b1af49528d22079ec32) | `LucidFactory` deployed against it. |
| 03:42:40 | 481 793 979 | [`0x5eb60957…`](https://shannon-explorer.somnia.network/tx/0x5eb60957b2bc16edecbdb14238bc2f1fa903d25bdca86d1bb1a12f2a1c5df481) | The `AiEdge` desk cloned and registered. |
| 03:42:50 | 481 794 074 | [`0x8ce5155d…`](https://shannon-explorer.somnia.network/tx/0x8ce5155dd65063ca7099358cbebb3eb59896cd8c355496f00d806335e875a616) | The `Maker` desk cloned and registered, by its own separate owner. |

Third-party addresses this document refers to:

| what | address |
| --- | --- |
| DreamDEX `BinaryMarketsModule` | [`0x3ecC694Cef705358864a646142ac17A90E29e388`](https://shannon-explorer.somnia.network/address/0x3ecC694Cef705358864a646142ac17A90E29e388) |
| Somnia agent platform (`IAgentRequester`) | [`0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`](https://shannon-explorer.somnia.network/address/0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776) |
| Somnia reactivity precompile | `0x0000000000000000000000000000000000000100` |
| Settlement collateral `tUSDC` (6 decimals) | [`0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E`](https://shannon-explorer.somnia.network/address/0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E) |
| `OutcomeToken6909` | [`0xb52C5934113AF5c0Bb20eb3c72290c8215F755b9`](https://shannon-explorer.somnia.network/address/0xb52C5934113AF5c0Bb20eb3c72290c8215F755b9) |
| DreamDEX venue registry (`MarketsCore`) | [`0x2802504314685D89bF6C992CA5a8e7cC78bc0294`](https://shannon-explorer.somnia.network/address/0x2802504314685D89bF6C992CA5a8e7cC78bc0294) |
| DreamDEX `MarketCreator` factory | [`0xE6bEE93cE87c9E6e62aCb621caa7832EE47b4F6B`](https://shannon-explorer.somnia.network/address/0xE6bEE93cE87c9E6e62aCb621caa7832EE47b4F6B) |
| Venue the router serves | `0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f` |
| Our own venue | `0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581` |

### Source verification

**All eight Lucid contracts are source-verified on Blockscout right now.** Do not take our word for
it. One command per address, no key:

```bash
curl -s https://shannon-explorer.somnia.network/api/v2/smart-contracts/<address> \
  | python -c "import json,sys;d=json.load(sys.stdin);print(d['is_verified'], d['name'], d['compiler_version'], d['verified_at'])"
```

Observed at 2026-09-07 04:50 UTC:

| contract | `is_verified` | verified at |
| --- | --- | --- |
| `LucidRouter` | `True` — `LucidRouter` | 2026-09-06T20:12:04Z |
| `LucidBrain` | `True` — `LucidBrain` | 2026-09-06T20:11:45Z |
| `LucidKeeper` | `True` — `LucidKeeper` | 2026-09-06T20:12:28Z |
| `LucidRelay` | `True` — `LucidRelay` | 2026-09-06T20:12:31Z |
| `LucidSeries` | `True` — `LucidSeries` | 2026-09-06T20:12:34Z |
| `LucidDesk` (implementation) | `True` — `LucidDesk` | 2026-09-07T03:43:38Z |
| `LucidFactory` | `True` — `LucidFactory` | 2026-09-07T03:44:17Z |
| `LucidWatch` | `True` — `LucidWatch` | 2026-09-08T14:41:19Z |

All eight report compiler `v0.8.30+commit.73712a01` with the optimizer at 200 runs. An earlier
version of this page recorded `LucidDesk` and `LucidFactory` as unverified, because at that moment
they were; the two verifications above landed shortly after the redeploy. Re-run the command — it is
the authority, not the paragraph.

The two desks are ERC-1167 minimal proxies (45 bytes each). The explorer resolves both to
implementation [`0xa659b03e…`](https://shannon-explorer.somnia.network/address/0xa659b03e2349559f2d56D17F246e66e79467c17e)
and reports them verified through it, which is why verifying that one address covers both:

```bash
curl -s https://shannon-explorer.somnia.network/api/v2/addresses/0x3ffbB71aec0D5459677021Ad888195042eDA4AA2 \
  | python -c "import json,sys;d=json.load(sys.stdin);print(d['is_verified'], d['proxy_type'], d['implementations'])"
# True eip1167 [{'address_hash': '0xa659b03e2349559f2d56D17F246e66e79467c17e', 'name': 'LucidDesk'}]
```

The `MarketCreator` is DreamDEX's contract, deployed through their factory — its source is theirs,
and it is not verified on this explorer.

---

## 2. The loop, proven end to end

One window: market `0x…0159cb`, ETH, 300 seconds, on the venue the router serves. Six transactions,
in order, all on chain, all on the current deployment.

| # | block | UTC | transaction | what happened |
| --- | --- | --- | --- | --- |
| 1 | 481 804 366 | 04:00:00 | [`0xde6c833e…`](https://shannon-explorer.somnia.network/tx/0xde6c833efd83e6ffbb1379e46811534d080fbf343ebded965167934faf2aa384) | The venue creates the window. `BinaryMarketsModule` emits `MarketCreated` with `topics[1] = 0x…0159cb`, and three sibling markets in the same transaction. |
| 2 | **481 804 366** | 04:00:00 | [`0x6fc665db…`](https://shannon-explorer.somnia.network/tx/0x6fc665db5091d165585f8ad61e6407ae83fcd6d45432e1c0b314c21445b32050) | **Same block.** A validator runs the router's handler as a synthetic transaction — `from` and `to` are both the router, 2 740 027 gas, three logs. `MarketSeen(0x…0159cb, intervalSec 300, ETH)`, `DecisionScheduled(tsMillis 1788753750000, subscriptionId 16613080)` for 04:02:30 — the halfway point of a window that runs 04:00:05 → 04:05:05 — and `SettlementScheduled(tsMillis 1788753905000, subscriptionId 16613081)` for 04:05:05. |
| 3 | 481 805 866 | 04:02:30 | [`0xe906edfb…`](https://shannon-explorer.somnia.network/tx/0xe906edfb19c4bae0f748baa1949101b0b3f6a9449e44d2d25ec773c95e41fb85) | The decision one-shot fires — again `from == to == router`, 3 620 925 gas, and it carries two windows at once. For `0x…0159cb` the router emits `VerdictRequested(fee 0.36 SOMI, deskCount 2)` and two `Debited(desk, 0.19 SOMI)` lines, one per desk; the brain emits `PriceRequested(requestId 13416423, deposit 0.12 SOMI)`. |
| 4 | 481 805 869 | 04:02:30 | [`0x1830ef33…`](https://shannon-explorer.somnia.network/tx/0x1830ef332ff751df76b7e65ce3dc789008f58cb4f2bfa6881c718a74a72e2868) | **The price committee answers.** `PriceReceived(spot 249686, used 3, prices [249686, 249686, 249686])` — ETH 2 496.86, three validator readings, all agreeing — and `LatencyObserved(stage 1, observed 0 s)`. The brain immediately buys stage two: `VerdictRequested(requestId 13416425, size 3, threshold 2, deposit 0.24 SOMI)`. Sent by a validator account, `to` the agent platform. |
| 5 | 481 805 874 | 04:02:30 | [`0xec22854e…`](https://shannon-explorer.somnia.network/tx/0xec22854e1a2619ade09453233f0d3dfbe20eb6185a73ceca869daae40927e010) | **The inference committee answers**, and both policy gates decide. `VerdictReceived(probUpBps 5000, responded 3, agreed 3, ok true, scores [50, 50, 50])`, `LatencyObserved(stage 2, observed 0 s)` — five blocks from question to answer. This is [hero #1](#3-hero-1--one-transaction-two-mandates-two-outcomes). |
| 6 | 481 807 415 | 04:05:05 | [`0xc50c6095…`](https://shannon-explorer.somnia.network/tx/0xc50c60958e32f6beca5c63c992294c168cb7e64b403a101f8a1553deef6063db) | The settlement one-shot fires (`from == to == router`), 9 185 925 gas, 38 logs. For each of the two windows it carries: `OrdersCancelled(count 2)` — the desk pulling its own resting legs back out of the venue — then the redemption, then `Settled(pnl 0.000000, equityAfter 5000.200000)`. |

The two decision one-shots are gone now, as consumed one-shots should be:

```bash
curl -s -X POST https://api.infra.testnet.somnia.network -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"somnia_reactivityGetSubscriptionInfo","params":["0xfda77f"]}'
# {"jsonrpc":"2.0","id":1,"result":[]}
```

---

## 3. Hero #1 — one transaction, two mandates, two outcomes

[`0xec22854e1a2619ade09453233f0d3dfbe20eb6185a73ceca869daae40927e010`](https://shannon-explorer.somnia.network/tx/0xec22854e1a2619ade09453233f0d3dfbe20eb6185a73ceca869daae40927e010)

Block 481 805 874 · 04:02:30 UTC · status `1` · 4 134 265 gas · `from` [`0x05f1fE2D…`](https://shannon-explorer.somnia.network/address/0x05f1fE2DDF9B65576D3165E37C6A60e6c5Ba93De),
a Somnia validator delivering the committee's answer · `to` the agent platform `0x037Bb9C7…`, which
calls back into `LucidBrain`, which calls the router, which fans out. One transaction, twenty-seven
logs. Decoded, in order:

| # | emitter | event | value |
| --- | --- | --- | --- |
| 0 | `LucidBrain` | `LatencyObserved` | stage 2, observed 0 s, EMA 0 s |
| 1 | `LucidBrain` | `VerdictReceived` | market `0x…0159cb`, requestId 13416425, `probUpBps 5000`, responded 3, agreed 3, `ok true`, `scores [50, 50, 50]` |
| 2 | `AiEdge` | `Considered` | market `0x…0159cb`, 300 s, ETH |
| 3 | `AiEdge` | `VerdictReceived` | `probUpBps 5000`, `pBookBps 65535`, responded 3 |
| **4** | **`AiEdge`** | **`Refused`** | **reason `NoBook` (15)**, `probUpBps 5000`, `pBookBps 65535` |
| 5–6 | `Maker` | `Considered`, `VerdictReceived` | the same market, the same instant, the same verdict |
| 7 | `tUSDC` | `Approval` | `Maker` → the market's pool `0x9cb6f4d5…` |
| 8–9 | `OutcomeToken6909` | `OperatorSet` | `Maker` approves the pool and the module to move its legs |
| 10 | `tUSDC` | `Transfer` | `Maker` → pool, **5.000000 tUSDC** |
| 11–12 | `OutcomeToken6909` | `Transfer` ×2 | **from `0x0`** to `Maker`: 5.000000 of the YES id and 5.000000 of the NO id — one complete set minted, no counterparty involved |
| 13–17 | pool `0x9cb6f4d5…` | escrow and order lifecycle | the first leg reaching the venue |
| **18** | **`Maker`** | **`Executed`** | `SELL_YES` at price `520000` (0.520), quantity `5000000` (5.000000 contracts), orderId 166020696663385998780 |
| 19–22 | pool `0x9cb6f4d5…` | escrow and order lifecycle | the second leg |
| **23** | **`Maker`** | **`Executed`** | `SELL_NO` at price `480000` (0.480), quantity `5000000`, orderId 36893488147419137469 |
| 24–26 | agent platform | request settled, per-validator receipts | |

`pBookBps 65535` is `LucidTypes.BOOK_UNOBSERVED` — the sentinel for *there was no book*, which sits
outside the 0–10000 probability range on purpose so it can never be mistaken for a price somebody
quoted.

Same market. Same block. Same committee answer, delivered to both desks in the same call frame.
`AiEdge`'s mandate needs a market price to measure an edge against, finds none, and refuses by name.
`Maker`'s mandate does not need a counterparty at all: it mints a complete set out of collateral and
rests **both** legs, 0.480 bid and 0.520 ask, around the committee's 50 %. The model proposes; each
desk's own policy contract disposes.

[`0x5e170dbb…`](https://shannon-explorer.somnia.network/tx/0x5e170dbb00608b70eedaeca00c5cea4772b1b28206e5dbab52562d65c3bc5f18)
(block 481 799 883, 03:52:31, 5 579 887 gas) is the same shape on the same pair of desks, and it is
the window whose quote a counterparty actually took — see [section 4](#4-hero-2--a-settlement-booked-honestly).

**The earlier clone.** [`0xa4bdae59…`](https://shannon-explorer.somnia.network/tx/0xa4bdae5926dbe8d0477bc65ae52e39d480c7cdb748f8873190ef8ecca2d0c1ea)
(block 481 583 935, 2026-09-06 21:52:31, 7 544 372 gas, twenty-three logs) is the first transaction
that ever showed this shape, and it still decodes exactly as described: the committee answered
`probUpBps 0` with `scores [0, 0, 0]`, the `AiEdge` clone `0x86D17016…` refused with `NoBook`, and
the `Maker` clone `0xd44B2e95…` minted a set and got a single `SELL_NO` leg up at 0.001 after the
other leg emitted `Refused(VenueRejected)`. Those are **superseded desk clones** — the desks running
today are the ones in [section 1](#1-the-addresses) — and that transaction is kept here because it is
immutable evidence of the fan-out, not because it describes the current desks.

---

## 4. Hero #2 — a settlement booked honestly

[`0x67c42a3edf14e32586f46ea528346859ff8ed015a3d9f4b8ea901632b7d0ff9a`](https://shannon-explorer.somnia.network/tx/0x67c42a3edf14e32586f46ea528346859ff8ed015a3d9f4b8ea901632b7d0ff9a)

Block 481 801 417 · 03:55:05 UTC · status `1` · 8 426 015 gas · `from` and `to` both the router —
a validator-executed reactivity handler, the settlement one-shot booked when the windows were seen.

| # | emitter | event | value |
| --- | --- | --- | --- |
| 6 | `Maker` | `OrdersCancelled` | market `0x…0159af`, **count 1** — the desk pulling its own resting leg back out of the pool before it redeems anything |
| 7–8 | `OutcomeToken6909` | `Transfer` ×2 | the returned leg, then the burn |
| 9 | `tUSDC` | `Transfer` | pool → `Maker`, **5.000000** |
| 11 | `BinaryMarketsModule` | redemption | market `0x…0159af`, owner `Maker` |
| **12** | **`Maker`** | **`Settled`** | market `0x…0159af`, **`pnl = +0.000000`**, `equityAfter = 5005.200000` |
| **17** | **`Maker`** | **`Settled`** | market `0x…0159b0`, **`pnl = -5.000000`**, `equityAfter = 5000.200000` |

Two windows closed in one transaction, and they are the two cases the settlement path has to tell
apart.

`0x…0159af` is the ordinary one. One leg was still resting, the desk cancelled it, the returned leg
was burned back into collateral, 5.000000 tUSDC came home, and the window booked **`+0.000000`** —
the desk got back exactly what it put in.

`0x…0159b0` is the interesting one, and it is the first time anything on this venue traded with us.
The desk had rested **both** legs on it at 03:52:31 in
[`0x5e170dbb…`](https://shannon-explorer.somnia.network/tx/0x5e170dbb00608b70eedaeca00c5cea4772b1b28206e5dbab52562d65c3bc5f18),
and a third party lifted them: 2.600000 tUSDC arrived from the pool one second later in
[`0xa9cd5fec…`](https://shannon-explorer.somnia.network/tx/0xa9cd5fec1ffe759d4f087b84a560143d180b8ff2663687a47252dde4b9856795)
and another 2.600000 eight seconds after that in
[`0xd003bb3c…`](https://shannon-explorer.somnia.network/tx/0xd003bb3cba2afa70176334ad4dbe96ad44a4126e817b8bf3a6d4081495119a70),
both taken by an ordinary account that has nothing to do with this project. By expiry the desk held
neither leg and had nothing to cancel and nothing to redeem — which is why there is no
`OrdersCancelled` and no redemption on that row — so `pnl = _free() − before − cost` booked the
5.000000 the mint had cost as a loss.

Read those two numbers together, not apart. Across the whole run the desk's collateral went
**5 000.000000 → 5 000.200000**, and every bit of that movement is the 5.200000 those two fills paid
for a set that cost 5.000000. The per-window `pnl` cannot see it, because the money arrived before
the settlement snapshot was taken; that is a real limitation of the accounting and it is written up
in [section 11](#11-honest-limits). Twelve windows is not a track record and there is no P&L claim
anywhere in this repository — see [CLAIMS.md](CLAIMS.md) § NOT CLAIMED.

The desk's current collateral is readable at any time:

```bash
cast call 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E 'balanceOf(address)(uint256)' \
  0x3ffbB71aec0D5459677021Ad888195042eDA4AA2 \
  --rpc-url https://api.infra.testnet.somnia.network
# 5000200000  (6 decimals)
```

**The earlier clone.** [`0x4d4e9f0d…`](https://shannon-explorer.somnia.network/tx/0x4d4e9f0d8ea3ca8412cadf1d9a749c55acb52c5720d8b742d15387a000d4d014)
(block 481 585 467, 2026-09-06 21:55:05, 2 691 006 gas) is the first loss this protocol ever booked
on chain: two `Settled` rows on the **superseded** `Maker` clone `0xd44B2e95…`, one at
`pnl = 0.000000` and one at `pnl = -5.000000`, equity 5005.100000 → 5000.100000. It still resolves
and still decodes as described. It is also, as it turned out, an instance of the defect written up in
[section 5](#5-the-defect-the-desks-found-live) rather than a real trading loss — which is exactly
why it is still here.

---

## 5. The defect the desks found live

A protocol that only shows the runs where nothing went wrong is showing a demo. This one found a real
accounting defect in its own settlement path, on chain, with money, and the fix is in the deployed
bytecode.

**The symptom.** A `Maker` clone of the previous implementation,
[`0x85e34174…`](https://shannon-explorer.somnia.network/address/0x85e34174fcd39c1c717724b3691d3e34ff265149),
was armed at 02:38:15 on 2026-09-07 with 5 000.000000 tUSDC. It quoted six windows and every single
one of them settled at **`pnl = -5.000000`**:

| UTC | block | transaction | booked |
| --- | --- | --- | --- |
| 02:45:05 | 481 759 426 | [`0xd3219ea0…`](https://shannon-explorer.somnia.network/tx/0xd3219ea0a4d1fb003fcc9d7b1bb549a80625a87ec46cf354a552f32155a05aef) | `0x…015900` −5.000000 → 4995.000000 · `0x…0158ff` −5.000000 → 4990.000000 |
| 02:50:05 | 481 762 426 | [`0x588ed9ff…`](https://shannon-explorer.somnia.network/tx/0x588ed9ff4db4cdb046e5a01593267c643fbdeaeb06134afa827b30fc9a201af6) | `0x…01590c` −5.000000 → 4985.000000 · `0x…01590b` −5.000000 → 4980.000000 |
| 02:55:05 | 481 765 425 | [`0x19992789…`](https://shannon-explorer.somnia.network/tx/0x199927896a07b8185df2556c93453d0b7dc86e2f27269312481a40390585f4b9) | `0x…015918` −5.000000 → 4975.000000 · `0x…015917` −5.000000 → 4970.000000 |

Equity **5 000.000000 → 4 970.000000**, six for six, the whole stake every time, with the committee
answering across a range of values. A strategy that loses exactly its entire mint on every window
regardless of the outcome is not losing; it is not measuring.

**The cause.** A resting order escrows its leg with the pool. The maker mints a complete set and
rests both legs, so between placement and expiry the desk's own balance of both outcome tokens is
zero — the pool is holding them. The old `onSettlement` went straight to redemption, `_redeemLeg`
found nothing to redeem, and

```solidity
int256 pnl = int256(_free()) - int256(before) - int256(uint256(h.cost));
```

reduced to `−cost` every time. The loss was not a market outcome. It was the desk failing to ask for
its own inventory back before valuing it.

**The fix**, in `contracts/src/LucidDesk.sol`, is that the cancel now comes first and the snapshot
comes before the cancel:

```solidity
uint256 before = _free();
_cancelResting(m.marketId, m.pool);
```

`_cancelResting` walks the desk's own order ids for that window, calls `cancelOrder` on each inside a
`try`, and emits `OrdersCancelled(marketId, count)` when at least one came back. Every failure is
swallowed on purpose: a cancel legitimately fails when the order already filled, already expired, or
was swept by the venue's own `cancelExpiredOrders`, and none of those is an error. The absence of the
event is itself readable — a settlement with no `OrdersCancelled` beside it is a settlement where
nothing came back.

**The evidence it works.** In the run in [section 7](#7-the-run) every window where a leg was still
resting settled at **`+0.000000`** with an `OrdersCancelled` line beside it, and the only `-5.000000`
in the whole run is `0x…0159b0`, where the legs really were gone because somebody bought them. Same
strategy, same venue, same cadence, same size.

Pinned in the suite, so it cannot come back:

```bash
cd contracts && forge test --match-contract LucidDeskTest --match-test cancel -vv
# test_a_settling_maker_cancels_both_legs_before_it_redeems_anything
# test_a_cancel_that_reverts_does_not_stop_the_settlement
# test_a_taker_order_that_rested_is_cancelled_too
```

---

## 6. The desk that halted itself

This is the part worth reading twice, because it is what the safety spine is for and it fired against
a real defect rather than a contrived one.

Nobody stopped the desk in [section 5](#5-the-defect-the-desks-found-live). **It stopped itself, six
windows in, before anyone had looked at it.**

Its mandate carried `maxConsecutiveLosses = 5`. `PolicyLib._staticChecks` reads:

```solidity
if (s.consecutiveLosses >= p.maxConsecutiveLosses) return LucidTypes.Refusal.RiskHalt;
```

and `_staticChecks` is reached from `preCheck`, which the router calls in `_candidates` **before it
will even include a desk in the fan-out**. So once the counter crossed the line, the desk was not
refusing trades — it was no longer being asked.

Settlements on this venue arrive two windows at a time, so the streak went 2 → 4 → 6 and the third
settlement transaction carried it past the limit of 5 in one step. Read the state yourself; both
values are public:

```bash
RPC=https://api.infra.testnet.somnia.network
D=0x85e34174fcd39c1c717724b3691d3e34ff265149
cast call $D 'state()((uint64,uint64,uint64,uint16,uint8))'  --rpc-url $RPC
# (20703, 30000000, 5000000000, 0, 6)   <- consecutiveLosses = 6
cast call $D 'policy()((uint64,uint64,uint16,uint16,uint8,uint16,uint32,uint32,uint8,bool))' --rpc-url $RPC
# (5000000, 200000000, 5, 3000, 5, 200, 3, 14, 1, false)   <- maxConsecutiveLosses = 5
cast call 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E 'balanceOf(address)(uint256)' $D --rpc-url $RPC
# 4970000000
```

**The desk stayed armed for another 47 minutes and never took another window.** Its last settlement
was 02:55:05. Its owner disarmed it at 03:42:20 in
[`0x57a5dd34…`](https://shannon-explorer.somnia.network/tx/0x57a5dd34f217aa184beddfb01e3241e41d7ce3cf2f88b8af32cee3ed7c53c8f7),
as part of the redeploy. Between those two moments, blocks 481 765 425 → 481 793 777, the router was
fully alive and spending: **112 `MarketSeen`, 18 `DecisionScheduled`, 7 `VerdictRequested`**, and the
other armed desk was `Considered` seven times. The halted desk was considered **zero** times.

```bash
RPC=https://api.infra.testnet.somnia.network
# not one Considered on the halted desk in that whole span
cast logs --rpc-url $RPC --from-block 481765426 --to-block 481766375 \
  --address 0x85e34174fcd39c1c717724b3691d3e34ff265149 \
  'Considered(bytes32,uint32,bytes32)'
```

A `preCheck` that declines emits nothing, deliberately — on a venue rolling two assets a minute, a
log line per uninterested desk per market would bury every line that matters — so the evidence here
is the state read plus the absence, together, rather than a log that says "halted".

Three things this establishes that a green run cannot:

- **The guard fires on the real failure, not on the modelled one.** Nobody wrote a losing strategy to
  demonstrate a risk limit. A genuine defect produced genuine losses and the limit caught them.
- **The blast radius was 30.000000 tUSDC of 5 000.000000 — 0.6 %** — and it was bounded by a number
  the desk's owner chose, enforced by a contract, with no operator awake.
- **The halt is sticky, and that is the design.** `consecutiveLosses` only clears on a settlement
  that does not lose, and a halted desk is never offered another window, so it cannot clear itself.
  The owner's only lever is `setPolicy` — changing the mandate, in public, in a transaction. A risk
  limit that a running strategy can reset is not a risk limit.

---

## 7. The run

Everything the current deployment did between **03:47:31 and 04:15:05 UTC on 2026-09-07**, twelve
windows, from the watcher's own counters and re-read off the chain: **12 committee verdicts, 12 price
fetches, 18 executions, 12 settlements, 12 `NoBook` refusals from `AiEdge`, 6 `VenueRejected` from
`Maker`.** That timestamp is a cut, not an ending — the deployment is still running, and a scan taken
later covers more windows than the table below. The five distinct committee medians in those twelve windows were **0, 50, 51, 99 and
100**, every one of them unanimous to the integer across three validators.

| market | asset | committee | legs rested | refused | cancelled at settlement | booked |
| --- | --- | --- | --- | --- | --- | --- |
| `0x…0159a3` | BTC | 100 % | `SELL_YES` 0.999 | `VenueRejected` | 1 | +0.000000 |
| `0x…0159a4` | ETH | 51 % | `SELL_NO` 0.490 | `VenueRejected` | 1 | +0.000000 |
| `0x…0159b0` | ETH | 50 % | `SELL_YES` 0.520, `SELL_NO` 0.480 | — | — | **−5.000000** |
| `0x…0159af` | BTC | 0 % | `SELL_NO` 0.001 | `VenueRejected` | 1 | +0.000000 |
| `0x…0159bc` | ETH | 0 % | `SELL_NO` 0.001 | `VenueRejected` | 1 | +0.000000 |
| `0x…0159bb` | BTC | 100 % | `SELL_YES` 0.999 | `VenueRejected` | 1 | +0.000000 |
| `0x…0159cb` | ETH | 50 % | `SELL_YES` 0.520, `SELL_NO` 0.480 | — | 2 | +0.000000 |
| `0x…0159ca` | BTC | 51 % | `SELL_YES` 0.530, `SELL_NO` 0.490 | — | 2 | +0.000000 |
| `0x…0159dd` | BTC | 50 % | `SELL_YES` 0.520, `SELL_NO` 0.480 | — | 2 | +0.000000 |
| `0x…0159de` | ETH | 0 % | `SELL_YES` 0.020, `SELL_NO` 0.001 | — | 2 | +0.000000 |
| `0x…0159e9` | BTC | 99 % | `SELL_YES` 0.999 | `VenueRejected` | 1 | +0.000000 |
| `0x…0159ea` | ETH | 50 % | `SELL_YES` 0.520, `SELL_NO` 0.480 | — | 2 | +0.000000 |

Prices are raw six-decimal collateral units divided by `oneCollateral = 1e6`; quantity was 5.000000
contracts on every row. `AiEdge` was `Considered` on all twelve and refused all twelve with `NoBook`,
correctly — no side of the venue's book quoted on any of them, and `pBookBps` carried the 65535
sentinel every time. `Maker` ended the run holding **5 000.200000 tUSDC**.

Six of the twelve got both legs up and six got one leg plus `Refused(VenueRejected)`. The split does
not line up with the committee's number: a 0 % window appears on both sides of it, and so does a
51 % one. What can be said is narrower and is said in [section 11](#11-honest-limits).

Then the router ran out of float, and said so by name rather than failing quietly:

| UTC | block | log | transaction |
| --- | --- | --- | --- |
| 04:17:30 | 481 814 864 | `Skipped … ROUTER_FLOAT` ×2 | [`0xc8bfff1c…`](https://shannon-explorer.somnia.network/tx/0xc8bfff1c01e664dbb87cf4894105a922b24cc6f5e05833290b17606007bc3f33) |
| 04:18:00 | 481 815 163 | `Skipped … SCHEDULE_FAILED`, first of 34 | [`0xaeec9c5a…`](https://shannon-explorer.somnia.network/tx/0xaeec9c5a600f7e05d733853370534cbfc8492ebde88a4ff4cabc7d6c31b0779d) |
| 04:20:00 | 481 816 363 | `Skipped … DECISION_SCHEDULE_FAILED`, first of 6 | [`0x9ca4ed87…`](https://shannon-explorer.somnia.network/tx/0x9ca4ed875872428bf42b1b8e9bb470f77ec6192aa6e05e82b7d552e68adffa37) |

The precompile checks the 32 SOMI subscription floor against the *calling* contract on every booking,
so once the router's own balance crossed it, new one-shots stopped being accepted. The router did not
pretend otherwise for a single block: it published the reason and spent nothing. It has since been
topped up — `verify-onchain.sh` read 37.612101 SOMI at 05:00 UTC — and the loop resumed at 04:37:31
without anyone touching the contracts. **Reporting funding exhaustion is the behaviour; a green
screenshot would have been worth less.**

Pull any of it yourself. Shannon caps `eth_getLogs` at 1000 blocks and mints a block roughly every
100 ms, so one call covers about ninety seconds:

```bash
RPC=https://api.infra.testnet.somnia.network
cast logs --rpc-url $RPC --from-block 481805800 --to-block 481805899 \
  --address 0x3ffbB71aec0D5459677021Ad888195042eDA4AA2 \
  'Executed(bytes32,uint8,uint256,uint256,uint128)'
```

---

## 8. There is no server

This is the claim that matters, so here is the evidence rather than the assertion.

### The subscription

```bash
curl -s -X POST https://api.infra.testnet.somnia.network -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"somnia_reactivityGetSubscriptions",
           "params":["0x6aE21a20444141552648C1f8443bAf171BCCcB99"]}'
# {"jsonrpc":"2.0","id":1,"result":["0xfc4163","0xfda77f","0xfda780","0xfda82e"]}
```

Four ids, all owned by the router, and they are not four subscriptions to the venue. **`0xfc4163` is
the only standing one**; the other three are the router's own `Schedule` one-shots, of which
`0xfda780` was still pending at 05:00 UTC and the other two had already been consumed and return an
empty result. `0xfda780` decodes as emitter `0x…0100` — the precompile itself — topic0
`0x67aa3d75…` = `Schedule(uint256)`, `topics[1] = 0x1a07a4173e8` = 1 788 757 505 000 ms = 05:05:05
UTC, which is the next settlement wake-up.

`0xfc4163` (16 531 811), decoded field by field:

| field | value | means |
| --- | --- | --- |
| `emitter` | `0x3ecc694cef705358864a646142ac17a90e29e388` | DreamDEX's own `BinaryMarketsModule`. Not a contract of ours. |
| `topics[0]` | `0xb5ec75cdb7dbcd28a5f50d152d8833334525a902ef5332ebc19bcf5c0011f8cd` | `MarketCreated`. |
| `topics[1..3]` | all zero | Wildcards — every market on that module, not a whitelist. |
| `owner` | `0x6ae21a20444141552648c1f8443baf171bcccb99` | The router. The precompile checks the 32 SOMI floor against *this* address. |
| `handler_contract_address` | `0x6ae21a20444141552648c1f8443baf171bcccb99` | The router again. |
| `handler_function_selector` | `0x53edf33d` | `onEvent(address,bytes32[],bytes)` — check it: `cast sig "onEvent(address,bytes32[],bytes)"`. |
| `gas_limit` | `0x5f5e100` = **100 000 000** | One firing fans out to every armed desk and then runs the venue's upkeep. |
| `priority_fee_per_gas` / `max_fee_per_gas` | 1 gwei / 20 gwei | |

### Who signs the handler transactions

A reactivity handler is a synthetic transaction the validator set executes. Its signature is that
the subscription owner appears as **both `from` and `to`**, because no external account sent it:

```bash
cast receipt 0x6fc665db5091d165585f8ad61e6407ae83fcd6d45432e1c0b314c21445b32050 \
  --rpc-url https://api.infra.testnet.somnia.network | grep -E '^(from|to)'
# from  0x6aE21a20444141552648C1f8443bAf171BCCcB99
# to    0x6aE21a20444141552648C1f8443bAf171BCCcB99
```

The same holds for every handler transaction in this document:
[`0x6fc665db…`](https://shannon-explorer.somnia.network/tx/0x6fc665db5091d165585f8ad61e6407ae83fcd6d45432e1c0b314c21445b32050) (market seen),
[`0xe906edfb…`](https://shannon-explorer.somnia.network/tx/0xe906edfb19c4bae0f748baa1949101b0b3f6a9449e44d2d25ec773c95e41fb85) (decision wake-up),
[`0x5c9e2b27…`](https://shannon-explorer.somnia.network/tx/0x5c9e2b2750774eca0edbde1893df56da5fc162c7ffc185a28758fdd1de5c2c02),
[`0x67c42a3e…`](https://shannon-explorer.somnia.network/tx/0x67c42a3edf14e32586f46ea528346859ff8ed015a3d9f4b8ea901632b7d0ff9a),
[`0xc50c6095…`](https://shannon-explorer.somnia.network/tx/0xc50c60958e32f6beca5c63c992294c168cb7e64b403a101f8a1553deef6063db) (settlements),
[`0xc8bfff1c…`](https://shannon-explorer.somnia.network/tx/0xc8bfff1c01e664dbb87cf4894105a922b24cc6f5e05833290b17606007bc3f33) (a refusal to spend).

The other half of the loop — the committee answers — are submitted by validator accounts to Somnia's
agent platform, not by us. Four different validators appear in the run above:
[`0x3e05e290…`](https://shannon-explorer.somnia.network/address/0x3e05e29029c60e000c8f01eb5ac9cee6b242d7e0),
[`0x55acbe37…`](https://shannon-explorer.somnia.network/address/0x55acbe370872c7d90f504ef169217a00c29e2a33),
[`0x05f1fE2D…`](https://shannon-explorer.somnia.network/address/0x05f1fE2DDF9B65576D3165E37C6A60e6c5Ba93De) and
[`0x1Cb38b3e…`](https://shannon-explorer.somnia.network/address/0x1Cb38b3ee632B5dCc0347dB81766606d6Aad4926),
each `to` `0x037Bb9C7…`. Open any committee transaction and read the `from` field.

### The invitation

Nothing of ours is running. Check it:

- Nothing subscribed to that emitter belongs to any address of ours except the router, and the
  router holds exactly one standing subscription to it.
- Not one transaction in the operating loop — sections [2](#2-the-loop-proven-end-to-end) through
  [7](#7-the-run) — was signed by a key of ours. Every `from` is either the router itself or a Somnia
  validator. The only transactions we signed are the deployment and arming calls in
  [section 1](#1-the-addresses), the one-off venue setup in [section 10](#10-our-own-venue-resolves),
  and the top-ups; nothing repeats them on a schedule.
- The router is still reacting **now**, with no help. Run
  [`verify-onchain.sh`](contracts/verify-onchain.sh) and read section 4/5 — at the run reproduced in
  [section 13](#13-reproduce-it-yourself) it found 6 `MarketSeen` and 6 `SettlementScheduled` in the
  last 950 blocks, the newest 73 blocks (about seven seconds) old.
- Turn off every machine we own and the loop does not change. There is no endpoint to switch off:
  the router's address is the process.

---

## 9. Self-calibration

The brain refuses windows it cannot finish in time, and it decides what "in time" means by measuring
itself. Five reads, no key:

```bash
RPC=https://api.infra.testnet.somnia.network
B=0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25
cast call $B 'feedObserved()(bool)'         --rpc-url $RPC   # true
cast call $B 'verdictObserved()(bool)'      --rpc-url $RPC   # true
cast call $B 'feedLatencyEma()(uint256)'    --rpc-url $RPC   # 0
cast call $B 'verdictLatencyEma()(uint256)' --rpc-url $RPC   # 0
cast call $B 'requiredSlack()(uint256)'     --rpc-url $RPC   # 90
```

On 2026-09-07 both stages were marked observed, both exponential moving averages had settled at
0 seconds, and `requiredSlack()` read **90** — its hard floor. It was seeded at 60 s per stage, which put the
requirement at **270 s**; a 300-second window asked at the halfway point offers 150 s, so the guard
refused every window and, because an EMA only updates when its stage *completes*, refusing meant the
measurement never happened. Sixteen consecutive wake-ups skipped `TOO_LATE` on a router that was
working perfectly.

The requirement came down to 90 because the contract measured its own two committee stages on chain
and found them fast — not because anyone edited a constant. The measurements are public:
`LatencyObserved(stage, observed, ema)` in
[`0x1830ef33…`](https://shannon-explorer.somnia.network/tx/0x1830ef332ff751df76b7e65ce3dc789008f58cb4f2bfa6881c718a74a72e2868)
(stage 1, observed 0 s) and
[`0xec22854e…`](https://shannon-explorer.somnia.network/tx/0xec22854e1a2619ade09453233f0d3dfbe20eb6185a73ceca869daae40927e010)
(stage 2, observed 0 s); a slower one at 1 s is in
[`0x5e170dbb…`](https://shannon-explorer.somnia.network/tx/0x5e170dbb00608b70eedaeca00c5cea4772b1b28206e5dbab52562d65c3bc5f18).
The general rule that came out of it: a self-calibrating guard must never be able to prevent its own
calibration, so an unobserved stage contributes its floor rather than its seed.

### The same deadlock, through the other door

That rule closed one door and left another open, and the deployment walked through it on
2026-09-11.

Contributing the floor only helps a stage that has never been measured. It does nothing for a stage
that has been measured *slowly*. At some point before 01:52 UTC the price committee delivered one
answer late enough to move `feedLatencyEma` from 0 to 81 in a single sample — the average folds in a
quarter of each observation, so that is a round trip of roughly 324 s. `requiredSlack()` became
`(81 + 0) × 2 + 30 = 192`. A 300-second window asked at the halfway point has 150 s left, so the
router's own pre-check, `_tooLateToAsk`, which reads the same `requiredSlack()` before it pays for
anything, refused every window with `TOO_LATE`. An average only moves when a stage completes, and
nothing was being asked, so nothing was ever going to move it back.

The desks sat armed, funded and silent for at least thirteen hours. A scan back to 01:52 UTC found
no committee request at all, and the maker's `dayKey` never rolled over into the 11th. Every layer
was healthy on its own terms: the watch was delivering markets, the router was booking decisions,
and each decision was being declined for a reason that reads exactly like prudence.

The cap on a single sample does not prevent this. `MAX_SLACK` is 600 s, and one capped sample puts
the average at 150 and the requirement at 330 — more than a 300-second window leaves at any decision
point the router allows.

It was recovered without a redeploy at 14:40 UTC on 2026-09-11 by moving the decision point from
50 % of the window to 25 % — `setDecisionPoint(2500)` in [`0x3b40a2d5…`](https://shannon-explorer.somnia.network/tx/0x3b40a2d5b2b8f6a903b2e72da8d820c58dd8bddaa1be345399e5df0329e7c361).
That leaves 225 s at the decision instant against 192 required. The first committee request after
it went out at block 485 644 108, 14:41:15 UTC. The price stage answered in 14 s and the verdict
stage in 1 s, the average fell from 81 to 64, and the requirement from 192 to 158; each fast answer
takes another quarter off, so it reaches the 90-second floor within a handful of windows, and the
decision point can then go back to halfway.

That is a recovery, not a fix. A guard that is only re-measured when it lets work through can always
lock itself shut, and moving the decision point widens the margin without removing the loop. The fix
is a contract change — let the router ask anyway after some number of consecutive `TOO_LATE`
refusals, so a stale average is always given the chance to be corrected — and it is not deployed.

The quote it charges for those two stages is re-derived from the platform's own deposit function
rather than taken on the brain's word, in section 10 of `verify-onchain.sh`:
stage 1 **0.12 SOMI** = deposit 0.03 + 3 × 0.03 · stage 2 **0.24 SOMI** = deposit 0.03 + 3 × 0.07 ·
`quote()` **0.36 SOMI**.

---

## 10. Our own venue resolves

DreamDEX's venue registration is open. The interesting question is not whether an ordinary account
can register one — it is whether the venue's oracle then actually answers the windows that come out
of it. It does.

An ordinary account, [`0xc84C24F7…`](https://shannon-explorer.somnia.network/address/0xc84C24F751c686568A907650FD59b1a3AC1a5E67),
registered the lot on 2026-09-06:

| UTC | transaction | what |
| --- | --- | --- |
| 14:19:46 | [`0xebd6f938…`](https://shannon-explorer.somnia.network/tx/0xebd6f938eef2ac173aebd1a159e48339c816cb3bad72f5cde516c16bbfaea02c) | Operator registered on `MarketsCore` — `operatorId = 0x13` = **19**, admin the same account. |
| 14:22:06 | [`0x0494f615…`](https://shannon-explorer.somnia.network/tx/0x0494f61523453fbf75c7d758111f7d4c60038626bc239a7773e9aaa6ebafb402) | Venue registered under operator 19 — `venueId = 0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581`. |
| 14:23:31 | [`0x05515473…`](https://shannon-explorer.somnia.network/tx/0x05515473d5b1cff726eef6fd55fafa87e71e192679b56a08c0a3901beae5aa91) | `MarketCreator` [`0x7Fa6Ac2a…`](https://shannon-explorer.somnia.network/address/0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2) deployed through DreamDEX's factory, bound to operator 19 and that venue. |
| 14:24:20 | [`0xbb889e05…`](https://shannon-explorer.somnia.network/tx/0xbb889e058d923c6fac0ee72075e2b65fa309c3bae8e75ce72a411e0403d1e586) | The venue is pointed at the creator. |
| 14:24:56 | [`0xd6d64c9c…`](https://shannon-explorer.somnia.network/tx/0xd6d64c9cd2bbf840a9c428b6d0b0f438761d345d1bc6d619982ad8077d1e926f) | **Series 1 registered: collateral tUSDC, `intervalSec = 0x12c` = 300, symbol `BTC`.** |
| 14:36:48 | [`0xf0359012…`](https://shannon-explorer.somnia.network/tx/0xf03590120a112ac6caec030b1056b5252711f5451f806fe2f78e3052fab6760a) | The first roll is booked for `1788705600000` ms (14:40:00Z); the precompile records one-shot `0xfb5f7d` owned by the creator, filtering on `Schedule(uint256)`. |
| 14:43:30 | [`0xa16e4a07…`](https://shannon-explorer.somnia.network/tx/0xa16e4a07bf2da746e34a4fe47823039a37b54ec7ec64f33d4f8557648588ded3) | **The roll.** 46 logs, and among them `MarketCreated` for `0x…01521d` — market contract `0x23695959…`, pool `0xB65b6BB6…`. **61 596 476 gas**, the measured figure behind the router's 100 M handler limit. |

That is the window below. It settled one second after expiry:

```bash
RPC=https://api.infra.testnet.somnia.network
M=0x000000000000000000000000000000000000000000000000000000000001521d
cast call 0x3ecC694Cef705358864a646142ac17A90E29e388 \
  'markets(bytes32)(uint256,uint8,uint8,address,uint32,bytes32,address,address,address,address,uint256,uint256,uint64,uint64)' \
  $M --rpc-url $RPC
# oracleQuestionId 51081 · originOperatorId 19 · originVenueId 0x7b41ffa0…8581
# oracleAdapter 0xe40db387cC98601Dd11bd634fF2f3AD5686dE32b
# creator 0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2   ← ours
# market  0x23695959288837F78075A9e28158215a5250049a

cast call 0x23695959288837F78075A9e28158215a5250049a 'payoutNumerators()(uint256[])' --rpc-url $RPC
# [10000000, 0]

cast call 0x23695959288837F78075A9e28158215a5250049a 'isResolved()(bool)' --rpc-url $RPC   # true
cast call 0x23695959288837F78075A9e28158215a5250049a 'isVoided()(bool)'   --rpc-url $RPC   # false
cast call 0x23695959288837F78075A9e28158215a5250049a 'status()(uint8)'    --rpc-url $RPC   # 4 (Resolved)

cast call 0xe40db387cC98601Dd11bd634fF2f3AD5686dE32b 'pullNumericAnswer(uint256)(uint256)' 51081 --rpc-url $RPC
# 7971864     ← BTC 79 718.64
```

And the public indexer agrees:

```bash
curl -s -X POST https://dev.smk.somnia.host/v1/graphql -H 'content-type: application/json' --data '{
  "query":"query($v: String!){ Market(limit:5, order_by:{resolvedAtTimestamp: desc}, where:{venueId:{_eq:$v}}) { marketId asset intervalSec clobStatus winningOutcome finalized voided expiry resolvedAtTimestamp } }",
  "variables":{"v":"0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581"}}'
```

```json
{ "marketId": "0x…01521d", "asset": "BTC", "intervalSec": "300",
  "clobStatus": "Finalized", "winningOutcome": 0, "finalized": true, "voided": false,
  "expiry": "1788705900", "resolvedAtTimestamp": "1788705901" }
```

`Finalized` is the terminal status on this venue; `Resolved` does not exist in the indexer's schema,
and a filter written against it matches nothing forever.

This is why `LucidSeries` is a failover rather than a slide. On 4 September short-cadence creation on
the shared venue stopped for hours because the SDK's advertised testnet `MarketCreator` had run its
float to zero, and every protocol pointed at it stopped at the same instant. The way out is not a
support ticket; it is your own creator, your own venue, and the venue's oracle answering it exactly
as it answers DreamDEX's own. The deployment runs in `Failover` mode — mode `1`, confirmed by section
11 of `verify-onchain.sh` — so it spends nothing while the venue's own scheduler is healthy. At the
run in [section 13](#13-reproduce-it-yourself) the watcher reported the venue healthy, 0 rolls of the
12 allowed today, and a creator float of 9.223132 SOMI against a 6 SOMI roll floor.

---

## 11. Honest limits

Stated here, at the same size as everything else.

**Both legs now rest about half the time, and we cannot say why the other half fails.** The old
statement here was "only one leg ever rests, six times out of six", and it is no longer true: in
[section 7](#7-the-run) six of twelve windows got a two-sided quote up and six got one leg plus
`Refused(VenueRejected)`. The refusal enum has since been split, so `VenueRejected` now means only
what its comment says — *the pool was shown a completely described order and turned it down* — and
`BookUnreadable`, `Unquotable` and `MintFailed` have their own values. None of those three fired in
the run, which narrows the cause but does not name it. The tempting story, that the ask crosses the
venue market maker's bid at extreme committee values and post-only correctly declines, **does not
survive the data**: a 0 % window and a 51 % window each appear on both sides of the split. The
supported statement is the narrow one: *the pool accepts both legs on some windows and one leg on
others, and the event says which order it turned down but not why.*

**Twelve windows is not a sample.** [Section 7](#7-the-run) covers 33 minutes on one venue, two
assets, one cadence and one size. It shows that the mechanism works end to end. It shows nothing
about whether the strategy works, and no P&L claim is made from it.

**The per-window `pnl` cannot see a maker fill.** `pnl = _free() − before − cost`, and `before` is
snapshotted at the start of settlement. Collateral that a counterparty paid for a filled leg arrives
*during the window*, long before that snapshot, so it lifts `equityAfter` and enters no window's
`pnl` at all. That is exactly what produced the `-5.000000` on `0x…0159b0` in
[section 4](#4-hero-2--a-settlement-booked-honestly) alongside a run that ended 0.200000 tUSDC up.
The event stream is complete and the equity figure is right; the per-window attribution is not, and
anyone reading `Settled.pnl` as trade P&L for a maker will read it wrong. It is stated rather than
patched because the fix changes an accounting convention that historical logs were written under.

**The committee is badly calibrated, and its direction is carried by one bucket.** The pre-registered
harness in [eval/EVAL.md](eval/EVAL.md) graded **n = 62** verdicts across 8 hours and published what
it found, including against itself. Eight distinct forecasts, realised UP rate 53.2 %; Brier
**0.3598** against **0.2500** for a forecaster that says "50 %" to everything and **0.3574** for a
same-boldness coin flip — it loses to both, and the harness prints `BEATS NEITHER CONTROL`.
Directional accuracy is 69.6 % (32 of 46 decisive, 16 abstentions at exactly 50 %), but the
committee's seventeen 51 % calls went 17 for 17 and everything else together went 15 of 29, which is
chance. Its confident calls are anti-calibrated: the 0 % bucket realised 42.1 % UP and the 90–100 %
bucket realised 25 %. **No predictive edge is claimed here.** Read EVAL.md before assuming anything.

**The keeper is wired, is attempted on every firing, and has never once succeeded. We do not know
why.** This is the weakest component in the deployment, and it is set out here at length because it
is described elsewhere as a contribution to the venue. Three things are true at once, and each has a
command under it.

*One — the wiring is correct.* The keeper points at the deployed router, and the router has the
keeper attached, so venue-wide upkeep is attempted on every settlement firing:

```bash
cast call 0x4757599dC9A5a089270373a66BEeeD6592788707 'router()(address)' --rpc-url https://api.infra.testnet.somnia.network
# 0x6aE21a20444141552648C1f8443bAf171BCCcB99   — the router in deployed.json
```

*Two — every attempt has reverted.* The keeper's six public counters, read at 2026-09-07 05:58 UTC:

```bash
cast call 0x4757599dC9A5a089270373a66BEeeD6592788707 'counts()(uint64,uint64,uint64,uint64,uint64,uint64)' --rpc-url https://api.infra.testnet.somnia.network
# 0 0 0 0 0 1362    finalized · released · synced · poked · voided · failures
```

Zero finalized, zero released, zero synced, zero poked, zero voided — and 1 362 attempts that
reverted, across roughly 260 markets. **That sixth number is a failure count, not work performed.**
The only thing it grows with is unsuccessful attempts, so a later read shows a larger number beside
the same five zeros. Read it yourself rather than taking either figure from us.

*Three — the calls themselves are not wrong.* Simulated **from the keeper's own address** at
2026-09-07 05:59 UTC against market `0x…5af9` — expired at 1 788 761 100, `isResolved()` true,
`status()` 4, and still listed by the indexer as `finalized: false`:

```bash
RPC=https://api.infra.testnet.somnia.network
MOD=0x3ecC694Cef705358864a646142ac17A90E29e388    # BinaryMarketsModule
K=0x4757599dC9A5a089270373a66BEeeD6592788707      # LucidKeeper
MID=0x0000000000000000000000000000000000000000000000000000000000015af9
MKT=0x8c0962F93B50Fe0B7f76271257941f35A0A97B55    # markets(MID).market
QID=102659976736423338484455824881934707204165729380291702598303405713070651455150

cast call --from $K $MOD 'finalizeMarket(bytes32)' $MID --rpc-url $RPC   # 0x  — succeeds
cast call --from $K $MOD 'syncSettlement(bytes32)' $MID --rpc-url $RPC   # 0x  — succeeds
cast call --from $K $MOD 'pokeOracle(uint256)'     $QID --rpc-url $RPC   # 0x  — succeeds
cast call --from $K $MOD 'releasePool(bytes32)'    $MID --rpc-url $RPC   # reverts 0xdf88ba21
cast call --from $K $MKT 'voidExpired()'                --rpc-url $RPC   # reverts 0xe064752b, args (2, 4)
```

Three of the five would go through. `voidExpired` reverting is correct — the market resolved, so it
is not void. The work is therefore real and the calls are right, and the keeper has still never
landed one. Any expired market the indexer reports as `finalized: false` reproduces this; the ids
turn over every few minutes, so find a current one rather than reusing the one above.

*What is not known.* **The cause is not established.** A plausible story is that at `expiry + 5 s`,
when the router's settlement wake-up fires, the oracle has not answered yet and everything reverts —
but that is a guess, and it is not offered here as an explanation. An earlier version of this page
carried a confident one and it was wrong: `settlementWindow()` reads **86 400** on this deployment, a
day, and is evidently the oracle's deadline to answer rather than a waiting period a market must sit
through before it can be finalized. Until the revert is captured at the moment of the firing instead
of reconstructed afterwards, the accurate statement is the one above: it does not work, and we cannot
yet say why.

Venue-wide upkeep also measured about 8.3 SOMI/hour on this deployment, which a testnet float does
not survive continuously.

**Funding is the binding constraint, and it is visible.** The router must hold 32 SOMI and stops
booking one-shots below it, re-checked on every booking rather than once at setup; it crossed that
line at 04:17:30 and logged `ROUTER_FLOAT`, `SCHEDULE_FAILED` and `DECISION_SCHEDULE_FAILED` until it
was topped up. Each desk's prepaid gas credit currently reads 0.15 SOMI against the 0.19 a verdict
debits (`cast call <router> 'gasCreditOf(address)(uint256)' <desk>`), which is why `NO_CREDIT` skips
resume between top-ups. Nothing about the mechanism is bursty; the funding is.

**Sixty-second windows can never be traded.** `requiredSlack()` floors at 90 seconds, which exceeds
the whole window. A desk may allow the cadence and will refuse every one of those windows with
`WindowTooShort`. Documented, not masked.

**The venue has stopped listing anything but 60 s and 300 s, which leaves one tradeable cadence.**
Checked against the indexer on 2026-09-08 at 15:55 UTC: of the last 298 binary markets on the venue
this deployment serves, 246 were 60-second windows and 52 were 300-second, split evenly between BTC
and ETH. There were no 15-minute and no 1-hour windows at all, although the desks allow both and the
venue was rolling them earlier in the week. With 60 s unreachable behind the slack floor, **300 s is
the only window length the desks can currently act on** — every trade in this document is one, and
that is not a design choice of ours.

```bash
curl -s https://dev.smk.somnia.host/v1/graphql -H 'content-type: application/json' \
  --data '{"query":"{ Market(where:{marketType:{_eq:\"BINARY\"}}, order_by:{expiry:desc}, limit:400)
           { asset intervalSec venueId } }"}'
```

**The desks are running on BTC alone, to fit a faucet.** The mandate allows what its `allowedAssets`
mask says and the interface reads that mask from the chain, so this is visible rather than stated —
but the reason is worth writing down. The protocol burns SOMI continuously: about 2.8 an hour for
the venue watch, plus roughly 0.36 per window the committee is asked about. On both assets that came
to ~12.5 SOMI an hour net, which is more than a day of Shannon faucet claims; on BTC alone it is
7.8, which a day's claims cover with margin to spare. Nothing about the protocol is per-asset —
`allowedAssets` is one bitmask and ETH is one transaction away — and the earlier runs in this
document, including the hero in [section 3](#3-hero-1--one-transaction-two-mandates-two-outcomes),
were traded on ETH. Testnet economics, not capability.

**Testnet only, unaudited.** Shannon, chain 50312, faucet tUSDC. All eight contracts are
source-verified on the explorer, which is not an audit and is not offered as one. Neither these
contracts nor the DreamDEX binary contracts underneath them have been audited — the published Hacken
audit covered the spot venue only.

---

## 12. The router bricked itself, and what replaced it

At 13:56 UTC on 2026-09-08 the router held 0.68 SOMI. Somnia requires a subscription's owner to
hold at least 32 at `subscribe` time, and the router had spent the difference the way it is
supposed to — 0.36 SOMI per committee call, a handler bill per firing, one settlement wake-up per
window it served. The chain had already taken its venue subscription away. Nothing was delivering
markets, and the whole loop was quiet.

At what point it was taken away we do not know, and this section used to assert that crossing the
32 SOMI line was enough to do it. It is not: the watch described below ran for nineteen hours at
7.65 SOMI, far under the floor, and kept its subscription and kept delivering. Two observations —
gone at 0.68, alive at 7.65 — do not identify a mechanism, and none is claimed here.

That part was expected: a router below the floor stops, and topping it up starts it again. It did
not start again.

```
$ cast call $ROUTER 'armVenue(address,bytes32)' $MODULE $VENUE --from $OWNER
Error: execution reverted, data: "0x13e7ce5d"

$ cast sig 'UnsubscribeFailed()'
0x13e7ce5d
```

`armVenue` cancels the previous subscription before it creates the new one, and
`SomniaExtensions.unsubscribe` reverts when the precompile refuses the cancel. The precompile
refuses a cancel for an id it no longer holds — which is precisely the state the router was left
in, holding `venueSubscriptionId = 16531811` for a subscription the chain had already taken away:

```
$ curl -s $RPC -d '{"method":"somnia_reactivityGetSubscriptions","params":["'$ROUTER'"]}'
{"result":[]}
```

The router had been funded to 40 SOMI before that call. Money was never the problem, and no amount
of it would have been: **a router that runs out of float can never be re-armed.**

Every desk binds to its router in `initialize` and there is no setter, so redeploying the router
means redeploying the desks that hold the collateral. That was not an acceptable answer at 14:00
UTC, and it would not have been an acceptable answer at any other hour either.

### LucidWatch

The precompile lets a subscription name a handler other than its owner, and Somnia's
`SomniaEventHandler` admits any call from `0x0100` without asking who owns the subscription behind
it. So the venue subscription can be owned and paid for by one contract and executed on another —
and the router needed no change at all to accept that.

`LucidWatch` at
[`0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C`](https://shannon-explorer.somnia.network/address/0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C)
owns the `MarketCreated` subscription on a bond of its own and names the router as its handler. Its
own cancel goes through a low-level call whose failure is recorded in an event and otherwise
ignored, because "the subscription is already gone" and "the cancel was refused" leave the caller in
the same place. A contract whose job is to recover from an empty balance must not carry a path that
an empty balance can close permanently.

```
14:12 UTC  deploy  LucidWatch(owner, router)      0xA0eb631b…
14:14 UTC  fund    36 SOMI                         0xd24624cc…
14:15 UTC  arm(0x3ecC694C…)                        0x31271b6d…  subscription 16982453
14:15 UTC  router decisionQueue = 2, settlementQueue = 4
16:17 UTC  committee 55 % / 51 %, two maker legs filled on the venue
```

The split is worth having beyond the recovery. The venue watch and the router's own scheduling now
sit behind two independent bonds: the router draining stops the wake-ups it pays for and leaves the
watch delivering markets, so the protocol resumes on the next window instead of on the next
deployment. `verify-onchain.sh` checks both bonds and reports a cold standby as a standby rather
than as an underfunded contract.

### Why the suite did not catch it

`MockPrecompile.unsubscribe` accepted any id at all. Under that mock the re-arm path is
unreachable, so 402 passing tests said nothing about it. The mock now refuses a cancel for a
subscription it does not hold and carries a `reap()` that takes one away the way the chain does —
without telling its owner, which is the whole failure mode.

`test_router_armVenue_is_bricked_by_a_reap` in
[`contracts/test/LucidWatch.t.sol`](contracts/test/LucidWatch.t.sol) then reproduces the production
revert against the deployed router's own code, and
`test_arm_recovers_after_the_chain_reaped_the_id` runs the identical setup through the watch. The
pair is the argument; the other nineteen tests in that file are housekeeping.

This is the second time in this project that a mock kinder than the chain hid a defect that only
chain time could find — the first is the `Schedule` timestamp in
[section 8](#8-there-is-no-server). Both are recorded in
[`MOCKS.md`](MOCKS.md).

---

## 13. Reproduce it yourself

No wallet, no key, no funds. Node 20+ and Foundry.

### The on-chain audit

```bash
DESK=0x3ffbB71aec0D5459677021Ad888195042eDA4AA2 bash contracts/verify-onchain.sh
```

`deployed.json` records two desks rather than a single `demoDesk`, so pass `DESK=`; without it the
script exits early and says so. It runs **42 checks** — every address carries code, both bonded
contracts are above the reactivity floor, the venue subscription's emitter/topic/handler/gas-limit
all match whichever of them owns it, the router is reacting right now, its wiring matches
`deployed.json`, the desk is registered/armed/funded, its mandate is printed in words, the brain's
quote is re-derived from the platform's own deposit function, the failover watcher's status, and our
own venue's resolution through the indexer.

Observed at 2026-09-08 16:30 UTC, head block 483 045 475:

```
42 checks: 42 passed, 0 failed, 0 skipped
OK — every claim was checked against the chain and held.
```

A skip counts as a failure in the exit code on purpose — a green line for something nobody looked at
is worse than a red one. An earlier version of this page recorded 37 passed and 3 failed: the router
was below the 32 SOMI floor, no settlement had been scheduled, and `router.keeper()` read zero. The
router has since been topped up and the keeper has since been attached — what that attachment has and
has not achieved is in [section 11](#11-honest-limits) — and the script, not this paragraph, is the
authority on whether it stays that way.

### The test suite

```bash
bash contracts/setup.sh          # forge install: forge-std + OpenZeppelin v5.4.0
cd contracts && forge test
```

Observed at 2026-09-08 16:35 UTC: **423 passed, 0 failed, 0 skipped, across 15 suites.** No network,
no key. The counts move as tests are added; the line that has to hold is `0 failed`. Per suite:
`PolicyLibTest` 85 · `LucidRouterTest` 77 · `LucidBrainStageTest` 49 · `LucidDeskTest` 49 ·
`LucidSeriesTest` 33 · `LucidWatchTest` 21 · `LucidBrainTest` 21 · `LucidRelayTest` 19 ·
`PromptLibTest` 15 · `LucidFactoryTest` 14 · `LucidKeeperTest` 13 · `PolicyLibInvariantTest` 11 ·
`MarketDecoderTest` 7 · `LucidDeskArmSyncTest` 5 · `TypesTest` 4.

`LucidWatchTest` is the newest suite and the only one written against a defect in a contract that
was already deployed — see [section 12](#12-the-router-bricked-itself-and-what-replaced-it).

Eleven of those are new since the escrow defect in [section 5](#5-the-defect-the-desks-found-live):
`LucidDeskTest` went from 38 to 49, covering the cancel-before-redeem order, a cancel that reverts,
and a taker order that ended up resting.

`PolicyLibInvariantTest` is an invariant campaign with `fail_on_revert = true` and a pinned seed;
each of its 11 invariants ran 128 campaigns of 32 768 calls with **0 reverts**, and the handler
asserts it actually reached the branches under test so a vacuous green is caught.

### The evaluation

```bash
cd eval && npm install && npm run eval
```

Read-only, pre-registered, signs nothing and costs nothing. It never calls the brain — replaying a
settled window would price it with today's spot and leak the answer into the question. It reads the
`VerdictReceived` logs the brain already committed to a block, joins each to how that window settled
from the public indexer, and grades only rows whose outcome did not exist when the verdict was
written. Whatever it prints is what [eval/EVAL.md](eval/EVAL.md) says, negative results included.

### The read-only client

```bash
cd kit && npm install && npm run build
npx lucid status                                              # addresses, router balance vs the 32 SOMI floor
npx lucid subs 0x6aE21a20444141552648C1f8443bAf171BCCcB99     # decode the subscription into English
npx lucid markets                                             # live windows a desk could still enter
npx lucid desk status 0x3ffbB71aec0D5459677021Ad888195042eDA4AA2
```

`lucid subs` is the shortest path to the point of [section 8](#8-there-is-no-server): it turns four
opaque topics and a selector into a sentence naming the emitter, the handler and the gas limit.
