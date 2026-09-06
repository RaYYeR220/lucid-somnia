# Evaluating the Lucid committee

An observational, pre-registered grading of the verdicts `LucidBrain`
(`0x37d0a2907242C09F0B445D655982dA4983345636`) has written on Somnia Shannon testnet, chain
50312, against how those windows actually settled.

---

## Headline

**The committee shows no edge, because in this sample it does not express an opinion at all.**
Every one of the 16 verdicts on chain is the same number: `probUpBps = 5000`, a flat 50 %, from
three validators that each returned exactly `50`. Forecast dispersion is zero — one distinct
value, standard deviation 0.0000. On the 14 verdicts whose window has since settled, the Brier
score is **0.2500**, which is *identical* to the constant-50 % negative control and identical to
the coin-flip control — not because the committee tied a contest, but because it is the same
predictor. It beats neither control. Directional accuracy is undefined: with every forecast at
exactly 50 %, the committee took a side zero times out of 14.

The desk behaved correctly in response. All 16 verdicts were refused with `LowEdge` — the book
was also quoting 50 %, the committee agreed with it to the basis point, and the mandate refuses
to pay spread for a forecast that says nothing. Zero trades were placed on committee signal. The
policy layer is doing its job; the signal layer has not yet produced a signal.

**The sample is small — 14 graded verdicts over 43 minutes of chain — and must be read as small.**
This is a first-hour reading of a deployment that is under an hour old, not a verdict on the
committee. Re-running the harness later grows the sample automatically. What the number *does*
establish today is that the harness is capable of returning bad news, and that this is the bad
news it returned.

---

## Pre-registration

Stated as a protocol, before any result. Everything below was fixed in `run.ts` before the first
scored run and has not been changed since; the code is the registration.

### 1. Why this is an observer and not a replayer

The obvious way to build this — take settled windows, feed them back through the brain, compare —
is worthless here, and quietly so. `LucidBrain` fetches the spot price at call time. Replaying a
window that closed an hour ago would price it with the price *now*, produce a number, and that
number would look exactly like a result. It would be a leak of the answer into the question.

So this harness never calls the brain. It reads what the brain already committed to chain:

- Each `VerdictReceived(marketId, requestId, probUpBps, responded, agreed, ok, scores)` is a
  probability written into a block, with a timestamp, before the window closed.
- The outcome is read separately, from the venue's own indexer, after settlement.

At the instant each verdict was written, the answer did not exist anywhere — not in the contract,
not in the indexer, not in the world. **That is what makes this evaluation genuinely
pre-registered**, and it is the only property that makes the resulting number worth anything.
Nothing about the grading can be tuned after the fact without changing a number that is already
immutable in a block.

### 2. Sample rule

The population is **every `VerdictReceived` log emitted by the deployed brain**, from its
deployment block to chain head, with no selection of any kind. Logs are paged in 950-block
windows because Somnia rejects an `eth_getLogs` span wider than 1000 blocks outright
(`block range exceeds 1000`), and blocks here are ~100 ms.

Two samples are graded, both declared here so neither is a post-hoc pick:

- **PRIMARY** — verdicts the protocol itself marked tradeable (`ok == true`) whose market has
  since settled. This is what a desk was actually allowed to act on.
- **SECONDARY** — every verdict the committee actually answered (`responded > 0` and a non-empty
  `scores` array) whose market has since settled, tradeable or not. This catches answers that
  arrived too late to trade but were still real forecasts.

### 3. Exclusion rule

A verdict is excluded, and counted under its reason, when:

- **`no-committee-answer`** — `responded == 0` or `scores` is empty. `handleResponse` writes
  `probUpBps = 0` when the agent platform failed or timed out. That zero is a structural absence,
  not a confident forecast of "0 % up". Grading it would invent an opinion the committee never
  held, and would do so in the direction that flatters or damns it at random.
- **`not-in-indexer`** — the brain priced a window the indexer has not surfaced yet.
- **`not-finalized`** — `clobStatus` is not the terminal `"Finalized"`, or `finalized != true`.
  The terminal status on this venue is the literal string **`"Finalized"`**. It is never
  `"Resolved"` — that value does not exist in the schema, and a filter written against it returns
  an empty set forever without ever erroring.
