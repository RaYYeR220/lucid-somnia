# Claims and evidence

Every public claim this project makes, with the tier of evidence behind it and the command or link
that settles it. Nothing is asserted here that is not either re-runnable, observable on chain, or
explicitly labelled as reasoning.

| tier | means |
| --- | --- |
| `REPRODUCIBLE` | You can re-run it yourself, right now, with no key and no funds. |
| `VERIFIED-LIVE` | Observed on Somnia Shannon. The chain is the record. |
| `MEASURED` | A number we measured, stated with the method that produced it. |
| `MODELED` | Reasoned from the code and the primitives. Not observed. Labelled as such. |

Addresses referred to below live in `contracts/deployed.json` and in the tables in
[README.md](README.md) and [JUDGES.md](JUDGES.md). Captured transaction links from the final
recorded run are collected in [PROOF.md](PROOF.md).

---

## REPRODUCIBLE

| claim | how to check |
| --- | --- |
| The eight contracts compile and the suite passes with zero failures. | `bash contracts/setup.sh && cd contracts && forge test` |
| A desk can never spend past its per-window cap or its daily budget, can never trade without a passing verdict, and stays halted once halted. | `contracts/test/PolicyLib.invariant.t.sol` — invariant campaign, `fail_on_revert = true`, pinned fuzz seed. |
| `PolicyLib` never reverts, and its checks always report the same first failure in the same order. | `contracts/test/PolicyLib.t.sol` |
| A desk that reverts, loops, has no code or has no credit is skipped by name and does not take the rest of the fan-out down with it. | `contracts/test/LucidRouter.t.sol` |
| Every address in `deployed.json` carries code; the router is above the 32 SOMI floor; its subscription matches the venue; the demo desk is armed and holds real collateral. | `bash contracts/verify-onchain.sh` |
| The brain's quote is stage 1 plus stage 2, each re-derived from the agent platform's own `getAdvancedRequestDeposit` rather than taken on the brain's word. | `verify-onchain.sh`, section 10 |
| The committee's on-chain verdicts, joined to how those windows actually settled, produce the metrics in `EVAL.md` against a constant-50% control and 20,000 coin-flip twins. | `cd eval && npm install && npm run eval` |
| The typed client decodes real Shannon logs and enforces the venue's traps (stale `Trading` rows, the 90-second slack, `Finalized` as the only terminal status). | `cd kit && npm install && npm test` |
| All seven Lucid contracts and the demo desk clone are source-verified on Blockscout. | Explorer links in [JUDGES.md](JUDGES.md) |
| The `Refusal` enum is append-only, and every value has one distinct meaning. | `contracts/src/types/LucidTypes.sol` |

## VERIFIED-LIVE

