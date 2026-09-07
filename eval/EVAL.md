# Evaluating the Lucid committee

An observational, pre-registered grading of the verdicts `LucidBrain`
(`0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25`) has written on Somnia Shannon testnet, chain 50312,
against how those windows actually settled.

Snapshot: run **2026-09-07T04:36:34Z**, blocks **481 521 686 → 481 825 872**, n = 62. Every number
below is from that run. Re-running regrades from scratch and the numbers move; see
[Re-running](#re-running-and-growing-the-sample).

---

## Headline

**The committee still prices worse than saying nothing, and it still fails the harness's own
control.** Over 62 graded windows the **Brier score is 0.3598**, against **0.2500** for a predictor
that answers "50 %" to everything and knows nothing, and **0.3574** for a same-boldness random twin.
It loses to both. The harness prints `BEATS NEITHER CONTROL`, which is stronger criticism than the
last run produced. **No predictive edge is claimed here, and none is supported.**

What changed is the other half of the result, and it changed in a way that has to be stated
carefully. Directional accuracy is **69.6 % — 32 of 46 decisive calls**, one-sided exact binomial
**p = 0.0057**, and only **0.57 %** of 20 000 same-boldness random twins matched or beat it. The
previous report's dominant caveat was that the sample had drifted up 76 % and a rule as dumb as
*always say UP* beat the committee on both metrics. **That caveat is gone.** This sample closed UP
53.2 % of the time — a fair coin, essentially — and always-saying-UP now scores **28 of 46** and a
Brier of **0.4677**, worse than the committee on both. The confound was outgrown rather than
argued away.

That is as far as it goes, and here is why it goes no further. **The directional result is still
carried entirely by one bucket of near-abstentions.** The committee answered 51 % seventeen times and
went 17 for 17; every other decisive call together went **15 of 29**, which is chance. A 51 % answer
is one percentage point of conviction away from declining to answer, so what the accuracy column is
rewarding is a lean, repeated, that happened to be right — and that bucket was singled out after
seeing the data, which means its own p-value is not honest and is not quoted. Where the committee
actually commits, it is **anti-calibrated**: it said 0 % nineteen times and those windows closed UP
42.1 % of the time, and it said 90–100 % eight times and those closed UP 25 % of the time. Both rails
point the wrong way.

**n = 62 over 7 h 50 m, one venue, one cadence, two assets.** Four of ten calibration deciles are
populated, two of them by one and three rows. This is a bigger sample than last time and it is still
not a finding.

---

## What changed since the previous report

Three things, all of them in the data rather than in the reading of it.

1. **The sample tripled and the drift washed out.** n went 21 → 62 and the span 95 minutes → 7 h
   50 m. The realised UP rate went 76.2 % → 53.2 %. The previous report said the base-rate confound
   was "not correctable after the fact — only outgrown", and it has been.
2. **The committee's Brier got relatively worse.** Last run 0.3653 against a coin-flip mean of
   0.3695, a nominal win the report called noise. This run 0.3598 against 0.3574 — a nominal loss.
   Both differences are inside the same noise band (50.13 % of twins matched or beat the committee
   this time, 37.70 % last time); the honest reading of both runs is that **the committee's magnitude
   carries no information at all**, and the sign of the gap flipping is what "no information" looks
   like.
3. **The desks traded.** Last run had zero executions in the graded range and the refusal table
   covered forecasts only. This range contains real order placement, real settlements and a real
   counterparty fill, so the refusal and skip breakdown below is a measurement of a running system
   rather than of an idle one.

Both defects the previous report found in the harness itself have been fixed, and the fixes are
visible in the output rather than only in the code — see [Defects](#defects-found-in-the-harness-itself).

The two fixes that made the forecast non-degenerate in the first place — asking halfway into the
window instead of at creation, and deleting the invented book sentence from the prompt — are
unchanged and are described in `LucidRouter._decisionSec`, `PromptLib._book` and
`LucidRouter._pBookForPrompt`. Platform-level findings from the same deployment are in
[`../SDK_FEEDBACK.md`](../SDK_FEEDBACK.md).

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
  `VerdictReceived(marketId, probUpBps, pBookBps, responded)`, with the unobserved-book sentinel
  excluded rather than averaged.
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

The line the harness prints as `verdict vs controls` compares **Brier only**, against both controls.
That is deliberate: a forecaster is a probability, and the accuracy column alone cannot tell a
calibrated forecast from a lucky lean.

---

## 2. Pre-condition: does the committee discriminate at all?

An earlier report could not separate "the committee is broken" from "the question was empty". That
needed a direct probe, so one was run against the same agent platform and the same agent id the
product uses, three validators per request, median taken the same way:

| Prompt | Committee scores | Median |
|---|---|---|
| `Reply with the integer 87 and nothing else.` | 87, 87, 87 | **87** |
| `Reply with the integer 12 and nothing else.` | 12, 12, 12 | **12** |
| `BTC trades at 80500. Threshold 60000. Settles in 3 seconds. Percent probability above?` | 85, 85, 85 | **85** |
| `BTC trades at 80500. Threshold 99000. Settles in 3 seconds. Percent probability above?` | 0, 0, 0 | **0** |

The committee follows instructions and it discriminates on the domain question. That establishes
that a constant 50 in a production sample would be a property of the question being asked, not of the
committee answering it.

It also foreshadows the calibration result: **85 for a three-second window 34 % out of the money is
already under-confident**, and 0 for the mirror case is over-confident in the other direction. The
same shape shows up in production below, and this run has enough rows to show it at both rails at
once.

This probe writes on chain and is not part of `run.ts`, which is read-only and never asks the
committee anything. It is reported here as a stated measurement, not as harness output.

---

## 3. Results

| | |
|---|---|
| Chain | Somnia Shannon 50312 |
| Brain | `0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25` |
| Router | `0x6aE21a20444141552648C1f8443bAf171BCCcB99` |
| Factory | `0x9c1EF0C429f1F88e8247f3539DeF8a1f8FCCEb84` |
| Desks discovered | **8** — `router.allDesks()` 8, `deployed.json` seeds 2, `DeskCreated` in range 2 |
| Blocks scanned | 481 521 686 → 481 825 872 (304 187 blocks, 321 pages of 950) |
| Head block time | 2026-09-07T04:35:51Z |
| Graded verdict blocks | 481 526 946 → 481 808 874 |
| Expiries covered | 2026-09-06T20:20:00Z → 2026-09-07T04:10:00Z (7 h 50 m) |
| Markets | 300-second BTC/USDC and ETH/USDC windows only (31 BTC, 31 ETH) |

### Sample

| | |
|---|---|
| `VerdictReceived` on the brain | **64** |
| — with a committee answer | 64 |
| — failed closed (no answer at all) | 0 |
| — `ok == false` (never tradeable) | 0 |
| **Graded, PRIMARY** (`ok`, market settled) | **62** |
| **Graded, SECONDARY** (answered, settled) | **62** |
| Excluded — `not-finalized` | **2** |

Every verdict came back `responded = 3`, `agreed = 3`, `ok = true`. The two exclusions are the two
newest windows in the scan, which had not reached `Finalized` when the harness ran and will grade
themselves on the next run. PRIMARY and SECONDARY are therefore the same 62 rows and every metric
below is identical for both; they will diverge as soon as the platform times out or a verdict lands
after expiry.

### Metrics — PRIMARY = SECONDARY (n = 62)

| Metric | Value |
|---|---|
| Realised UP rate in sample | **53.2 %** (33 of 62 windows closed up) |
| Forecast dispersion | **8 distinct values**, 0.0 % … 100.0 %, sd **0.3156** |
| **Brier score** | **0.3598** |
| **Directional accuracy** | **69.6 %** — 32 of 46 decisive, 16 abstained at exactly 50 % |
| Exact binomial p (one-sided, H₀ = 0.5) | **0.0057** |
| Mean \|committee − book\| | **n/a** |

**`mean |committee − book|` is `n/a`, and that is the correct answer rather than a gap.** All 62
graded rows carried `pBookBps = 65535` — `LucidTypes.BOOK_UNOBSERVED`, the sentinel meaning no side
of the venue's book quoted. Zero rows had a real quote to measure against, zero rows were missing the
field, and zero rows carried a value outside 0..10000. The venue quoted neither side on any window in
this sample, so "how far is the committee from the market" has no market in it. The harness reports
`n/a` and names the reason and the count; it does not average a sentinel.

Calibration:

| Bucket | n | Mean forecast | Realised UP |
|---|---|---|---|
| 0.0 – 0.1 | 19 | 0.0 % | **42.1 %** |
| 0.4 – 0.5 | 1 | 49.0 % | 0.0 % |
| 0.5 – 0.6 | 34 | 50.6 % | **67.6 %** |
| 0.9 – 1.0 | 8 | 98.6 % | **25.0 %** |

Six of ten deciles are empty. The two populated rails are the whole calibration story and they both
point the wrong way: the committee said 0 % nineteen times and those windows went up more often than
two in five, and it said something near 99 % eight times and those windows went up one time in four.

### Negative controls — identical sample

| Predictor | Brier | Directional accuracy |
|---|---|---|
| **Committee** | **0.3598** | **69.6 %** (32/46) |
| Constant 50 % | **0.2500** | n/a by construction |
| Coin flip, same boldness (20 000 draws, seed `0x1ec1d`) | 0.3574 | 50.0 % |
| Always say UP | 0.4677 | 60.9 % (28/46) |
| Constant at the sample's own base rate (53.2 %) | 0.2490 | n/a by construction |

| Empirical p | |
|---|---|
| P(random twin ≥ committee, Brier) | **50.13 %** |
| P(random twin ≥ committee, accuracy) | **0.57 %** |

The first two rows and the two empirical p-values are harness output. The always-UP and base-rate
rows are computed here from the same `results.json`, because the previous report used always-UP as
the decisive counter-argument and it has to be re-run rather than quietly dropped when it stops
working. Denominators, so the columns are comparable: every **Brier** in this table is over all 62
graded rows, and every **accuracy** is over the same 46 rows the committee was decisive on — an
always-UP rule never abstains, and scoring it on rows the committee declined would be scoring two
different samples against each other.

**The committee loses to both pre-registered controls on Brier and beats the coin flip on accuracy.**
Its Brier gap over the flip (0.3598 vs 0.3574) is noise in the same way the previous run's gap in the
other direction was noise: half the twins scored at least as well. Only the accuracy column separates
it from the false twin, and the next table is why that column should not be read as skill.

### Where the forecast actually sat

The eight distinct values, with what happened to each:

| Forecast | n | Windows up | Directional | Contribution to the 0.3598 |
|---|---|---|---|---|
| 0 % | 19 | 8 | **11 / 19 correct** | **0.1290** |
| 49 % | 1 | 0 | 1 / 1 correct | 0.0039 |
| 50 % | 16 | 5 | abstained | 0.0645 |
| 51 % | 17 | 17 | **17 / 17 correct** | 0.0658 |
| 55 % | 1 | 1 | 1 / 1 correct | 0.0033 |
| 97 % | 3 | 0 | **0 / 3 correct** | 0.0455 |
| 99 % | 2 | 0 | **0 / 2 correct** | 0.0316 |
| 100 % | 3 | 2 | 2 / 3 correct | 0.0161 |

Read the two ends against the middle. The eight confident calls at 97 % and above went **2 of 8**.
The nineteen confident calls at 0 % went 11 of 19, barely better than a coin. The seventeen calls at
51 % — one point off abstention — went **17 of 17**. Strip that single bucket out and the remaining
decisive calls are 15 of 29.

**Every verdict was unanimous to the integer.** All 64 rows came back `responded = 3`, `agreed = 3`,
with the three validators returning the same number — never a split, on any row. The committee
produced consensus but, in this sample, no ensemble diversity: the median equals every member's
answer, so the three-validator structure bought agreement and no variance reduction. That is
unchanged from the previous, smaller sample, and it now holds over three times as many rows.

### Refusals and skips

Now that the desks trade, this table covers a running system. All eight desks the router drives are
included.

| Source | Reason | Count | What it is |
|---|---|---|---|
| Desk `Refused` | `NoBook` | **64** | An `AiEdge` desk declining to measure an edge against a book nobody quoted. Every one carries `pBookBps = 65535`. |
| Desk `Refused` | `VenueRejected` | **25** | A `Maker` desk shown a completely described order that the pool turned down. |
| Desk `Refused` | `CapExceeded` | **13** | The mandate's per-window cap, enforced before anything reached the venue. |
| Desk `Refused` | `InsufficientFunds` | **2** | The desk did not hold the collateral the order needed. |
| Router `Skipped` | `NO_CREDIT` | **115** | A desk out of prepaid gas credit, named rather than silently dropped. |
| Router `Skipped` | `DECISION_SCHEDULE_FAILED` | **36** | The precompile refusing to book a decision wake-up. |
| Router `Skipped` | `SCHEDULE_FAILED` | **34** | The precompile refusing to book a settlement wake-up. |
| Router `Skipped` | `ROUTER_FLOAT` | **6** | The router's own balance under the 32 SOMI subscription floor. |

Float at run time: brain **13.855 STT**, router **40.728 STT**.

Three things this says that the totals do not:

- **`NoBook` is arithmetically the only refusal an `AiEdge` desk could have produced in this range.**
  No side of the book quoted on any graded window, so there was no edge to compute. `LucidDesk`
  refuses rather than substituting a midpoint, which is the same discipline as the prompt fix, one
  layer down. It also means the `AiEdge` mandate has still never been exercised against a real quote.
- **`VenueRejected` now means one thing.** The enum has been split, so `BookUnreadable`, `Unquotable`
  and `MintFailed` are separate values — and none of the three appears anywhere in this range. The
  25 refusals are all the narrow case: the pool was shown a complete order and said no.
- **The three schedule-shaped skips are one event, not three.** 6 `ROUTER_FLOAT`, 34
  `SCHEDULE_FAILED` and 36 `DECISION_SCHEDULE_FAILED` are the router crossing its 32 SOMI floor near
  the end of the scan and reporting that it could not book wake-ups, until it was topped up. The
  router publishing its own funding exhaustion is the designed behaviour; it is also why the two
  `not-finalized` exclusions exist.

### Verbatim output

```
Lucid committee evaluation - observer, read-only
  chain                                  Somnia Shannon 50312
  rpc                                    https://api.infra.testnet.somnia.network
  indexer                                https://dev.smk.somnia.host/v1/graphql
  brain                                  0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25
  router                                 0x6aE21a20444141552648C1f8443bAf171BCCcB99
  scanned blocks                         481521686 -> 481825872 (304187 blocks, 321 pages of 950; start from cache)
  head block time (UTC)                  2026-09-07T04:35:51.000Z

desks driven by the router
  desks in the union                     8
    router allDesks() / seeds / in range 8 / 2 / 2

sample
  VerdictReceived on the brain           64
    with a committee answer              64
    failed closed (no answer at all)     0
    ok = false (never tradeable)         0
  graded PRIMARY (ok, market settled)    62
  graded SECONDARY (answered, settled)   62

excluded from grading, by reason
    not-finalized                        2

PRIMARY - verdicts the protocol marked tradeable (ok = true)
  graded verdicts (n)                    62
  realised UP rate in sample             53.2 %
  forecast dispersion                    8 distinct value(s), 0.0 %..100.0 %, sd 0.3156
  Brier score (lower is better)          0.3598
  directional accuracy                   69.6 % (32/46 decisive, 16 abstained at exactly 50 %)
    exact binomial p (one-sided)         0.0057
  mean |committee - book|                n/a - no row in this sample carried a real book quote
    rows excluded from that mean         62 no book at the venue (sentinel 65535), 0 no book field on the row, 0 book value outside 0..10000

  calibration (decile -> realised UP frequency)
    bucket          n    mean p  realised
    0.0-0.1        19     0.0 %  42.1 %
    0.4-0.5         1    49.0 %   0.0 %
    0.5-0.6        34    50.6 %  67.6 %
    0.9-1.0         8    98.6 %  25.0 %

  negative controls on the identical sample
    constant 50 % - Brier                0.2500
    coin flip (same boldness) - Brier    0.3574 mean of 20000 draws
    coin flip - directional accuracy     50.0 %
    P(random twin >= committee, Brier)   50.13 %
    P(random twin >= committee, acc.)    0.57 %
    verdict vs controls                  BEATS NEITHER CONTROL

refusals - desk Refused, by reason
    NoBook                               64
    VenueRejected                        25
    CapExceeded                          13
    InsufficientFunds                    2

skips - router Skipped, by reason
    NO_CREDIT                            115
    DECISION_SCHEDULE_FAILED             36
    SCHEDULE_FAILED                      34
    ROUTER_FLOAT                         6

float (context for any funding-shaped refusal or skip)
  brain                                  13.8554640074 STT
  router                                 40.7275658412 STT
```

The SECONDARY block is identical and is omitted here; it is in `results.json` in full, along with
every graded row, the raw per-validator scores and the settlement decision for each market.

---

## 4. Interpretation

**The committee's magnitudes carry no information, and its direction is one bucket wide.** Those are
two separate statements and both are supported by the tables above.

*Calibration.* This is unambiguous and it got worse-looking as the sample grew, because there are now
enough rows at the top rail to see it. The committee said 0 % nineteen times and those windows closed
UP eight times; it said 97–100 % eight times and those windows closed UP twice. A forecast of 0 %
realised at 42 % and a forecast of 99 % realised at 25 % are not small errors; between them they are
0.2222 of the 0.3598 Brier from 44 % of the sample. Nothing in 62 rows sits between 55 % and 97 %, or
between 1 % and 48 %. The committee answers as if it were classifying, not pricing. That is exactly
why a predictor that always says 50 % beats it while knowing nothing: it never pays for a confident
miss because it is never confident.

*Direction.* The honest reading has moved, and it has not moved as far as the p-value suggests.

- 32 of 46 decisive is p = 0.0057 against a fair coin, and only 0.57 % of same-boldness random twins
  did as well or better. On its own terms that clears the pre-registered control cleanly, which the
  previous run's 4.84 % did not.
- **The base-rate objection that killed the previous result no longer applies.** 33 of 62 windows
  closed UP — 53.2 %, indistinguishable from a coin. Always-UP scores 28 of 46 and a Brier of 0.4677,
  worse than the committee on both metrics. Whatever is going on, "the market drifted up and so did
  the committee" is not it any more.
- **But the signal is a single bucket, and that bucket is a near-abstention.** The 51 % calls went 17
  for 17; everything else decisive went 15 of 29. A committee whose one-point-off-the-midpoint calls
  are perfect and whose confident calls are worse than chance is not obviously a committee with a
  view. And that bucket was identified after looking at the data, so any p-value computed on it alone
  would be dishonest and none is quoted here.
- **Accuracy and Brier disagree, and Brier is the one that matters for a forecast.** The harness's
  own summary line compares Brier against both controls and prints `BEATS NEITHER CONTROL`. A number
  that is right about the sign 70 % of the time and wrong about the magnitude badly enough to lose to
  a coin flip is not yet a probability, and a desk sizing on it would be sizing on the wrong half.

The defensible statement is narrower than the headline number: **on 62 windows over 7 h 50 m the
committee's forecasts varied, its direction beat a same-boldness random twin without help from a
drifting sample, its magnitude was worse than useless, and the direction is concentrated in one
seventeen-row bucket of barely-decisive calls.** The second of those is new information relative to
the previous report. It is not a claim about skill, and none is made.

*What the run does establish regardless of sample size.*

- The measurement path works end to end: verdicts are on chain, outcomes are joinable, the join is
  honest, and the whole thing is reproducible from public data with no key and no cost.
- The sample now includes execution. 104 refusals and 191 skips across eight desks are a measurement
  of a system that is placing orders and settling them, not of one sitting idle.
- The refusal path is doing its job, and its vocabulary got sharper: `NoBook` for an unquoted book,
  a narrowed `VenueRejected` for an order the pool turned down, and the mandate's own `CapExceeded`
  and `InsufficientFunds`. A desk that had traded on an unobservable book would be the actual
  finding, and a much worse one.
- The harness keeps returning bad news. It returned "beats neither control" two reports ago, "loses
  to constant 50 % on Brier" one report ago, and `BEATS NEITHER CONTROL` again now — every time in
  the headline.

---

## 5. What would change the conclusion

- **A book.** Every one of the 62 graded rows carried the unobserved sentinel, so `mean |committee −
  book|` is `n/a` and the most interesting comparison in this document cannot be computed at all.
  Until some side of the venue's book quotes, "edge versus the market" is unmeasurable, `NoBook` will
  keep being the correct answer, and the `AiEdge` mandate stays unexercised.
- **A calibrated committee.** The Brier result is not a statement that the committee knows nothing;
  it is a statement that its numbers are not probabilities. Two cheap interventions would test that
  directly: an explicit instruction against the rails, or a post-hoc shrink toward the base rate
  (mapping 0 → 0.2, 100 → 0.8, say) applied on chain and then graded by this same harness. Given the
  0 % and 97–100 % buckets above, shrinking alone would move the Brier below 0.25 without adding one
  bit of information — which is precisely why doing it would prove nothing about skill and everything
  about calibration.
- **A sample that keeps the 51 % bucket honest.** 17 for 17 is the single most interesting number
  here and it was found by looking. The test it deserves is pre-registered and prospective: fix the
  bucket now, keep grading, and see whether the next few hundred barely-decisive calls hold up. At
  n in the hundreds the answer stops depending on which eight hours were sampled.
- **More than one venue, cadence and asset.** Every graded window is a 300-second BTC/USDC or
  ETH/USDC window on one venue. Longer cadences and other assets are untested.
- **Funded desks and a funded router.** 115 `NO_CREDIT` skips and 76 schedule-shaped skips mean a
  large share of windows never reached a mandate at all. Continuous funding would widen the sample
  faster than anything else on this list.

---

## Defects found in the harness itself

The previous report found two defects in `eval/` and published them rather than quietly fixing them.
Both are now fixed, and both fixes are visible in the output above rather than only in the diff.

1. **`mean |committee − book|` no longer averages a sentinel.** It previously treated
   `pBookBps = 65535` as a number, folding 6.5535 into an average of values that live on 0..1 and
   reporting a deviation of 6.1302. `metrics.ts::bookComparison` now excludes the sentinel, reports
   `n/a` when nothing is left, and prints the exclusion counts beside it — in this run, "62 no book
   at the venue (sentinel 65535), 0 no book field on the row, 0 book value outside 0..10000". The
   contracts have always guarded against exactly this (`LucidDesk`: "a value that encodes ABSENCE
   must never be an arithmetic input"); the harness now does too, and `metrics.ts` asserts it against
   a fixture before any real number is computed.
2. **Desk discovery no longer misses desks.** The scan window is anchored on the brain, which has
   been redeployed, so desks registered before that block were found neither by `DeskCreated` in
   range nor in `deployed.json`; the previous run scanned 2 of 4. `run.ts` now unions
   `router.allDesks()` with both other sources and prints the breakdown: this run found **8 desks —
   `allDesks()` 8, `deployed.json` 2, `DeskCreated` in range 2**. The refusal and skip table above is
   therefore complete for every desk the router drives, not for two of them.

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
redeploy of the brain, delete `.scan-cache.json`.

The number that decides how much a run is worth is **graded PRIMARY**, printed first.

**Everything in this file is a snapshot.** Chain 50312, blocks 481 521 686 → 481 825 872, head block
time 2026-09-07T04:35:51Z, run 2026-09-07T04:36:34Z, n = 62. A later run covers a different and
larger window and will produce different numbers; the ones here are not updated in place, and any
number quoted from this document should be quoted with that block range attached.

---

## Limits, stated plainly

- **n = 62.** Bigger than the last report and still without the power to establish an edge or rule
  one out.
- **7 h 50 m, one venue, one cadence, two assets.** Every graded window is a 300-second BTC/USDC or
  ETH/USDC window. Longer cadences and other assets are untested.
- **The directional result rests on one bucket found after the fact.** 17 of 17 at 51 %, 15 of 29
  everywhere else. No p-value is quoted for that subset because an honest one cannot be.
- **No row had a book.** All 62 carried the unobserved sentinel, so the committee has never been
  compared against a market price on this venue.
- **The committee was unanimous on every row.** Whether three validators add anything over one cannot
  be answered from a sample with zero within-committee dispersion.
- **This measures forecasts, not P&L.** The desks in this range did trade, and the trades are not
  graded here: no returns figure appears in this document or anywhere in this repository.
- **Settlement comes from the venue's indexer.** If the indexer is wrong, this is wrong. The payout
  vector and `winningOutcome` are cross-checked against each other, which catches inconsistency but
  not a consistent error.
- **The discrimination probe in section 2 is not harness output** and is not reproduced by `run.ts`.
  It is reported as measured.