- **`voided`** — the market was voided; both legs paid, so no side won.
- **`no-payout`** — **finalized with an all-zero payout vector and a null `winningOutcome`.**
  This happens when the oracle stopped publishing before the window closed. The market is
  terminal, but nothing settled and no side won. Scoring these as losses would manufacture wrong
  answers out of absent ones, so they are excluded and counted as unresolved.
- **`inconsistent-payout`** — `winningOutcome` and `payoutNumerators` disagree. Two independent
  statements of the same fact; when they conflict neither is trustworthy enough to grade against.

Outcome index 0 is YES on this venue, and YES is "at or above the strike", i.e. UP.

### 4. Metrics

All computed from observed rows only. Anything that cannot be computed is reported as `n/a`,
never as a default.

- **Sample size**, and the `ok` / failed-closed split.
- **Forecast dispersion** — distinct values, range, standard deviation. Declared up front because
  it is the only thing that separates "the committee was wrong" from "the committee never said
  anything", and a Brier score alone cannot tell those apart.
- **Directional accuracy** against the 50 % line. A forecast of *exactly* 50 % is an abstention,
  not a coin flip the committee happened to lose; it is excluded from the numerator and the
  denominator and reported separately. Accompanied by a one-sided exact binomial p-value under
  H₀ = 0.5, computed with integer coefficients.
- **Brier score** — mean squared error against the realised binary outcome. Lower is better;
  0.25 is what saying nothing scores.
- **Calibration table** — ten deciles, each with its count, mean forecast and realised UP
  frequency.
- **Mean absolute deviation from the book-implied probability**, taken from the desk's own
  `VerdictReceived(marketId, probUpBps, pBookBps, responded)`, which the router emits with the
  pool's implied probability read at the moment it fanned the verdict out. Rows with no book
  quote are excluded and counted.
- **Refusal breakdown** — the desk's `Refused` events grouped by `LucidTypes.Refusal`, and the
  router's `Skipped` events grouped by reason string. Refusals are a result, not an error log:
  the rate at which a mandate declines to act is as much a measurement of the system as its hit
  rate.

### 5. Negative controls

Declared before the fact, run on the identical sample, with a fixed seed (`0x1ec1d`) and 20 000
draws so the numbers are reproducible rather than re-rollable.

- **Constant 50 %** — predicts 0.5 on everything. Brier 0.25 by construction. This is the floor a
  forecast must clear before it has said anything.
- **Coin flip, same boldness** — for each row it keeps the committee's own distance from 50 % and
  randomises only the sign. A flat-50 % twin would be a strawman: it can never be confidently
  wrong, so beating it proves nothing. Keeping the confidence and destroying the direction
  isolates the only thing under test — whether the direction carried information. Reported as a
  mean Brier and a mean accuracy, plus the fraction of random twins that matched or beat the
  committee, which is an empirical p-value.

**If the committee does not beat both controls, that is the headline and it goes first.** A green
check that a false twin also passes is worth nothing.

---

## Results

Run at **2026-09-06T16:57:42Z**, against live chain state.

| | |
|---|---|
| Chain | Somnia Shannon 50312 |
| Brain | `0x37d0a2907242C09F0B445D655982dA4983345636` |
| Router | `0x10bC10a861fBb61Cc26832110011766d8CfA958B` |
| Desks discovered | 1 (`0x7a1b13b3531cd07e34df7ecc0f8a18652a92a4c4`) |
| Blocks scanned | 481 381 284 → 481 407 041 (25 758 blocks, 28 pages of 950) |
| Chain time covered | 2026-09-06T16:14:42Z → 16:57:38Z — **42.9 minutes** |
| Block cadence observed | ~10 blocks/second |

### Sample

| | |
|---|---|
| `VerdictReceived` on the brain | **16** |
| — with a committee answer | 16 |
| — failed closed (no answer at all) | 0 |
| — `ok == false` (never tradeable) | 0 |
| **Graded, PRIMARY** (`ok`, market settled) | **14** |
| **Graded, SECONDARY** (answered, settled) | **14** |

Excluded, by reason: `not-finalized` 2 — the two most recent windows had not closed when the scan
ran. They are not dropped, only not settled yet, and the next run grades them.

No verdict was excluded for the all-zero-payout trap in this window. The exclusion path exists and
is counted; it simply did not fire yet.

PRIMARY and SECONDARY are identical here because every verdict came back `ok == true` and none
arrived late. They will diverge as soon as the platform times out or a verdict lands after
expiry.