| claim | evidence |
| --- | --- |
| The router owns a live reactivity subscription on DreamDEX's real `MarketCreated` — emitter `0x3ecC694C…`, topic0 `0xb5ec75cd…`, handler the router itself, gas limit 100,000,000. | `somnia_reactivityGetSubscriptions` / `…GetSubscriptionInfo`; `verify-onchain.sh` section 3 |
| Handlers execute as validator-run synthetic transactions in the same block as the venue event, with no process of ours running. | `MarketSeen` and `SettlementScheduled` logs from the last few minutes; `verify-onchain.sh` section 4/5 |
| In-handler context is `msg.sender == 0x0100`, `tx.origin == the subscribing contract`, `msg.value == 0`. | Day-0 reactivity spike on Shannon |
| `Schedule` one-shots fire on time at a millisecond timestamp. | Day-0 reactivity spike |
| Somnia's agent committee answers on chain: 3 of 3 validators, status `Success`, one receipt per validator. | Day-0 committee spike; `VerdictReceived` on the brain |
| The two-stage brain runs end to end on chain — price committee, then inference committee. | 15-minute live run: 6 `VerdictRequested`, 6 `PriceReceived`, 6 `VerdictReceived`, 0 errors, 0 skips |
| The desk refuses on chain, with the reason in the log. | Every desk decision in that run was `Refused(LowEdge)` |
| The router reacted to 40 venue markets and scheduled 40 settlement one-shots in 15 minutes with no failures. | Same run: 40 `MarketSeen`, 40 `SettlementScheduled` |
| A contract can run the whole Event-Contracts loop with zero off-chain signatures: `faucet`, `approve`, `mintSet`, `placeBinaryOrder(POST_ONLY)` on both sides, `cancelOrder`. | Day-0 execution spike from a contract; the resting quote was visible in `getBookLevels` on the live book |
| `mintSet` needs no counterparty: 100 tUSDC in, 100 UP and 100 DOWN out, called by a contract. | Day-0 execution spike |
| An ordinary account can register its own operator, venue, `MarketCreator` and series, and the venue's oracle resolves the resulting windows exactly as it resolves DreamDEX's own. | `verify-onchain.sh` section 13 — a `Finalized` market on our own venue with a winning outcome; a rolled 300-second window answered one second after expiry with `payoutNumerators = [10000000, 0]` |
| A desk is an ERC-1167 clone created by the factory, registered with the router, armed, and holding real tUSDC. | `verify-onchain.sh` sections 1, 7, 8 |
| The venue's live testnet book is usually empty, which is why the `Maker` path exists. | Indexer: most live windows have `tradeCount: 0` |

## MEASURED

| number | method |
| --- | --- |
| **0.36 SOMI** per verdict — 0.12 for the price stage, 0.24 for the inference stage. | `brain.quote()` on chain, cross-checked against `getAdvancedRequestDeposit` plus the per-validator rewards (0.03 for the feed, 0.07 for the LLM) at a committee of 3. |
| **~8.3 SOMI/hour** to run the router with venue-wide upkeep attached. | Router balance drain over an hour of live operation. The venue created about 40 markets per 15 minutes; each one costs a creation firing at roughly 0.017 SOMI plus the wake-ups it books, and verdicts run on top at 0.36 each. |
| **0.003–0.01 SOMI** per handler firing in the day-0 spikes; ~0.017 under the live deployment's heavier handlers. | Balance delta across firings. |
| **~34 SOMI/hour** for `Continuous` series mode. | 2.8 SOMI of creator float per rolled window (two oracle questions at 1.296 plus the 0.2 resolve reserve) × 12 windows/hour on the 300-second cadence. |
| **61.6M gas** for one `triggerRoll`. | Live call on Shannon. It is why `HANDLER_GAS_LIMIT` is 100M. |
| **1,314,773 gas** for one `LucidDesk.onVerdict`. | `cast estimate` against real chain state. The first router shipped a 1,000,000 stipend and every desk call ran out of gas. |
| **~250,000 gas** for a single SSTORE plus an event on Somnia. | Measured on Shannon. Roughly five to ten times a mainnet Ethereum equivalent. |
| A handler subscribed at **2,000,000 gas** is charged in full (0.014 SOMI) and never executes — no revert, no logs, no state change. 3M and 5M both work. | Reproduced on Shannon; written up as B1 in [SDK_FEEDBACK.md](SDK_FEEDBACK.md). |
| **~16.5M gas** to relay a full 64-entry redemption queue. | Measured; the router therefore drains 16 per settlement firing and leaves the rest for anyone to finish. |
| Committee round trip: **~40 s** in the day-0 spike, **~1 s** in a later live run. | Timestamps on the request and the callback. The spread is exactly why `requiredSlack()` is measured by the contract instead of hard-coded. |
| Live testnet book parameters: tick = minQuantity = lotSize = **1000**, `oneCollateral` = **1e6**. | `getOrderBookParameters()` on a live pool. The indexer returns `null` for all three — see S5 in [SDK_FEEDBACK.md](SDK_FEEDBACK.md). |
| Venue lifetime: **10,642 markets / 83,770 USDso**, about 7.9 USDso per market, with four addresses providing essentially all quotes. | Indexer aggregate over the mainnet venue. |

