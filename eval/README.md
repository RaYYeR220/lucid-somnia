# `eval/` — the committee scoring harness

Grades the verdicts `LucidBrain` has written on Somnia Shannon against how those windows actually
settled. Read-only: it never signs, never sends, and never asks the brain to price anything.

The report is [`EVAL.md`](./EVAL.md). The raw graded rows are `results.json`, rewritten on every
run.

## Run it

```sh
cd eval
npm install     # once
npm run eval    # or: npx tsx run.ts
```

Node 20 or newer. The only runtime dependency is `viem`.

## What it costs

Nothing. Every call is a read:

- `eth_getLogs`, `eth_getBlockByNumber`, `eth_getBalance` against the public Shannon RPC.
- A GraphQL POST to the public DreamDEX indexer, which needs no auth.
- One call to the block explorer's public API, on the very first run only, to learn which block
  the brain was deployed in — then cached to `.scan-cache.json` and never fetched again.

No private key is read, no transaction is built, and nothing is written on chain. Running this a
hundred times costs the same as running it once.

## Re-running it to grow the sample

Just run it again. There is no state to reset and no flag to pass.

The venue lists new five-minute windows continuously and the router prices them without
intervention, so the population of `VerdictReceived` logs grows on its own. Each run rescans from
the brain's deployment block to current head and regrades everything that has settled since,
including verdicts that were excluded last time as `not-finalized` or `not-in-indexer` — those
resolve on their own within minutes and are picked up automatically.

The number that matters for how much a run is worth is **`graded PRIMARY`** in the output. It is
printed first, and if it is small the report says so rather than hiding it behind a percentage.

Rough arithmetic: two markets (BTC and ETH) per five-minute window means roughly **24 verdicts an
hour**, so an overnight gap gives a few hundred graded rows. Wait for the run where **forecast
dispersion** is greater than one distinct value — until then, accuracy and calibration have
nothing to measure.

### Environment overrides

All optional.

| Variable | Effect |
|---|---|
| `LUCID_FROM_BLOCK` | Start the scan at this block instead of the brain's deployment block. Useful for grading only a recent slice, or after a redeploy. |
| `LUCID_RPC_URL` | Point at a different Shannon endpoint. |
| `LUCID_INDEXER_URL` | Point at a different indexer. |

After a redeploy, delete `.scan-cache.json` so the deployment block is resolved fresh. Addresses
themselves are read from `contracts/deployed.json` at run time, so they need no action.

## How it works

1. **Scan.** Pages `eth_getLogs` in 950-block windows from the brain's deployment block to head.
   Somnia rejects any span wider than 1000 blocks outright (`block range exceeds 1000`), and
   blocks are ~100 ms, so a day of history is ~860 000 blocks — pages run eight at a time and are
   reassembled in block order.
2. **Collect.** The brain's `VerdictReceived` (median, per-validator scores, responded/agreed,
   `ok`), the desk's `VerdictReceived` (which carries the book-implied probability at fan-out
   time), the desk's `Refused`, and the router's `Skipped`. Desks are discovered from the
   factory's `DeskCreated` rather than assumed.
3. **Join.** Each verdict's market is fetched from the indexer and its settled outcome extracted.
   The terminal status is the literal string `"Finalized"` — never `"Resolved"`, which does not
   exist in the schema and silently matches nothing. A market finalized with an all-zero payout
   vector and no `winningOutcome` is excluded as unresolved, not scored as wrong.
4. **Score.** Only verdicts whose market has since settled. Brier, directional accuracy with an
   exact binomial p-value, a decile calibration table, mean absolute deviation from the book, and
   two negative controls on the identical sample.

The design constraint that shapes all of it: **this is an observer, not a replayer.** The brain
fetches spot at call time, so re-running a settled window would price it with today's number and
return something that looks like a result and is not one. Reading verdicts that were already
committed to a block, before their outcome existed, is what makes the evaluation
pre-registered — see the protocol section of `EVAL.md`.

## Files

| File | |
|---|---|
| `run.ts` | Entry point: scan, join, score, print, write `results.json`. |
| `chain.ts` | RPC client, event ABIs, 950-block log paging, deployment-block resolution. |
| `indexer.ts` | GraphQL client and the settlement rule, including the exclusion traps. |
| `metrics.ts` | Brier, accuracy, calibration, dispersion, MAD, and the negative controls. |
| `config.ts` | Endpoints, page size, and the `Refusal` enum mirrored from `LucidTypes.sol`. |
| `results.json` | Every graded row plus the full metric set. Regenerated each run. |
| `.scan-cache.json` | The brain's deployment block, cached after the first run. |

Nothing in this directory writes to `contracts/`, `kit/` or `ui-prototypes/`.

## Typecheck

```sh
npm run typecheck
```

Strict TypeScript with `noUncheckedIndexedAccess` and `exactOptionalPropertyTypes`, no `any`.