### Metrics — PRIMARY (n = 14)

| Metric | Value |
|---|---|
| Realised UP rate in sample | 42.9 % (6 of 14 windows closed up) |
| **Forecast dispersion** | **1 distinct value**, 50.0 % … 50.0 %, sd **0.0000** |
| **Brier score** | **0.2500** |
| Directional accuracy | **n/a** — 0 of 14 decisive, 14 abstained at exactly 50 % |
| Exact binomial p | n/a (no decisive calls to test) |
| Mean \|committee − book\| | **0.0000** over 14 rows, 0 rows without a book quote |

Calibration:

| Bucket | n | Mean forecast | Realised UP |
|---|---|---|---|
| 0.5 – 0.6 | 14 | 50.0 % | 42.9 % |

Nine of ten deciles are empty. That is the finding, not a formatting artefact.

### Negative controls — identical sample

| Predictor | Brier | Directional accuracy |
|---|---|---|
| **Committee** | **0.2500** | n/a (never took a side) |
| Constant 50 % | 0.2500 | n/a by construction |
| Coin flip, same boldness (20 000 draws, seed `0x1ec1d`) | 0.2500 | n/a |

Fraction of random twins scoring at least as well as the committee on Brier: **100.00 %**.

**The committee beats neither control.** Not narrowly — exactly. With every forecast pinned at
50 %, the coin-flip twin has zero edge to flip the sign of, so it reproduces the committee's
predictions bit for bit. The controls are not losing to the committee; they *are* the committee.

### Refusals and skips

| Source | Reason | Count |
|---|---|---|
| Desk `Refused` | `LowEdge` | **16** |
| Router `Skipped` | — | 0 |

Every verdict reached a desk — no router skips, and the brain held 10.31 STT with the router at
40.32 STT, so nothing was starved of float or gas — and every one was refused for insufficient
edge. The mean absolute deviation from the book is 0.0000, so `LowEdge` is arithmetically the only
refusal this data could have produced under any non-zero `minEdgeBps`. The refusal path is working
as designed; there was simply nothing to trade.

### Verbatim output

```
Lucid committee evaluation - observer, read-only
  chain                                  Somnia Shannon 50312
  rpc                                    https://api.infra.testnet.somnia.network
  indexer                                https://dev.smk.somnia.host/v1/graphql
  brain                                  0x37d0a2907242C09F0B445D655982dA4983345636
  router                                 0x10bC10a861fBb61Cc26832110011766d8CfA958B
  scanned blocks                         481381284 -> 481407041 (25758 blocks, 28 pages of 950; start from cache)
  head block time (UTC)                  2026-09-06T16:57:38.000Z

sample
  VerdictReceived on the brain           16
    with a committee answer              16
    failed closed (no answer at all)     0
    ok = false (never tradeable)         0
  graded PRIMARY (ok, market settled)    14
  graded SECONDARY (answered, settled)   14

excluded from grading, by reason
    not-finalized                        2

PRIMARY - verdicts the protocol marked tradeable (ok = true)
  graded verdicts (n)                    14
  realised UP rate in sample             42.9 %
  forecast dispersion                    1 distinct value(s), 50.0 %..50.0 %, sd 0.0000
  Brier score (lower is better)          0.2500
  directional accuracy                   n/a (0/0 decisive, 14 abstained at exactly 50 %)
    exact binomial p (one-sided)         n/a
  mean |committee - book|                0.0000 over 14 rows (0 carried no book quote)

  calibration (decile -> realised UP frequency)
    bucket          n    mean p  realised
    0.5-0.6        14    50.0 %  42.9 %

  negative controls on the identical sample
    constant 50 % - Brier                0.2500
    coin flip (same boldness) - Brier    0.2500 mean of 20000 draws
    coin flip - directional accuracy     n/a
    P(random twin >= committee, Brier)   100.00 %
    P(random twin >= committee, acc.)    n/a
    DEGENERATE FORECAST                  every verdict in this sample is the same number - no skill is measurable
    verdict vs controls                  BEATS NEITHER CONTROL

SECONDARY - every verdict the committee actually answered
  graded verdicts (n)                    14
  realised UP rate in sample             42.9 %
  forecast dispersion                    1 distinct value(s), 50.0 %..50.0 %, sd 0.0000
  Brier score (lower is better)          0.2500
  directional accuracy                   n/a (0/0 decisive, 14 abstained at exactly 50 %)
    exact binomial p (one-sided)         n/a
  mean |committee - book|                0.0000 over 14 rows (0 carried no book quote)

  calibration (decile -> realised UP frequency)
    bucket          n    mean p  realised
    0.5-0.6        14    50.0 %  42.9 %

  negative controls on the identical sample
    constant 50 % - Brier                0.2500
    coin flip (same boldness) - Brier    0.2500 mean of 20000 draws
    coin flip - directional accuracy     n/a
    P(random twin >= committee, Brier)   100.00 %
    P(random twin >= committee, acc.)    n/a
    DEGENERATE FORECAST                  every verdict in this sample is the same number - no skill is measurable
    verdict vs controls                  BEATS NEITHER CONTROL

refusals - desk Refused, by reason
    LowEdge                              16

skips - router Skipped, by reason
                                         none emitted in the scanned range

float (context for any funding-shaped refusal or skip)
  brain                                  10.313178323 STT
  router                                 40.321389516 STT
```

