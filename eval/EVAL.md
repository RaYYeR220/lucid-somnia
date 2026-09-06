# Evaluating the Lucid committee

An observational, pre-registered grading of the verdicts `LucidBrain`
(`0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25`) has written on Somnia Shannon testnet, chain 50312,
against how those windows actually settled.

Snapshot: run **2026-09-06T22:19:02Z**, blocks **481 521 686 → 481 599 789**. Every number below is
from that run. Re-running regrades from scratch and the numbers move; see
[Re-running](#re-running-and-growing-the-sample).

---

## Headline

**On this sample the committee gets the direction right more often than a coin flip and prices it
far worse than saying nothing.** Directional accuracy is **72.2 % (13 of 18 decisive calls)**,
one-sided exact binomial **p = 0.0481** under H₀ = 0.5, and only 4.84 % of 20 000 same-boldness
random twins matched or beat it. Over the same 21 rows the **Brier score is 0.3653**, against **0.2500** for
a predictor that says "50 %" to everything and knows nothing. Both halves are the result. The
committee answers 0 % and 100 % where the truthful answer is nearer 60 %, and Brier punishes exactly
that: it is often right about the sign and wildly overconfident about the magnitude.

Two things immediately qualify the accuracy half, and they are in this paragraph rather than a
footnote because they are decisive for how it should be read. **The sample drifted up**: 16 of 21
windows closed UP (76.2 %; P(X ≥ 16 | n = 21, p = 0.5) = 0.0133). A rule as dumb as *always say UP*
would have scored **14 of 18** on the identical decisive rows and a Brier of **0.2381** — better than
the committee on both metrics. And **the directional result is carried entirely by eight barely
decisive calls**: the committee's 51 % calls went 8 for 8, while every other decisive call together
went 5 for 10 — exactly chance — and the nine confident 0 % calls contributed 0.2381 of the total
0.3653 Brier on their own. So the p-value is against a fair-coin null in a sample whose own base rate
was not a fair coin.

**n = 21 is small.** Three of ten calibration deciles are populated, one of them by a single row. A
one-sided p just under 0.05 at this size is suggestive and is not a finding.

---

## What changed since the previous report

The previous version of this file reported a degenerate forecast: every verdict at exactly 50.00 %,
zero dispersion, a Brier identical to the constant-50 control. That was a real measurement of a
broken pipeline, and two causes were found and fixed. Both explain the discontinuity in the data, so
neither the old numbers nor the new ones are comparable across the fix.

1. **The committee was asked at the wrong moment.** The verdict was requested when the market was
   created. For these markets the strike *is* the window's opening price, so at `tradingStart` spot
   equals strike by construction and "will it close above the strike" has no answer but a coin flip.
   The question is now put at the halfway point of the window, once the price has had time to move
   away from the strike — `LucidRouter._decisionSec` and `DECISION_POINT_BPS`, with the case pinned
   in `contracts/test/LucidRouter.t.sol::test_nothing_is_asked_at_creation_and_the_decision_is_booked_halfway_in`.

2. **The prompt was anchoring the committee.** When no side of the order book quoted, the router
   substituted 5000 bps and the prompt then stated it as the market's implied probability — and then
   asked the committee to disagree with a number the protocol had invented. Measured on the live
   three-validator committee with everything else held identical: a window +776 bps through the
   strike with eight seconds left scored a median of **50** with `Book-implied UP probability:
   50.00%` in the prompt and **95** with that one sentence deleted; the mirror-image bearish twin
   scored **0**. The sentence is now omitted entirely when no book was observed, and the sentinel
   that says so (`LucidTypes.BOOK_UNOBSERVED`, 65535) sits outside the probability range so it can
   never be clamped back into one. See the comments on `PromptLib._book` and
   `LucidRouter._pBookForPrompt`, and `contracts/test/PromptLib.t.sol`.

Platform-level findings from the same deployment are in [`../SDK_FEEDBACK.md`](../SDK_FEEDBACK.md).

---

## 1. Method, pre-registered

Stated as a protocol, before any number. Everything below is fixed in `run.ts`; the code is the
registration.

### Why this is genuinely pre-registered

The obvious way to build this — take settled windows, feed them back through the brain, compare — is
worthless here, and quietly so. `LucidBrain` fetches spot at call time, so replaying a window that
closed an hour ago prices it with the price *now* and returns something that looks exactly like a
result. That is a leak of the answer into the question.

So the harness never calls the brain. It reads what the brain already committed to a block:
`VerdictReceived(marketId, requestId, probUpBps, responded, agreed, ok, scores)` is a probability
written on chain with a timestamp, before the window closed. The outcome is read separately, from
the venue's indexer, after settlement. **At the instant each verdict was written its outcome did not
exist anywhere** — not in the contract, not in the indexer, not in the world. Nothing about the
grading can be tuned after the fact without changing a number that is already immutable in a block.

The harness signs nothing, sends nothing and costs nothing.

### Sample rule

The population is **every `VerdictReceived` log the deployed brain emitted**, from its deployment
block to chain head, with no selection of any kind. Logs are paged in 950-block windows because
Somnia rejects an `eth_getLogs` span wider than 1000 blocks outright (`block range exceeds 1000`).

Two samples, both declared here so neither is a post-hoc pick:

- **PRIMARY** — verdicts the protocol itself marked tradeable (`ok == true`) whose market has since
  settled. This is what a desk was actually allowed to act on.
- **SECONDARY** — every verdict the committee answered (`responded > 0`, non-empty `scores`) whose
  market has settled, tradeable or not. This catches answers that arrived too late to trade but were
  still real forecasts.

### Exclusion rules

A verdict is excluded, and counted under its reason, when:

- **`no-committee-answer`** — `responded == 0` or `scores` is empty. `handleResponse` writes
  `probUpBps = 0` when the agent platform failed or timed out. That zero is a structural absence, not
  a confident forecast of "0 % up"; grading it would invent an opinion the committee never held.
- **`not-in-indexer`** — the brain priced a window the indexer has not surfaced yet.
- **`not-finalized`** — `clobStatus` is not the terminal `"Finalized"`, or `finalized != true`. The
  terminal status on this venue is the literal string `"Finalized"`; it is never `"Resolved"`, a
  value that does not exist in the schema and that a filter written against it matches forever
  without erroring.
- **`no-payout`** — **finalized with an all-zero payout vector and a null `winningOutcome`.** The
  market is terminal but nothing settled and no side won. That is an unresolved window, not a loss.
  Scoring these would manufacture wrong answers out of absent ones.
- **`voided`** — both legs paid, so no side won.
- **`inconsistent-payout`** — `winningOutcome` and `payoutNumerators` disagree; when two independent
  statements of the same fact conflict, neither is trustworthy enough to grade against.

Outcome index 0 is YES on this venue, and YES is "at or above the strike", i.e. UP.

### Metrics

Computed from observed rows only. Anything that cannot be computed is `n/a`, never a default.

- **Forecast dispersion** — distinct values, range, standard deviation. Declared first because it is
  the only thing that separates "the committee was wrong" from "the committee never said anything",
  and a Brier score alone cannot tell those apart.
- **Directional accuracy** against the 50 % line. Exactly 50 % is an abstention, not a coin flip the
  committee happened to lose: excluded from numerator and denominator, reported separately. With a
  one-sided exact binomial p-value under H₀ = 0.5, computed with integer coefficients.
- **Brier score** — mean squared error against the realised binary outcome. 0.25 is what saying
  nothing scores.
- **Calibration** — ten deciles, each with count, mean forecast and realised UP frequency.
- **Mean absolute deviation from the book-implied probability**, from the desk's own
  `VerdictReceived(marketId, probUpBps, pBookBps, responded)`. (This metric is broken in the current
  harness — see [Defects](#defects-found-in-the-harness-itself).)
- **Refusal and skip breakdown.** The rate at which a mandate declines to act is as much a
  measurement of the system as its hit rate.

### Negative controls

Fixed before the fact, run on the identical sample, seed `0x1ec1d`, 20 000 draws, so the numbers are
reproducible rather than re-rollable.

- **Constant 50 %** — 0.5 on everything, Brier 0.25 by construction. The floor a forecast must clear
  before it has said anything.
- **Coin flip, same boldness** — keeps the committee's own distance from 50 % on each row and
  randomises only the sign. A flat-50 % twin would be a strawman: it can never be confidently wrong,
  so beating it proves nothing. Keeping the confidence and destroying the direction isolates the only
  thing under test — whether the direction carried information. Reported as mean Brier, mean
  accuracy, and the fraction of twins that matched or beat the committee, which is an empirical
  p-value.

---

## 2. Pre-condition: does the committee discriminate at all?

The previous report could not separate "the committee is broken" from "the question was empty". That
needed a direct probe, so one was run against the same agent platform and the same agent id the
product uses, three validators per request, median taken the same way:

| Prompt | Committee scores | Median |
|---|---|---|
| `Reply with the integer 87 and nothing else.` | 87, 87, 87 | **87** |
| `Reply with the integer 12 and nothing else.` | 12, 12, 12 | **12** |
| `BTC trades at 80500. Threshold 60000. Settles in 3 seconds. Percent probability above?` | 85, 85, 85 | **85** |
| `BTC trades at 80500. Threshold 99000. Settles in 3 seconds. Percent probability above?` | 0, 0, 0 | **0** |

The committee follows instructions and it discriminates on the domain question. That establishes
that the constant 50 in the earlier production sample was a property of the question being asked,
not of the committee answering it.

It also foreshadows the calibration result: **85 for a three-second window 34 % out of the money is
already under-confident**, and 0 for the mirror case is over-confident in the other direction. The
same shape shows up in production below.

This probe writes on chain and is not part of `run.ts`, which is read-only and never asks the
committee anything. It is reported here as a stated measurement, not as harness output.

---

## 3. Results

| | |
|---|---|
| Chain | Somnia Shannon 50312 |
| Brain | `0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25` |
| Router | `0x6aE21a20444141552648C1f8443bAf171BCCcB99` |
| Factory | `0xF82cC4219F6c7fe816155A8c3F0C9C3B1cc320eA` |
| Desks discovered | 2 (`0x86d1…49ea` AiEdge, `0xd44b…6fac` maker) |
| Blocks scanned | 481 521 686 → 481 599 789 (78 104 blocks, 83 pages of 950) |
| Chain time covered | 2026-09-06T20:08:45Z → 22:18:57Z (2 h 10 m) |
| Verdicts span | 20:17:31Z → 21:52:32Z (95 minutes), expiries 20:20Z → 21:55Z |
| Markets | 300-second BTC/USDC and ETH/USDC windows only (11 BTC, 10 ETH) |

### Sample

| | |
|---|---|
| `VerdictReceived` on the brain | **21** |
| — with a committee answer | 21 |
| — failed closed (no answer at all) | 0 |
| — `ok == false` (never tradeable) | 0 |
| **Graded, PRIMARY** (`ok`, market settled) | **21** |
| **Graded, SECONDARY** (answered, settled) | **21** |
| Excluded | **none** |

Every verdict came back `responded = 3`, `agreed = 3`, `ok = true`, and every window in the scan had
settled by the time the harness ran, so PRIMARY and SECONDARY are the same 21 rows and every metric
below is identical for both. They will diverge as soon as the platform times out or a verdict lands
after expiry.

### Metrics — PRIMARY = SECONDARY (n = 21)

| Metric | Value |
|---|---|
| Realised UP rate in sample | **76.2 %** (16 of 21 windows closed up) |
| Forecast dispersion | **4 distinct values**, 0.0 % … 100.0 %, sd **0.2902** |
| **Brier score** | **0.3653** |
| **Directional accuracy** | **72.2 %** — 13 of 18 decisive, 3 abstained at exactly 50 % |
| Exact binomial p (one-sided, H₀ = 0.5) | **0.0481** |
| Mean \|committee − book\| | 6.1302 over 6 rows (15 carried no book quote) — **invalid, see Defects** |

Calibration:

| Bucket | n | Mean forecast | Realised UP |
|---|---|---|---|
| 0.0 – 0.1 | 9 | 0.0 % | **55.6 %** |
| 0.5 – 0.6 | 11 | 50.7 % | **90.9 %** |
| 0.9 – 1.0 | 1 | 100.0 % | 100.0 % |

Seven of ten deciles are empty and the top one holds a single row. The 0.0–0.1 line is the whole
calibration story: the committee said 0 % nine times and those windows closed up more often than
not.

### Negative controls — identical sample

| Predictor | Brier | Directional accuracy |
|---|---|---|
| **Committee** | **0.3653** | **72.2 %** (13/18) |
| Constant 50 % | **0.2500** | n/a by construction |
| Coin flip, same boldness (20 000 draws, seed `0x1ec1d`) | 0.3695 | 49.9 % |

| Empirical p | |
|---|---|
| P(random twin ≥ committee, Brier) | **37.70 %** |
| P(random twin ≥ committee, accuracy) | **4.84 %** |

The committee **beats the coin flip on accuracy and loses to constant 50 % on Brier**. Note that its
Brier win over the flip (0.3653 vs 0.3695) is noise: 37.7 % of twins scored at least as well. Only
the accuracy column separates it from the false twin.

### Where the forecast actually sat

The four distinct values, with what happened to each:

| Forecast | n | Windows up | Directional | Brier on the subset | Contribution to the 0.3653 |
|---|---|---|---|---|---|
| 0 % | 9 | 5 | **4 / 9 correct** | 0.5556 | **0.2381** |
| 50 % | 3 | 2 | abstained | 0.2500 | 0.0357 |
| 51 % | 8 | 8 | **8 / 8 correct** | 0.2401 | 0.0915 |
| 100 % | 1 | 1 | 1 / 1 correct | 0.0000 | 0.0000 |

Per asset: BTC 8 of 11 decisive calls correct (7 of 11 windows up); ETH 5 of 7 (9 of 10 windows up).

**Every verdict was unanimous to the integer.** The three validators returned `[0,0,0]`,
`[50,50,50]`, `[51,51,51]` or `[100,100,100]` — never a split, on any of the 21 rows. `agreed = 3` on
all of them. The committee produced consensus but, in this sample, no ensemble diversity: the median
equals every member's answer, so the three-validator structure bought agreement and no variance
reduction.

### Refusals and skips

| Source | Reason | Count | What it is |
|---|---|---|---|
| Desk `Refused` | `NoBook` | **6** | The AiEdge desk declining to measure an edge against a book nobody quoted. All six carry `pBookBps = 65535`, the unobserved sentinel. |
| Desk `Refused` | `VenueRejected` | **6** | The maker desk turned away by the venue when it tried to stand up a two-sided quote. |
| Router `Skipped` | `NO_CREDIT` | **50** | The router reporting that a desk had run out of gas credit rather than fanning out and pretending otherwise. |
| Router `Skipped` | `ROUTER_FLOAT` | **4** | The router's own float below its reserve at that instant. |

Float at run time: brain **7.928 STT**, router **32.634 STT**.

Three things this says that the totals do not:

- **Only 6 of the 21 verdicts reached a desk at all.** Both current desks were created at 21:41Z,
  near the end of the sample, and each saw the same six verdicts (four at 51 %, one at 50 %, one at
  0 %) and refused all six. Nothing was traded on committee signal in this window, so there is no
  P&L here — only forecasts.
- **`NoBook` is arithmetically the only refusal the AiEdge desk could have produced.** No side of the
  book quoted on any of the six, so there was no edge to compute. `LucidDesk` refuses rather than
  substituting a midpoint, which is the same discipline as the prompt fix above, one layer down.
- **`VenueRejected` names the venue, not which check.** One enum value covers three distinct failures
  in `_make`: the order-book parameter read, the quote pair, and the `mintSet` call. The event alone
  does not say which of the three fired, so the honest reading is that the maker never got a
  two-sided quote up — not why. That is a granularity gap in the refusal enum, not a finding about
  the venue.

### Verbatim output

```
Lucid committee evaluation - observer, read-only
  chain                                  Somnia Shannon 50312
  rpc                                    https://api.infra.testnet.somnia.network
  indexer                                https://dev.smk.somnia.host/v1/graphql
  brain                                  0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25
  router                                 0x6aE21a20444141552648C1f8443bAf171BCCcB99
  scanned blocks                         481521686 -> 481599789 (78104 blocks, 83 pages of 950; start from cache)
  head block time (UTC)                  2026-09-06T22:18:57.000Z

sample
  VerdictReceived on the brain           21
    with a committee answer              21
    failed closed (no answer at all)     0
    ok = false (never tradeable)         0
  graded PRIMARY (ok, market settled)    21
  graded SECONDARY (answered, settled)   21

excluded from grading, by reason
                                         nothing excluded

PRIMARY - verdicts the protocol marked tradeable (ok = true)
  graded verdicts (n)                    21
  realised UP rate in sample             76.2 %
  forecast dispersion                    4 distinct value(s), 0.0 %..100.0 %, sd 0.2902
  Brier score (lower is better)          0.3653
  directional accuracy                   72.2 % (13/18 decisive, 3 abstained at exactly 50 %)
    exact binomial p (one-sided)         0.0481
  mean |committee - book|                6.1302 over 6 rows (15 carried no book quote)

  calibration (decile -> realised UP frequency)
    bucket          n    mean p  realised
    0.0-0.1         9     0.0 %  55.6 %
    0.5-0.6        11    50.7 %  90.9 %
    0.9-1.0         1   100.0 %  100.0 %

  negative controls on the identical sample
    constant 50 % - Brier                0.2500
    coin flip (same boldness) - Brier    0.3695 mean of 20000 draws
    coin flip - directional accuracy     49.9 %
    P(random twin >= committee, Brier)   37.70 %
    P(random twin >= committee, acc.)    4.84 %
    verdict vs controls                  beats the coin flip only

refusals - desk Refused, by reason
    NoBook                               6
    VenueRejected                        6

skips - router Skipped, by reason
    NO_CREDIT                            50
    ROUTER_FLOAT                         4

float (context for any funding-shaped refusal or skip)
  brain                                  7.9281084092 STT
  router                                 32.633850218 STT
```

The SECONDARY block is identical and is omitted here; it is in `results.json` in full, along with
every graded row, the raw per-validator scores and the settlement decision for each market.

---

## 4. Interpretation

**The committee has some directional signal and is badly calibrated.** Those are two separate
statements and both are supported by the table above.

*Calibration.* This is unambiguous. The committee said **0 %** nine times, and those windows closed
UP five times out of nine. A forecast of 0 % that is realised 56 % of the time is not a small error;
it is the largest error the scale allows. Those nine rows alone contribute 0.2381 of the total Brier
of 0.3653 — 65 % of the loss from 43 % of the sample. This is the same shape the discrimination
probe showed at the top: the committee reaches for the rails. Nothing in the 21 rows sits between
51 % and 100 %, or between 0 % and 50 %. It answers as if it were classifying, not pricing. That is
why a predictor that always says 50 % beats it on Brier while knowing nothing: it never pays the
price of a confident miss because it is never confident.

*Direction.* This is where the honesty has to be applied, because the number looks better than the
evidence behind it.

- 13 of 18 decisive is p = 0.0481 against a fair coin, and 4.84 % of same-boldness random twins did
  as well or better. Taken at face value, that clears the pre-registered control.
- But the sample's own base rate was 76 % UP, which is itself unlikely under a fair coin
  (P(X ≥ 16 | 21, 0.5) = 0.0133). Both assets drifted up across the 95 minutes sampled. Against that
  background, **always saying UP scores 14 of 18 and a Brier of 0.2381** — better than the committee
  on both. The fair-coin null is the wrong null for this sample, and it is the null the p-value uses.
- The signal is also concentrated in the least confident calls. The 51 % cluster went 8 for 8; the
  0 % cluster went 4 for 9. A committee whose near-midpoint calls are perfect and whose extreme calls
  are coin flips is not obviously a committee with a view. In an up-drifting sample, a marginal
  upward lean is nearly free.

The defensible statement is therefore narrower than the headline number: **on 21 windows over 95
minutes the committee's forecasts were no longer degenerate, its direction beat a same-boldness
random twin, its magnitude was worse than useless, and a trivial always-UP rule beat it on the same
rows.** The first of those is new information — the pipeline now produces a forecast that varies.
The rest is not yet a claim about skill.

*What the run does establish regardless of sample size.*

- The measurement path works end to end: verdicts are on chain, outcomes are joinable, the join is
  honest, and the whole thing is reproducible from public data with no key and no cost.
- The two fixes changed the data, not just the story. Dispersion moved from 1 distinct value to 4 and
  sd from 0.0000 to 0.2902 over the same venue, the same assets and the same cadence.
- The refusal path is doing its job. Six verdicts reached a desk, six were refused, and the reasons
  name a missing book and a venue that would not take the quote. A desk that had traded on an
  unobservable book would be the actual finding, and a much worse one.
- The harness returns bad news. It returned "beats neither control" last time and "loses to constant
  50 % on Brier" this time, both in the headline.

---

## 5. What would change the conclusion

- **A larger sample.** n = 21 has no power. The 51 %-cluster result (8/8; p = 0.0039 taken alone,
  though that subset was chosen after seeing the data and the p-value is not honest as stated) is the
  single most interesting number here and it rests on eight rows. Two verdicts per five-minute
  window means roughly 24 an hour; a few hundred rows is one overnight gap. At n in the hundreds the
  base-rate confound above washes out or does not, and the answer stops depending on which two hours
  were sampled.
- **A sample that is not one-directional.** Every conclusion here is entangled with a 76 % UP window.
  A sample spanning both drifts would separate "predicts the market" from "leans up".
- **A calibrated committee.** The Brier result is not a statement that the committee knows nothing;
  it is a statement that its numbers are not probabilities. Two cheap interventions would test that
  directly: an explicit instruction against the rails, or a post-hoc shrink toward the base rate
  (mapping 0 → 0.2, 100 → 0.8, say) applied on chain and then graded by this same harness. If the
  direction is real, shrinking alone moves the Brier below 0.25 without adding any information.
- **A book to measure edge against.** Every one of the six desk-side rows carried the unobserved
  sentinel. Until some side of the venue's book quotes, "edge versus the market" is unmeasurable and
  `NoBook` will keep being the correct answer — which also means the `AiEdge` mandate has not yet
  been exercised on a real quote.
- **Funded desks.** 50 `NO_CREDIT` skips means most verdicts never reached a mandate at all. There is
  no execution result in this document because there was no execution.

---

## Defects found in the harness itself

Found while writing this report, from the same run. Both are in `eval/`, neither changes the
committee metrics above, and both are stated here rather than quietly fixed.

1. **`mean |committee − book|` is invalid in this sample.** All six rows carrying a `pBookBps`
   carried **65535** — `LucidTypes.BOOK_UNOBSERVED`, the sentinel for "no side of the book quoted".
   `metrics.ts::meanAbsoluteDeviation` treats it as a number, so 65535 bps enters the arithmetic as a
   probability of 6.5535 and produces the reported 6.1302. The contracts guard against exactly this
   (`LucidDesk`: "a value that encodes ABSENCE must never be an arithmetic input"); the harness does
   not. The correct reading of that row is **zero rows had an observed book**, and the metric should
   report `n/a`.
2. **Desk discovery misses desks created before the brain's deployment block.** The scan window is
   anchored on the brain, which has been redeployed; desks registered with the router before that
   block are found neither by `DeskCreated` in range nor in `deployed.json`. In this run the router
   fanned out to **four** desks and the harness scanned **two**. Verified directly against the same
   block range: the two undiscovered desks (`0x7a31…58c0`, `0xb8d3…5644`) took 19 `NO_CREDIT` skips
   each and emitted **30 further refusals** — 15 `NoBook`, 13 `CapExceeded`, 2 `InsufficientFunds` —
   that the refusal table above does not include. The reported refusal breakdown is complete for the
   two current desks and covers 12 of the 42 refusals actually emitted in the scanned range.

---

## Re-running and growing the sample

```sh
cd eval
npm install     # once
npm run eval    # or: npx tsx run.ts
```

Node 20+, `viem` the only dependency. There is no state to reset and no flag to pass. Each run
rescans from the brain's deployment block to current head and regrades everything settled since,
including rows excluded last time as `not-finalized` or `not-in-indexer` — those resolve on their own
within minutes. Optional overrides: `LUCID_FROM_BLOCK`, `LUCID_RPC_URL`, `LUCID_INDEXER_URL`. After a
redeploy, delete `.scan-cache.json`.

The number that decides how much a run is worth is **graded PRIMARY**, printed first.

**Everything in this file is a snapshot.** Chain 50312, blocks 481 521 686 → 481 599 789, head block
time 2026-09-06T22:18:57Z, run 2026-09-06T22:19:02Z, n = 21. A later run covers a different and
larger window and will produce different numbers; the ones here are not updated in place, and any
number quoted from this document should be quoted with that block range attached.

---

## Limits, stated plainly

- **n = 21.** No claim here has the power to detect a real edge or to rule one out.
- **95 minutes, one venue, one cadence, two assets.** Every graded window is a 300-second BTC/USDC or
  ETH/USDC window. Longer cadences and other assets are untested.
- **The sample drifted up** (16 of 21). This is the dominant confound and it is not correctable
  after the fact — only outgrown.
- **The committee was unanimous on every row.** Whether three validators are adding anything over one
  cannot be answered from a sample with zero within-committee dispersion.
- **Zero trades on committee signal.** This measures forecasts, not execution, not P&L, not slippage.
- **Settlement comes from the venue's indexer.** If the indexer is wrong, this is wrong. The payout
  vector and `winningOutcome` are cross-checked against each other, which catches inconsistency but
  not a consistent error.
- **The discrimination probe in section 2 is not harness output** and is not reproduced by `run.ts`.
  It is reported as measured.
