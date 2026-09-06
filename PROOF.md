# Proof

Every claim on this page is a link to something on a public chain, or a command you can run against
it. Nothing here is a screenshot and nothing here is a promise.

- **Chain** — Somnia Shannon testnet, id `50312`
- **Explorer** — <https://shannon-explorer.somnia.network>
- **RPC** — `https://api.infra.testnet.somnia.network`
- **Indexer** — `https://dev.smk.somnia.host/v1/graphql` (DreamDEX's public Hasura, unauthenticated)

Everything below was re-read off the chain on **2026-09-06, around 22:00–23:05 UTC**, head block
≈ 481 623 000. Addresses come from [`contracts/deployed.json`](contracts/deployed.json), which is the
authority. The address tables in `README.md` and `JUDGES.md` were written by
`scripts/sync-addresses.mjs` before the last redeploy and still name the previous deployment; where
they disagree with this page, `deployed.json` and the chain are right.

Related documents, not repeated here: [README.md](README.md) · [CLAIMS.md](CLAIMS.md) ·
[MOCKS.md](MOCKS.md) · [JUDGES.md](JUDGES.md) · [SDK_FEEDBACK.md](SDK_FEEDBACK.md) ·
[eval/EVAL.md](eval/EVAL.md).

---

## 1. The addresses

Runtime-code sizes are the ones `eth_getCode` returned during the run of `verify-onchain.sh`
reproduced in [section 10](#10-reproduce-it-yourself).

| what | address | one line |
| --- | --- | --- |
| `LucidRouter` | [`0x6aE21a20444141552648C1f8443bAf171BCCcB99`](https://shannon-explorer.somnia.network/address/0x6aE21a20444141552648C1f8443bAf171BCCcB99) | Owns the reactivity subscription, wakes on the venue's `MarketCreated`, books the decision and settlement one-shots, fans out to armed desks. 24 112 bytes. |
| `LucidBrain` | [`0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25`](https://shannon-explorer.somnia.network/address/0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25) | Two-stage question to Somnia's on-chain agent committees: price first, then the probability verdict. 20 621 bytes. |
| `LucidDesk` (clone implementation) | [`0xc54d0BaA3310F77a164D17Fe10f32a567793489E`](https://shannon-explorer.somnia.network/address/0xc54d0BaA3310F77a164D17Fe10f32a567793489E) | The desk logic every desk clone delegates to: mandate enforcement, sizing, order placement, settlement booking. 14 147 bytes. |
| `LucidFactory` | [`0xF82cC4219F6c7fe816155A8c3F0C9C3B1cc320eA`](https://shannon-explorer.somnia.network/address/0xF82cC4219F6c7fe816155A8c3F0C9C3B1cc320eA) | Mints ERC-1167 desk clones, one per owner address, and registers them with the router. 4 943 bytes. |
| `LucidKeeper` | [`0x4757599dC9A5a089270373a66BEeeD6592788707`](https://shannon-explorer.somnia.network/address/0x4757599dC9A5a089270373a66BEeeD6592788707) | Runs the venue's permissionless upkeep (`finalizeMarket`, `releasePool`, `syncSettlement`, `pokeOracle`) for every market, not only ours. 3 736 bytes. |
| `LucidRelay` | [`0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A`](https://shannon-explorer.somnia.network/address/0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A) | Queue of signed redemption authorisations anyone may drain, so a winner does not have to be online to be paid. 6 565 bytes. |
| `LucidSeries` | [`0x747fF3a7A6FE4912c96dCe7faA711dCB6fbd1CE4`](https://shannon-explorer.somnia.network/address/0x747fF3a7A6FE4912c96dCe7faA711dCB6fbd1CE4) | Failover: watches the venue's cadence and rolls a window on our own `MarketCreator` if the venue's scheduler stops. 5 452 bytes. |
| Desk `AiEdge` | [`0x86D170169cde0b5ab4bb3B360E930625aBA849ea`](https://shannon-explorer.somnia.network/address/0x86D170169cde0b5ab4bb3B360E930625aBA849ea) | Live desk, clone of the implementation above, owner [`0xc84C24F7…`](https://shannon-explorer.somnia.network/address/0xc84C24F751c686568A907650FD59b1a3AC1a5E67). Takes the book when the committee disagrees with it. Holds 5 000.000000 tUSDC. |
| Desk `Maker` | [`0xd44B2e952a29409eAfb940e42c7D2C20BA746faC`](https://shannon-explorer.somnia.network/address/0xd44B2e952a29409eAfb940e42c7D2C20BA746faC) | Live desk, a *different* owner [`0x3F396B9e…`](https://shannon-explorer.somnia.network/address/0x3F396B9e1E203d95BA5Be32f4115eaa435cb9dde) — the factory allows one desk per address. Mints a complete set and quotes both sides. Holds 5 000.100000 tUSDC. |
| `MarketCreator` (ours) | [`0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2`](https://shannon-explorer.somnia.network/address/0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2) | DreamDEX's own creator contract, deployed and owned by an ordinary account of ours, running series 1 (BTC, 300 s) on our own venue. 13 903 bytes. |

Third-party addresses this document refers to:

| what | address |
| --- | --- |
| DreamDEX `BinaryMarketsModule` | [`0x3ecC694Cef705358864a646142ac17A90E29e388`](https://shannon-explorer.somnia.network/address/0x3ecC694Cef705358864a646142ac17A90E29e388) |
| Somnia agent platform (`IAgentRequester`) | [`0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`](https://shannon-explorer.somnia.network/address/0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776) |
| Somnia reactivity precompile | `0x0000000000000000000000000000000000000100` |
| Settlement collateral `tUSDC` (6 decimals) | [`0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E`](https://shannon-explorer.somnia.network/address/0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E) |
| DreamDEX venue registry (`MarketsCore`) | [`0x2802504314685D89bF6C992CA5a8e7cC78bc0294`](https://shannon-explorer.somnia.network/address/0x2802504314685D89bF6C992CA5a8e7cC78bc0294) |
| DreamDEX `MarketCreator` factory | [`0xE6bEE93cE87c9E6e62aCb621caa7832EE47b4F6B`](https://shannon-explorer.somnia.network/address/0xE6bEE93cE87c9E6e62aCb621caa7832EE47b4F6B) |
| Venue the router serves | `0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f` |
| Our own venue | `0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581` |

### Source verification

Do not take our word for it. One command per address, no key:

```bash
curl -s https://shannon-explorer.somnia.network/api/v2/addresses/<address> \
  | python -c "import json,sys;d=json.load(sys.stdin);print(d['is_verified'], d['name'])"
```

Observed at 2026-09-06 23:02 UTC:

| contract | `is_verified` |
| --- | --- |
| `LucidRouter` | `True` — `LucidRouter` |
| `LucidBrain` | `True` — `LucidBrain` |
| `LucidKeeper` | `True` — `LucidKeeper` |
| `LucidRelay` | `True` — `LucidRelay` |
| `LucidSeries` | `True` — `LucidSeries` |
| `LucidDesk` (implementation) | **`False`** — verification of this deployment's copy had not landed when this was checked |
| `LucidFactory` | **`False`** — same |

Stated rather than smoothed over. The identical source *is* verified at the previous deployment's
addresses — [`LucidDesk` `0x8D87D72A…`](https://shannon-explorer.somnia.network/address/0x8D87D72A23Be0F9a07046b89113a7e615F629994)
and [`LucidFactory` `0xF36b6E1c…`](https://shannon-explorer.somnia.network/address/0xF36b6E1cf0D43563bC8874dd0cf8c24188eE2d94) —
so a reviewer can read the code today, but the two live addresses above are, right now, unverified
bytecode and should be treated as such. Re-run the command; if it now says `True`, this paragraph is
stale, and the command is the authority, not the paragraph.

The two desks are ERC-1167 minimal proxies (45 bytes each); the explorer reports their
implementation as `0xc54d0BaA…`, which is why verifying that one address covers both. The
`MarketCreator` is DreamDEX's contract, deployed through their factory — its source is theirs.

---

## 2. The loop, proven end to end

One window: market `0x…015633`, BTC, 300 seconds, on the venue the router serves. Six transactions,
in order, all on chain.

| # | block | UTC | transaction | what happened |
| --- | --- | --- | --- | --- |
| 1 | 481 582 418 | 21:50:00 | [`0xf623ec36…`](https://shannon-explorer.somnia.network/tx/0xf623ec36594f229aca9a216048ef25c48346b90287f59651e96244e1359c98cd) | The venue creates the window. `BinaryMarketsModule` emits `MarketCreated` with `topics[1] = 0x…015633` (and three sibling markets in the same transaction). |
| 2 | **481 582 418** | 21:50:00 | [`0x0273f912…`](https://shannon-explorer.somnia.network/tx/0x0273f912dc86e7da29ca4a48a23e6cc06d269d69f0a8b43d9b6e4248efed3ac8) | **Same block.** A validator runs the router's handler as a synthetic transaction — `from` and `to` are both the router. It emits `MarketSeen(0x…015633, intervalSec 300, BTC)` and `DecisionScheduled(0x…015633, tsMillis 1788731550000, subscriptionId 16549137)`. The decision is booked for 21:52:30, the halfway point of a window that runs 21:50:05 → 21:55:05. |
| 3 | 481 583 918 | 21:52:30 | [`0xc4c1464e…`](https://shannon-explorer.somnia.network/tx/0xc4c1464ee2f0e81a7a81aa5d5047a89a228f21bfbf76389dd5af39128a54334c) | The one-shot fires — again `from == to == router`. The router emits `VerdictRequested(fee 0.36 SOMI, deskCount 2)`, debits 0.19 SOMI of prepaid credit from each desk, and books `SettlementScheduled(tsMillis 1788731705000, subscriptionId 16549569)`. The brain emits `PriceRequested(requestId 13394188, deposit 0.12 SOMI)`. In the same block the precompile logs the creation of subscription `0xfc86c1` owned by the router. |
| 4 | 481 583 924 | 21:52:30 | [`0xc15bb46d…`](https://shannon-explorer.somnia.network/tx/0xc15bb46de3a6ad7d5bed730860f459e075287e53f9c1c82a452f722e9967d2a1) | **The price committee answers.** `PriceReceived(spot 7992414, used 3, prices [7992414, 7992414, 7992414])` — BTC 79 924.14, three validator readings, all agreeing. `LatencyObserved(stage 1, observed 0 s)`. The brain immediately buys stage two: `VerdictRequested(requestId 13394191, size 3, threshold 2, deposit 0.24 SOMI)`. |
| 5 | 481 583 935 | 21:52:31 | [`0xa4bdae59…`](https://shannon-explorer.somnia.network/tx/0xa4bdae5926dbe8d0477bc65ae52e39d480c7cdb748f8873190ef8ecca2d0c1ea) | **The inference committee answers**, and the policy gate decides. `VerdictReceived(probUpBps 0, responded 3, agreed 3, ok true, scores [0, 0, 0])`, `LatencyObserved(stage 2, observed 1 s)` — six blocks, about one second, from question to answer. Then both desks act. This is [hero #1](#3-hero-1--one-transaction-two-mandates-two-outcomes). |
| 6 | 481 585 467 | 21:55:05 | [`0x4d4e9f0d…`](https://shannon-explorer.somnia.network/tx/0x4d4e9f0d8ea3ca8412cadf1d9a749c55acb52c5720d8b742d15387a000d4d014) | The settlement one-shot fires (`from == to == router`), the position is redeemed and the result is booked. This is [hero #2](#4-hero-2--a-loss-booked-on-chain). |

The decision one-shot is gone now, as a consumed one-shot should be:

```bash
curl -s -X POST https://api.infra.testnet.somnia.network -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"somnia_reactivityGetSubscriptionInfo","params":["0xfc8511"]}'
# {"jsonrpc":"2.0","id":1,"result":[]}
```

---

## 3. Hero #1 — one transaction, two mandates, two outcomes

[`0xa4bdae5926dbe8d0477bc65ae52e39d480c7cdb748f8873190ef8ecca2d0c1ea`](https://shannon-explorer.somnia.network/tx/0xa4bdae5926dbe8d0477bc65ae52e39d480c7cdb748f8873190ef8ecca2d0c1ea)

Block 481 583 935 · status `1` · 7 544 372 gas · `from` [`0x1Cb38b3e…`](https://shannon-explorer.somnia.network/address/0x1Cb38b3ee632B5dCc0347dB81766606d6Aad4926),
a Somnia validator delivering the committee's answer · `to` the agent platform `0x037Bb9C7…`, which
calls back into `LucidBrain`, which calls the router, which fans out. One transaction, twenty-three
logs. Decoded, in order:

| # | emitter | event | value |
| --- | --- | --- | --- |
| 0 | `LucidBrain` | `LatencyObserved` | stage 2, observed 1 s, EMA 0 s |
| 1 | `LucidBrain` | `VerdictReceived` | market `0x…015633`, requestId 13394191, `probUpBps 0`, responded 3, agreed 3, `ok true`, `scores [0, 0, 0]` |
| 2 | `AiEdge` | `Considered` | market `0x…015633`, 300 s, BTC |
| 3 | `AiEdge` | `VerdictReceived` | `probUpBps 0`, `pBookBps 65535`, responded 3 |
| **4** | **`AiEdge`** | **`Refused`** | **reason `NoBook` (15)**, `probUpBps 0`, `pBookBps 65535` |
| 5–6 | `Maker` | `Considered`, `VerdictReceived` | the same market, the same instant, the same verdict |
| 7 | `tUSDC` | `Approval` | `Maker` → the market's pool `0x9253c714…` |
| 8–9 | `OutcomeToken6909` | `OperatorSet` | `Maker` approves the pool and the module to move its legs |
| 10 | `tUSDC` | `Transfer` | `Maker` → pool, **5.000000 tUSDC** |
| 11–12 | `OutcomeToken6909` | `Transfer` ×2 | **from `0x0`** to `Maker`: 5.000000 of token id `…1400` and 5.000000 of id `…1401` — one complete set minted, no counterparty involved |
| 13 | pool `0x9253c714…` | order lifecycle | the first leg reaching the venue |
| **14** | **`Maker`** | **`Refused`** | **reason `VenueRejected` (12)** — the second leg never got up |
| 15 | `OutcomeToken6909` | `Transfer` | `Maker` → pool, 5.000000 of id `…1401` — the NO leg escrowed behind the resting quote |
| 16–18 | pool `0x9253c714…` | order placed / rested | |
| **19** | **`Maker`** | **`Executed`** | `SELL_NO` at price `1000` (0.001), quantity `5000000` (5.000000 contracts), orderId `202914184810805070236` |
| 20–22 | agent platform | request settled, per-validator receipts | |

`pBookBps 65535` is `LucidTypes.BOOK_UNOBSERVED` — the sentinel for *there was no book*, which sits
outside the 0–10000 probability range on purpose so it can never be mistaken for a price somebody
quoted.

Same market. Same block. Same committee answer, delivered to both desks in the same call frame.
`AiEdge`'s mandate needs a market price to measure an edge against, finds none, and refuses by name.
`Maker`'s mandate does not need a counterparty at all, mints a complete set out of collateral and
puts a leg on the book. The model proposes; each desk's own policy contract disposes.

---

## 4. Hero #2 — a loss booked on chain

[`0x4d4e9f0d8ea3ca8412cadf1d9a749c55acb52c5720d8b742d15387a000d4d014`](https://shannon-explorer.somnia.network/tx/0x4d4e9f0d8ea3ca8412cadf1d9a749c55acb52c5720d8b742d15387a000d4d014)

Block 481 585 467 · 21:55:05 UTC · status `1` · 2 691 006 gas · `from` and `to` both the router —
a validator-executed reactivity handler, the settlement one-shot booked in step 3 above.

| # | emitter | event | value |
| --- | --- | --- | --- |
| 0–1 | `OutcomeToken6909` | `Transfer` ×2 | `Maker` → module, then burned: 5.000000 of market `0x…015634`'s NO leg |
| 2 | `tUSDC` | `Transfer` | pool → `Maker`, **5.000000** |
| 4 | `BinaryMarketsModule` | redemption | market `0x…015634`, owner `Maker`, amount 5.000000, payout 5.000000 |
| **5** | **`Maker`** | **`Settled`** | market `0x…015634`, **`pnl = 0.000000`**, `equityAfter = 5005.100000` |
| **7** | **`Maker`** | **`Settled`** | market `0x…015633`, **`pnl = -5.000000`**, `equityAfter = 5000.100000` |

Two windows closed in one transaction. One broke even. The other lost the whole 5.000000 tUSDC the
desk had committed: there is exactly one redemption in this transaction and it belongs to `015634`.
For `015633` — the window where the committee answered 0 % and the desk sold its NO leg at 0.001 —
nothing came back, and the desk booked it as a loss rather than leaving the position dangling.
Equity **5005.100000 → 5000.100000**.

That number is in this document because a system that only ever shows its wins is not showing
anything. The desk's current equity is readable at any time:

```bash
cast call 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E 'balanceOf(address)(uint256)' \
  0xd44B2e952a29409eAfb940e42c7D2C20BA746faC \
  --rpc-url https://api.infra.testnet.somnia.network
# 5000100000  (6 decimals)
```

There is no P&L claim anywhere in this repository. Six executions is not a track record. See
[CLAIMS.md](CLAIMS.md) § NOT CLAIMED.

---

## 5. Executions and settlements

Every trade the deployment has placed, 21:42–21:55 UTC on 2026-09-06. All by `Maker`; `AiEdge`
refused all six with `NoBook`, correctly — the venue's book was empty on every one of them.

| market | committee `probUpBps` | side | price | quantity | block | transaction |
| --- | --- | --- | --- | --- | --- | --- |
| `0x…01561b` | 5100 (`[51, 51, 51]`) | `SELL_NO` | 0.490 | 5.000000 | 481 577 936 | [`0xc6161328…`](https://shannon-explorer.somnia.network/tx/0xc6161328d4986b3ced6e1985245684c0af2784f28fb3f359e34c50ac2ad6bdd6) |
| `0x…01561c` | 5100 | `SELL_NO` | 0.490 | 5.000000 | 481 577 936 | [`0x12f44b11…`](https://shannon-explorer.somnia.network/tx/0x12f44b117a6dae948c80ded0f0323f91f16f12ab04275d8fe652cd074ab18a97) |
| `0x…015628` | 5100 | `SELL_NO` | 0.490 | 5.000000 | 481 580 932 | [`0xe7cff68b…`](https://shannon-explorer.somnia.network/tx/0xe7cff68be9e037fd4576e4ba04bc116320d6797ba289817b4f8fa91994c33704) |
| `0x…015627` | 5100 | `SELL_NO` | 0.490 | 5.000000 | 481 580 932 | [`0xdb66bc8d…`](https://shannon-explorer.somnia.network/tx/0xdb66bc8dc569254af0f349f270d5220f88d83889beb8d03f221124e978ee5a18) |
| `0x…015633` | **0** (`[0, 0, 0]`) | `SELL_NO` | **0.001** | 5.000000 | 481 583 935 | [`0xa4bdae59…`](https://shannon-explorer.somnia.network/tx/0xa4bdae5926dbe8d0477bc65ae52e39d480c7cdb748f8873190ef8ecca2d0c1ea) |
| `0x…015634` | 5000 (`[50, 50, 50]`) | `SELL_YES` | 0.520 | 5.000000 | 481 583 939 | [`0x2ae507e7…`](https://shannon-explorer.somnia.network/tx/0x2ae507e7375e57e86258bb8151a65849c859dbda46d519f94bf6c838f518d4a5) |

Prices are raw six-decimal collateral units divided by `oneCollateral = 1e6`; quantity likewise.
`SELL_NO` at 0.001 on the `015633` row is the desk quoting where the committee told it to — a
verdict of 0 % up means the NO leg is worth almost everything, and the desk marked its ask a tick
above zero. That is the quote that produced the −5.000000 in [hero #2](#4-hero-2--a-loss-booked-on-chain).

Settlements — three transactions, six windows, all validator-executed handlers with the router as
both `from` and `to`:

| block | UTC | transaction | booked |
| --- | --- | --- | --- |
| 481 579 468 | 21:45:05 | [`0xfba1695d…`](https://shannon-explorer.somnia.network/tx/0xfba1695d169c8cc91f66af58933cdacc54088239c4c9e910b06d7069984559ab) | `0x…01561b` pnl 0.000000 · `0x…01561c` pnl 0.000000 · equity 5005.100000 |
| 481 582 468 | 21:50:05 | [`0x570b424d…`](https://shannon-explorer.somnia.network/tx/0x570b424de8dea85aaab8b120935a7bca9d26db09593562e3cc7ee74398a6bdb6) | `0x…015627` pnl 0.000000 · `0x…015628` pnl 0.000000 · equity 5005.100000 |
| 481 585 467 | 21:55:05 | [`0x4d4e9f0d…`](https://shannon-explorer.somnia.network/tx/0x4d4e9f0d8ea3ca8412cadf1d9a749c55acb52c5720d8b742d15387a000d4d014) | `0x…015634` pnl 0.000000 · **`0x…015633` pnl −5.000000** · equity 5000.100000 |

Pull them yourself. Shannon caps `eth_getLogs` at 1000 blocks and mints a block roughly every
100 ms, so one call covers about ninety seconds:

```bash
RPC=https://api.infra.testnet.somnia.network
cast logs --rpc-url $RPC --from-block 481583900 --to-block 481583999 \
  --address 0xd44B2e952a29409eAfb940e42c7D2C20BA746faC \
  'Executed(bytes32,uint8,uint256,uint256,uint128)'
```

---

## 6. There is no server

This is the claim that matters, so here is the evidence rather than the assertion.

### The subscription

```bash
curl -s -X POST https://api.infra.testnet.somnia.network -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"somnia_reactivityGetSubscriptions",
           "params":["0x6aE21a20444141552648C1f8443bAf171BCCcB99"]}'
# {"jsonrpc":"2.0","id":1,"result":["0xfc4163"]}

curl -s -X POST https://api.infra.testnet.somnia.network -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"somnia_reactivityGetSubscriptionInfo","params":["0xfc4163"]}'
```

Subscription **`0xfc4163` (16 531 811)**, decoded field by field:

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
cast receipt 0x0273f912dc86e7da29ca4a48a23e6cc06d269d69f0a8b43d9b6e4248efed3ac8 \
  --rpc-url https://api.infra.testnet.somnia.network | grep -E '^(from|to)'
# from  0x6aE21a20444141552648C1f8443bAf171BCCcB99
# to    0x6aE21a20444141552648C1f8443bAf171BCCcB99
```

The same holds for every handler transaction in this document:
[`0x0273f912…`](https://shannon-explorer.somnia.network/tx/0x0273f912dc86e7da29ca4a48a23e6cc06d269d69f0a8b43d9b6e4248efed3ac8) (market seen),
[`0xc4c1464e…`](https://shannon-explorer.somnia.network/tx/0xc4c1464ee2f0e81a7a81aa5d5047a89a228f21bfbf76389dd5af39128a54334c) (decision wake-up),
[`0xfba1695d…`](https://shannon-explorer.somnia.network/tx/0xfba1695d169c8cc91f66af58933cdacc54088239c4c9e910b06d7069984559ab),
[`0x570b424d…`](https://shannon-explorer.somnia.network/tx/0x570b424de8dea85aaab8b120935a7bca9d26db09593562e3cc7ee74398a6bdb6),
[`0x4d4e9f0d…`](https://shannon-explorer.somnia.network/tx/0x4d4e9f0d8ea3ca8412cadf1d9a749c55acb52c5720d8b742d15387a000d4d014) (settlements),
[`0x0cd9c425…`](https://shannon-explorer.somnia.network/tx/0x0cd9c425852520fa550d137ab94802aa74f3a87c5f68347990a7144c1be3f5ff) (a refusal to spend).

The other half of the loop — the committee answers — are submitted by validator accounts to Somnia's
agent platform, not by us: [`0x05f1fE2D…`](https://shannon-explorer.somnia.network/address/0x05f1fE2DDF9B65576D3165E37C6A60e6c5Ba93De)
and [`0x1Cb38b3e…`](https://shannon-explorer.somnia.network/address/0x1Cb38b3ee632B5dCc0347dB81766606d6Aad4926)
delivered the six verdicts in [section 5](#5-executions-and-settlements), each `to`
`0x037Bb9C7…`. Open any of those transactions and read the `from` field.

### The invitation

Nothing of ours is running. Check it:

- Nothing subscribed to that emitter belongs to any address of ours except the router — the
  subscription list above has exactly one entry.
- Not one transaction in the operating loop — sections [2](#2-the-loop-proven-end-to-end) through
  [5](#5-executions-and-settlements) — was signed by a key of ours. Every `from` is either the router
  itself or a Somnia validator. The only transactions here we signed are the one-off setup calls in
  [section 8](#8-our-own-venue-resolves), and nothing repeats them.
- The router is still reacting **now**, with no help. Run
  [`verify-onchain.sh`](contracts/verify-onchain.sh) and read section 4/5 — at the run reproduced in
  [section 10](#10-reproduce-it-yourself) it found 24 `MarketSeen` logs in the last 5 700 blocks, the
  newest 110 blocks (about 11 seconds) old.
- Turn off every machine we own and the loop does not change. There is no endpoint to switch off:
  the router's address is the process.

---

## 7. Self-calibration

The brain refuses windows it cannot finish in time, and it decides what "in time" means by measuring
itself. Four reads, no key:

```bash
RPC=https://api.infra.testnet.somnia.network
B=0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25
cast call $B 'feedObserved()(bool)'        --rpc-url $RPC   # true
cast call $B 'verdictObserved()(bool)'     --rpc-url $RPC   # true
cast call $B 'feedLatencyEma()(uint256)'   --rpc-url $RPC   # 0
cast call $B 'verdictLatencyEma()(uint256)' --rpc-url $RPC  # 0
cast call $B 'requiredSlack()(uint256)'    --rpc-url $RPC   # 90
```

Both stages are marked observed, both exponential moving averages have settled at 0 seconds, and
`requiredSlack()` reads **90** — its hard floor. It was seeded at 60 s per stage, which put the
requirement at **270 s**; a 300-second window asked at the halfway point offers 150 s, so the guard
refused every window and, because an EMA only updates when its stage *completes*, refusing meant the
measurement never happened. Sixteen consecutive wake-ups skipped `TOO_LATE` on a router that was
working perfectly.

The requirement came down to 90 because the contract measured its own two committee stages on chain
and found them fast — not because anyone edited a constant. The measurements are public:
`LatencyObserved(stage, observed, ema)` in
[`0xc15bb46d…`](https://shannon-explorer.somnia.network/tx/0xc15bb46de3a6ad7d5bed730860f459e075287e53f9c1c82a452f722e9967d2a1)
(stage 1, observed 0 s) and
[`0xa4bdae59…`](https://shannon-explorer.somnia.network/tx/0xa4bdae5926dbe8d0477bc65ae52e39d480c7cdb748f8873190ef8ecca2d0c1ea)
(stage 2, observed 1 s). The general rule that came out of it: a self-calibrating guard must never be
able to prevent its own calibration, so an unobserved stage contributes its floor rather than its
seed.

The quote it charges for those two stages is re-derived from the platform's own deposit function
rather than taken on the brain's word, in section 10 of `verify-onchain.sh`:
stage 1 **0.12 SOMI** = deposit 0.03 + 3 × 0.03 · stage 2 **0.24 SOMI** = deposit 0.03 + 3 × 0.07 ·
`quote()` **0.36 SOMI**.

---

## 8. Our own venue resolves

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
11 of `verify-onchain.sh` — so it spends nothing while the venue's own scheduler is healthy.

---

## 9. Honest limits

Stated here, at the same size as everything else.

**Only one leg ever rests.** The maker quotes both sides; one leg gets on the book and the other
emits `Refused(VenueRejected)` — six times out of six, in every execution row in
[section 5](#5-executions-and-settlements). What that refusal does **not** tell you is *why*.
`VenueRejected` currently covers several distinct failures inside the maker's quoting path — an
unreadable book, an unquotable pair, a failed mint, and a genuine rejection by the pool — and the log
does not distinguish them. The obvious explanation — the venue's own market maker quotes around 0.87
while the committee said 0.51, so our ask crosses its bid and post-only correctly refuses to post a
crossing quote — is plausible and **not established**: on the `015633` window the committee said
0 %, which clamps the bid up a tick and makes the pair postable, and the leg failed anyway. The
supported statement is the narrow one: *the maker never got a two-sided quote up, and the event does
not say which of the four causes fired.* The fix — splitting the enum into `BookUnreadable`,
`Unquotable`, `MintFailed` and a `VenueRejected` that means only "the pool turned the order down" —
is in `contracts/src/types/LucidTypes.sol` and appended, so every historical log keeps its meaning.
It is not in the deployed bytecode that produced the logs above. Until a run on the new code exists,
nobody should read a market-structure story into this refusal.

**The committee is over-confident at the extremes, and the sample is small.** The pre-registered
harness in [eval/EVAL.md](eval/EVAL.md) graded n = 21 verdicts and published what it found, including
against itself. Four distinct forecasts (0 % ×9, 50 % ×3, 51 % ×8, 100 % ×1); Brier **0.3653**
against **0.2500** for a forecaster that says "50 %" to everything; directional accuracy 72.2 %
(13/18) with a one-sided binomial p = 0.0481. **That p-value does not survive contact with the
sample**: 16 of 21 windows closed UP, and a rule as dumb as *always say UP* scores 14/18 with a
Brier of 0.2381 — better on both metrics. The directional result is carried entirely by the eight
barely-decisive 51 % calls, which went 8 for 8; every other decisive call together went 5 for 10,
exactly chance. The nine confident 0 % calls contribute 0.2381 of the total 0.3653 Brier on their
own. **No directional skill is claimed here.** All 21 verdicts were unanimous to the integer, so the
committee bought consensus and no variance reduction in this sample.

**The desks ran out of gas credit mid-run, and the router said so by name.** The degradation is on
chain, in order, each step naming the component that actually failed:

| UTC | block | `Skipped` reason | transaction |
| --- | --- | --- | --- |
| 21:57:30 | 481 586 917 | `NO_CREDIT` (both desks) | [`0x0cd9c425…`](https://shannon-explorer.somnia.network/tx/0x0cd9c425852520fa550d137ab94802aa74f3a87c5f68347990a7144c1be3f5ff) |
| 22:12:30 | 481 595 915 | `ROUTER_FLOAT` | [`0xea98470e…`](https://shannon-explorer.somnia.network/tx/0xea98470ec59eff4b42a249103dd283aa5b0e3f5f79591f5217d3cd26a87f48b5) |
| 22:55:00 | 481 621 409 | `DECISION_SCHEDULE_FAILED` | [`0xa0f02d81…`](https://shannon-explorer.somnia.network/tx/0xa0f02d815d95a31e7b9cd0c674a1765e0b92c20a0cbf9080887772d873fbe845) |

Each desk's prepaid credit is 0.06 SOMI against the 0.19 a verdict costs
(`cast call <router> 'gasCreditOf(address)(uint256)' <desk>`), and the router's own balance —
**31.200088 SOMI** when `verify-onchain.sh` ran, **31.136753 SOMI** a few minutes later, still
falling as each firing pays its own gas — is under the precompile's 32 SOMI subscription floor, so
the precompile now refuses to book new one-shots. The router did not pretend otherwise for a
single block: it published the reason and spent nothing. That is the behaviour under funding exhaustion, and it is worth more than a
green screenshot.

**The keeper is currently detached.** `router.keeper()` reads zero, so the router schedules a
settlement only for markets its own desks asked about and runs no venue-wide upkeep. Venue-wide
upkeep measured about 8.3 SOMI/hour on this deployment — 40 markets per 15 minutes at roughly
0.017 SOMI per firing — which a testnet float does not survive continuously. The mechanism is not
bursty; the funding is.

**Sixty-second windows can never be traded.** `requiredSlack()` floors at 90 seconds, which exceeds
the whole window. A desk may allow the cadence and will refuse every one of those windows with
`WindowTooShort`. Documented, not masked.

**Testnet only, unaudited.** Shannon, chain 50312, faucet tUSDC. Neither these contracts nor the
DreamDEX binary contracts underneath them have been audited — the published Hacken audit covered the
spot venue only. Two of the seven contracts are unverified bytecode on the explorer at the time of
writing; see [section 1](#1-the-addresses).

---

## 10. Reproduce it yourself

No wallet, no key, no funds. Node 20+ and Foundry.

### The on-chain audit

```bash
DESK=0xd44B2e952a29409eAfb940e42c7D2C20BA746faC bash contracts/verify-onchain.sh
```

`deployed.json` records two desks rather than a single `demoDesk`, so pass `DESK=`; without it the
script exits early and says so. It runs **40 checks** — every address carries code, the router is
above the reactivity floor, the subscription's emitter/topic/handler/gas-limit all match, the router
is reacting right now, its wiring matches `deployed.json`, the desk is registered/armed/funded, its
mandate is printed in words, the brain's quote is re-derived from the platform's own deposit
function, the failover watcher's status, and our own venue's resolution through the indexer.

Observed at 2026-09-06 23:00 UTC, head block 481 622 119:

```
40 checks: 37 passed, 3 failed, 0 skipped
NOT OK — see the FAIL/SKIP lines above.
```

The three failures are the funding exhaustion documented in [section 9](#9-honest-limits), and the
script is doing exactly what it should by refusing to call them anything else:

- `router balance — 31.200088 SOMI held, floor is 32 SOMI (-0.799912)`
- `SettlementScheduled — 0 logs in the last 5700 blocks` (no keeper attached, no desk positions open)
- `router.keeper() = zero — the keeper is detached`

`MarketSeen` in the same run: **24 logs, newest 110 blocks ago.** The reactivity loop is alive; only
the spending is stopped. A skip counts as a failure in the exit code on purpose — a green line for
something nobody looked at is worse than a red one.

### The test suite

```bash
bash contracts/setup.sh          # forge install: forge-std + OpenZeppelin v5.4.0
cd contracts && forge test
```

Observed at 2026-09-06 22:45 UTC: **391 passed, 0 failed, 0 skipped, across 14 suites.** No network,
no key. The counts move as tests are added; the line that has to hold is `0 failed`. Per suite:
`PolicyLibTest` 85 · `LucidRouterTest` 77 · `LucidBrainStageTest` 49 · `LucidDeskTest` 38 ·
`LucidSeriesTest` 33 · `LucidBrainTest` 21 · `LucidRelayTest` 19 · `PromptLibTest` 15 ·
`LucidFactoryTest` 14 · `LucidKeeperTest` 13 · `PolicyLibInvariantTest` 11 · `MarketDecoderTest` 7 ·
`LucidDeskArmSyncTest` 5 · `TypesTest` 4.

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
npx lucid desk status 0xd44B2e952a29409eAfb940e42c7D2C20BA746faC
```

`lucid subs` is the shortest path to the point of [section 6](#6-there-is-no-server): it turns four
opaque topics and a selector into a sentence naming the emitter, the handler and the gas limit.