Every row behind these numbers, including the raw per-validator scores and the settlement
decision for each market, is in `results.json`.

---

## Reading the result honestly

### What the data says without interpretation

Sixteen verdicts. Every one: three validators responded, three agreed, each returned the integer
`50`, median `50`, `probUpBps = 5000`, `ok = true`. The book quoted 5000 on every one of them.
Fourteen of those windows have settled: six up, eight down. Every graded window is a 300-second
BTC or ETH window.

### Two explanations, and the harness cannot separate them

1. **The committee is defaulting.** Three independent validators returning the identical integer
   on every window, across both BTC and ETH, is the shape of a fallback value rather than a
   considered forecast.
2. **50 % is the honest answer.** These are five-minute at-the-money windows: "will BTC be at or
   above its opening price in five minutes". For a near-driftless asset over that horizon the true
   probability really is close to a coin flip, and a well-behaved forecaster that refuses to
   pretend otherwise would output 50 every time.

Both are consistent with fourteen identical rows. Distinguishing them needs either variance in the
forecast or a window structure where the right answer is not 50 %, and this sample has neither.
The harness reports that it cannot tell, rather than picking the flattering reading.

### What this does establish

- The measurement path works end to end: verdicts are on chain, outcomes are joinable, the join
  is honest, and the whole thing is reproducible from public data with no key and no cost.
- The policy layer is sound under the worst realistic input. Handed a signal with no edge, the
  desk refused sixteen times out of sixteen and traded nothing. A desk that had traded on this
  input would be the actual finding, and a much worse one.
- Under the pre-registered protocol, **the committee currently provides no measurable forecasting
  edge over a coin flip.** That is the number as of this run, and it will stay the number until a
  bigger sample with non-degenerate forecasts says otherwise.

### What would change the answer

The sample is 14. It grows on its own — the venue lists new five-minute windows continuously and
the router prices them without intervention. Over the six minutes between two runs during this
session the graded sample went from 10 to 14, which is the rate to expect: roughly two verdicts
per five-minute window, one for BTC and one for ETH. Re-running the harness an hour, a day or a
week later regrades everything settled since, with no state to reset and nothing to configure.

The interesting threshold is the first run where forecast dispersion is greater than one distinct
value. Until then, accuracy, calibration and the binomial test have nothing to bite on, and
reporting them as anything other than `n/a` would be dressing up a constant as a prediction.

### Limits of this evaluation, stated plainly

- **n = 14 is tiny.** Nothing here has the power to detect a real edge even if one existed. No
  claim in this document should be read as evidence that the committee is *incapable*; it is
  evidence about what it has emitted so far.
- **42.9 minutes of chain, one venue, one asset pair, one cadence** (300 s). Every graded window
  is a five-minute BTC or ETH window. Longer cadences are untested.
- **The book-implied probability is a single pool read at fan-out time**, not a depth-weighted
  mid. On books quoting a flat 0.50 with no trades it carries little information — which is itself
  why the MAD is exactly zero.
- **Settlement is taken from the venue's indexer.** If the indexer is wrong, this is wrong. The
  payout vector and `winningOutcome` are cross-checked against each other, which catches
  inconsistency but not a consistent error.
- **Two verdicts are excluded and will be graded later**, awaiting finalization. They are not
  dropped, just not settled yet.