## MODELED

| claim | reasoning |
| --- | --- |
| Asking the committee halfway into a window produces a more answerable question than asking at creation. | These windows settle against the price they opened at, so at `tradingStart` spot equals strike and the question has no content — which is what the first live run showed, three validators returning exactly 50. Moving the question later gives spot room to leave the strike. The improvement itself has not yet been measured over enough settled windows to claim. |
| 32 desks fit inside one 100M-gas handler firing even when several of them place orders. | Sized against the measured per-desk cost, and backstopped by `_stipend`, which degrades the tail of the list into named skips rather than into a lost firing. Not demonstrated with 32 live desks. |
| The committee-fee split converges. | Dropping an unaffordable desk only ever raises the share for those left, so the iteration is monotone and bounded by `MAX_FANOUT` rounds. |
| `Maker` adds real depth to a venue whose books are mostly empty. | The mechanism is verified live from a contract — `mintSet` needs no counterparty and both `POST_ONLY` legs rested in the live book — but no `LucidDesk` in `Maker` mode has rested an order on chain yet. See [MOCKS.md](MOCKS.md). |
| A cross-exchange median is a better price input than a single venue endpoint. | A single endpoint can geo-block part of a validator set, costing a committee member on every request; a median across seven exchanges with a source count and a staleness stamp cannot be geo-blocked out of existence. Not A/B tested. |
| One shared router is the only viable subscription topology. | The precompile checks the 32 SOMI floor against the *calling* contract, so per-desk subscriptions would lock 32 SOMI per user. |
| Running the venue's permissionless upkeep for every market benefits the venue. | Markets that are never finalized never pay out and pools that are never released are never recycled. We already pay for a subscription that wakes on every market, so the marginal cost is gas. Whether anyone else was going to run it is not something we can observe. |

---

## NOT CLAIMED

Stated plainly, because the absence of a claim is easy to miss.

- **We do not claim the strategy is profitable.** Neither `AiEdge` nor `Maker` has been run long
  enough, or at enough size, for a P&L number to mean anything. There is no backtest in this
  repository presented as evidence of returns, and there is no returns figure anywhere in it.
- **We do not claim the committee has predictive edge beyond what [EVAL.md](eval/EVAL.md) reports.**
  The harness is pre-registered, read-only, and published whatever it found, including a negative
  result. Read it before assuming anything about accuracy or calibration.
- **We do not claim mainnet readiness.** This is Shannon testnet only, with faucet tUSDC. Several
  operating parameters are sized for a testnet float rather than for production.
- **We do not claim an audit.** Nothing here has been audited. Neither have the DreamDEX binary
  contracts underneath — the published Hacken audit covered the spot venue only, and the binary
  contracts have no public source.
- **We do not claim `redeemFor` works with contract signatures.** EIP-1271 support in the venue's
  `redeemFor` is untested on Shannon. `LucidRelay` verifies ECDSA signatures itself and therefore
  serves externally owned accounts; whether a contract-signed authorization is accepted by the
  module is unknown, and we have not tried it.
- **We do not claim `placeBinaryOrderFor` works.** It exists on the module and is unwired in the
  SDK. We have never exercised it, and no code here depends on it.
- **We do not claim the price the committee reads is the price the window settles on.** Stage one
  reads Somnia's on-chain price-oracle agent; DreamDEX settles against its own Prophecy Oracle.
  Those are different series and the basis between them is not measured here.
- **We do not claim the keeper has performed venue upkeep at scale.** Its on-chain counters are
  public via `counts()`; read them rather than taking a number from us.
- **We do not claim a 60-second window can be traded.** It cannot, by construction. See the honest
  limits in [README.md](README.md).
