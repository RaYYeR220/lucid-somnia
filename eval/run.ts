/**
 * Pre-registered, read-only evaluation of the Lucid committee on Somnia Shannon.
 *
 * This is an observer, not a replayer. It never asks the brain to price anything: the brain
 * fetches spot at call time, so re-running a settled window would price it with today's number
 * and return something that looks like a result and is not one. Instead it reads the verdicts
 * the brain already wrote on chain, joins each to how that window actually settled, and grades
 * only the ones whose answer did not exist yet when the verdict was written.
 *
 * Nothing here signs, sends or costs anything.
 */
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { formatEther } from 'viem'
import type { Address, Hex } from 'viem'
import {
  BRAIN_VERDICT_EVENT,
  DESK_REFUSED_EVENT,
  DESK_VERDICT_EVENT,
  FACTORY_DESK_CREATED_EVENT,
  ROUTER_SKIPPED_EVENT,
  createClient,
  resolveDeployBlock,
  scanLogs,
} from './chain.js'
import type { BlockRange, DeployBlock, EventLogs } from './chain.js'
import { CHAIN_ID, HERE, INDEXER_URL, RPC_URL, loadDeployment, refusalName } from './config.js'
import { marketsById, settlementOf } from './indexer.js'
import type { MarketRow, Settlement, UnresolvedReason } from './indexer.js'
import {
  accuracy,
  brier,
  calibration,
  coinFlipControl,
  constantHalfControl,
  dispersion,
  meanAbsoluteDeviation,
  upRate,
} from './metrics.js'
import type {
  Accuracy,
  CalibrationBucket,
  CoinFlipControl,
  Dispersion,
  Observation,
} from './metrics.js'

/** Pre-registered, not tuned: fixed before any number was looked at, and never changed since. */
const CONTROL_TRIALS = 20_000
const CONTROL_SEED = 0x1ec1d

// -- row shapes --------------------------------------------------------------

interface VerdictRow {
  marketId: Hex
  requestId: string
  blockNumber: string
  txHash: Hex
  /** Committee median on 0..10000. A row with no committee answer carries a structural 0. */
  probUpBps: number
  responded: number
  agreed: number
  ok: boolean
  scores: readonly string[]
  /** Book-implied UP probability the router read when it handed this verdict to the desk. */
  pBookBps: number | null
  asset: string | null
  question: string | null
  intervalSec: number | null
  expiry: number | null
  settlement: Settlement
  /** True when this row entered the secondary graded sample. */
  graded: boolean
  /** True when this row entered the primary graded sample. */
  gradedOk: boolean
}

interface ReasonCount {
  reason: string
  count: number
}

function tally(values: readonly string[]): ReasonCount[] {
  const counts = new Map<string, number>()
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1)
  return [...counts.entries()]
    .map(([reason, count]) => ({ reason, count }))
    .sort((a, b) => b.count - a.count || a.reason.localeCompare(b.reason))
}

interface SampleMetrics {
  n: number
  upRate: number | null
  dispersion: Dispersion
  brier: number | null
  accuracy: Accuracy
  calibration: CalibrationBucket[]
  bookComparison: {
    /** Rows carrying a book-implied probability. Rows without one are excluded and counted. */
    n: number
    missing: number
    meanAbsoluteDeviation: number | null
  }
  controls: {
    constantHalf: { brier: number | null; accuracy: null }
    coinFlip: CoinFlipControl | null
  }
}

/** Unresolved rows are dropped here rather than defaulted, so no row can be scored without an
 * outcome that actually happened. */
function observationsOf(rows: readonly VerdictRow[]): Observation[] {
  const out: Observation[] = []
  for (const row of rows) {
    if (!row.settlement.resolved) continue
    out.push({ p: row.probUpBps / 10_000, up: row.settlement.up })
  }
  return out
}

function scoreSample(rows: readonly VerdictRow[]): SampleMetrics {
  const observations = observationsOf(rows)
  const committeeBrier = brier(observations)
  const committeeAccuracy = accuracy(observations)

  const bookPairs: (readonly [number, number])[] = []
  let missingBook = 0
  for (const row of rows) {
    if (row.pBookBps === null) {
      missingBook += 1
      continue
    }
    bookPairs.push([row.probUpBps / 10_000, row.pBookBps / 10_000])
  }

  return {
    n: observations.length,
    upRate: upRate(observations),
    dispersion: dispersion(observations),
    brier: committeeBrier,
    accuracy: committeeAccuracy,
    calibration: calibration(observations),
    bookComparison: {
      n: bookPairs.length,
      missing: missingBook,
      meanAbsoluteDeviation: meanAbsoluteDeviation(bookPairs),
    },
    controls: {
      constantHalf: constantHalfControl(observations),
      coinFlip: coinFlipControl(
        observations,
        committeeBrier,
        committeeAccuracy.rate,
        CONTROL_TRIALS,
        CONTROL_SEED,
      ),
    },
  }
}

// -- output helpers ----------------------------------------------------------

function pct(value: number | null, digits = 1): string {
  return value === null ? 'n/a' : `${(value * 100).toFixed(digits)} %`
}

function num(value: number | null, digits = 4): string {
  return value === null ? 'n/a' : value.toFixed(digits)
}

function line(label: string, value: string): string {
  return `  ${label.padEnd(38)} ${value}`
}

function printSample(title: string, m: SampleMetrics): void {
  console.log(`\n${title}`)
  console.log(line('graded verdicts (n)', String(m.n)))
  if (m.n === 0) {
    console.log(line('', 'nothing to score'))
    return
  }
  console.log(line('realised UP rate in sample', pct(m.upRate)))
  console.log(
    line(
      'forecast dispersion',
      `${m.dispersion.distinctForecasts} distinct value(s), ` +
        `${pct(m.dispersion.min)}..${pct(m.dispersion.max)}, sd ${num(m.dispersion.stdev)}`,
    ),
  )
  console.log(line('Brier score (lower is better)', num(m.brier)))
  console.log(
    line(
      'directional accuracy',
      `${pct(m.accuracy.rate)} (${m.accuracy.correct}/${m.accuracy.decisive} decisive, ` +
        `${m.accuracy.abstained} abstained at exactly 50 %)`,
    ),
  )
  console.log(line('  exact binomial p (one-sided)', num(m.accuracy.pValue, 4)))
  console.log(
    line(
      'mean |committee - book|',
      `${num(m.bookComparison.meanAbsoluteDeviation)} over ${m.bookComparison.n} rows ` +
        `(${m.bookComparison.missing} carried no book quote)`,
    ),
  )

  console.log('\n  calibration (decile -> realised UP frequency)')
  console.log(`    ${'bucket'.padEnd(12)} ${'n'.padStart(4)}  ${'mean p'.padStart(8)}  realised`)
  for (const bucket of m.calibration) {
    if (bucket.count === 0) continue
    const label = `${bucket.from.toFixed(1)}-${bucket.to.toFixed(1)}`
    console.log(
      `    ${label.padEnd(12)} ${String(bucket.count).padStart(4)}  ` +
        `${pct(bucket.meanForecast).padStart(8)}  ${pct(bucket.realisedUpRate)}`,
    )
  }

  console.log('\n  negative controls on the identical sample')
  console.log(line('  constant 50 % - Brier', num(m.controls.constantHalf.brier)))
  const flip = m.controls.coinFlip
  if (flip === null) {
    console.log(line('  coin flip', 'n/a'))
  } else {
    console.log(
      line('  coin flip (same boldness) - Brier', `${num(flip.meanBrier)} mean of ${flip.trials} draws`),
    )
    console.log(line('  coin flip - directional accuracy', pct(flip.meanAccuracy)))
    console.log(line('  P(random twin >= committee, Brier)', pct(flip.brierBeatenFraction, 2)))
    console.log(line('  P(random twin >= committee, acc.)', pct(flip.accuracyBeatenFraction, 2)))
  }

  if (m.dispersion.distinctForecasts === 1) {
    console.log(
      line(
        '  DEGENERATE FORECAST',
        'every verdict in this sample is the same number - no skill is measurable',
      ),
    )
  }

  const flat = m.controls.constantHalf.brier
  const beatsFlat = m.brier !== null && flat !== null && m.brier < flat
  const beatsFlip = flip !== null && m.brier !== null && m.brier < flip.meanBrier
  console.log(
    line(
      '  verdict vs controls',
      beatsFlat && beatsFlip
        ? 'beats both on Brier'
        : beatsFlat
          ? 'beats constant 50 % only'
          : beatsFlip
            ? 'beats the coin flip only'
            : 'BEATS NEITHER CONTROL',
    ),
  )
}

// -- main --------------------------------------------------------------------

async function main(): Promise<void> {
  const deployment = loadDeployment()
  const client = createClient()

  const head = await client.getBlockNumber()
  const deployBlock: DeployBlock = await resolveDeployBlock(deployment.brain, head)
  const range: BlockRange = { fromBlock: deployBlock.block, toBlock: head }
  const spanBlocks = range.toBlock - range.fromBlock + 1n
  const pageCount = Number((spanBlocks + 949n) / 950n)

  console.log('Lucid committee evaluation - observer, read-only')
  console.log(line('chain', `Somnia Shannon ${CHAIN_ID}`))
  console.log(line('rpc', RPC_URL))
  console.log(line('indexer', INDEXER_URL))
  console.log(line('brain', deployment.brain))
  console.log(line('router', deployment.router))
  console.log(
    line(
      'scanned blocks',
      `${range.fromBlock} -> ${range.toBlock} (${spanBlocks} blocks, ${pageCount} pages of 950; ` +
        `start from ${deployBlock.source}${deployBlock.exact ? '' : ', PARTIAL SCAN'})`,
    ),
  )

  const headBlock = await client.getBlock({ blockNumber: head })
  const headTime = new Date(Number(headBlock.timestamp) * 1000).toISOString()
  console.log(line('head block time (UTC)', headTime))

  const progress =
    (label: string) =>
    (done: number, total: number): void => {
      if (done === total || done % 25 === 0) {
        process.stderr.write(`\r  scanning ${label}: ${done}/${total}   `)
      }
      if (done === total) process.stderr.write('\n')
    }

  // Desks are discovered rather than assumed: a refusal breakdown covering only the demo desk
  // would understate the protocol's own refusals without ever looking wrong.
  const deskCreated = await scanLogs(
    client,
    deployment.factory,
    FACTORY_DESK_CREATED_EVENT,
    range,
    progress('desk registry'),
  )
  const desks = [
    ...new Set<Address>([
      deployment.demoDesk.toLowerCase() as Address,
      ...deskCreated.map((log) => log.args.desk.toLowerCase() as Address),
    ]),
  ]

  const brainVerdicts = await scanLogs(
    client,
    deployment.brain,
    BRAIN_VERDICT_EVENT,
    range,
    progress('brain verdicts'),
  )

  const deskVerdicts: EventLogs<typeof DESK_VERDICT_EVENT> = []
  const deskRefusals: EventLogs<typeof DESK_REFUSED_EVENT> = []
  for (const desk of desks) {
    deskVerdicts.push(
      ...(await scanLogs(client, desk, DESK_VERDICT_EVENT, range, progress('desk verdicts'))),
    )
    deskRefusals.push(
      ...(await scanLogs(client, desk, DESK_REFUSED_EVENT, range, progress('desk refusals'))),
    )
  }

  const routerSkips = await scanLogs(
    client,
    deployment.router,
    ROUTER_SKIPPED_EVENT,
    range,
    progress('router skips'),
  )

  // Book-implied probability, keyed by market. The router reads the pool as it fans the verdict
  // out, so this is the book at verdict time - the only quote comparable to the forecast.
  const bookByMarket = new Map<string, number>()
  for (const log of deskVerdicts) {
    bookByMarket.set(log.args.marketId.toLowerCase(), log.args.pBookBps)
  }

  const marketIds = brainVerdicts.map((log) => log.args.marketId)
  const markets = marketIds.length > 0 ? await marketsById(marketIds) : new Map<string, MarketRow>()

  const rows: VerdictRow[] = brainVerdicts.map((log) => {
    const key = log.args.marketId.toLowerCase()
    const market = markets.get(key)
    const settlement = settlementOf(market)
    // A verdict nobody answered is not a forecast of 0 %. `handleResponse` writes a structural
    // zero when the platform failed or timed out; grading that zero as a confident DOWN call
    // would invent an opinion the committee never held.
    const hasAnswer = log.args.responded > 0 && log.args.scores.length > 0
    const expiry = market?.expiry
    const intervalSec = market?.intervalSec
    return {
      marketId: log.args.marketId,
      requestId: log.args.requestId.toString(),
      blockNumber: (log.blockNumber ?? 0n).toString(),
      txHash: log.transactionHash ?? ('0x' as Hex),
      probUpBps: log.args.probUpBps,
      responded: log.args.responded,
      agreed: log.args.agreed,
      ok: log.args.ok,
      scores: log.args.scores.map((score) => score.toString()),
      pBookBps: bookByMarket.get(key) ?? null,
      asset: market?.asset ?? null,
      question: market?.question ?? null,
      intervalSec: intervalSec === undefined || intervalSec === null ? null : Number(intervalSec),
      expiry: expiry === undefined || expiry === null ? null : Number(expiry),
      settlement,
      graded: settlement.resolved && hasAnswer,
      gradedOk: settlement.resolved && hasAnswer && log.args.ok,
    }
  })

  const answered = rows.filter((row) => row.responded > 0 && row.scores.length > 0)
  const failedClosed = rows.filter((row) => !(row.responded > 0 && row.scores.length > 0))
  const notOk = rows.filter((row) => !row.ok)
  const primary = rows.filter((row) => row.gradedOk)
  const secondary = rows.filter((row) => row.graded)

  type ExclusionReason = UnresolvedReason | 'no-committee-answer'
  const exclusions = new Map<ExclusionReason, number>()
  for (const row of rows) {
    if (!row.settlement.resolved) {
      const reason: ExclusionReason = row.settlement.reason
      exclusions.set(reason, (exclusions.get(reason) ?? 0) + 1)
    } else if (!row.graded) {
      exclusions.set('no-committee-answer', (exclusions.get('no-committee-answer') ?? 0) + 1)
    }
  }

  console.log('\nsample')
  console.log(line('VerdictReceived on the brain', String(rows.length)))
  console.log(line('  with a committee answer', String(answered.length)))
  console.log(line('  failed closed (no answer at all)', String(failedClosed.length)))
  console.log(line('  ok = false (never tradeable)', String(notOk.length)))
  console.log(line('graded PRIMARY (ok, market settled)', String(primary.length)))
  console.log(line('graded SECONDARY (answered, settled)', String(secondary.length)))

  console.log('\nexcluded from grading, by reason')
  if (exclusions.size === 0) console.log(line('', 'nothing excluded'))
  for (const [reason, count] of [...exclusions.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(line(`  ${reason}`, String(count)))
  }

  const primaryMetrics = scoreSample(primary)
  const secondaryMetrics = scoreSample(secondary)
  printSample('PRIMARY - verdicts the protocol marked tradeable (ok = true)', primaryMetrics)
  printSample('SECONDARY - every verdict the committee actually answered', secondaryMetrics)

  const refusals = tally(deskRefusals.map((log) => refusalName(log.args.reason)))
  const skips = tally(routerSkips.map((log) => log.args.reason))

  console.log('\nrefusals - desk Refused, by reason')
  if (refusals.length === 0) console.log(line('', 'none emitted in the scanned range'))
  for (const entry of refusals) console.log(line(`  ${entry.reason}`, String(entry.count)))

  console.log('\nskips - router Skipped, by reason')
  if (skips.length === 0) console.log(line('', 'none emitted in the scanned range'))
  for (const entry of skips) console.log(line(`  ${entry.reason}`, String(entry.count)))

  const brainBalance = await client.getBalance({ address: deployment.brain })
  const routerBalance = await client.getBalance({ address: deployment.router })
  console.log('\nfloat (context for any funding-shaped refusal or skip)')
  console.log(line('brain', `${formatEther(brainBalance)} STT`))
  console.log(line('router', `${formatEther(routerBalance)} STT`))

  const results = {
    meta: {
      generatedAt: new Date().toISOString(),
      chainId: CHAIN_ID,
      rpcUrl: RPC_URL,
      indexerUrl: INDEXER_URL,
      brain: deployment.brain,
      router: deployment.router,
      factory: deployment.factory,
      desks,
      scan: {
        fromBlock: range.fromBlock.toString(),
        toBlock: range.toBlock.toString(),
        blocks: spanBlocks.toString(),
        pages: pageCount,
        pageSize: 950,
        startBlockSource: deployBlock.source,
        startBlockExact: deployBlock.exact,
        headBlockTimeUtc: headTime,
      },
      controls: { trials: CONTROL_TRIALS, seed: CONTROL_SEED },
      balancesWei: { brain: brainBalance.toString(), router: routerBalance.toString() },
    },
    counts: {
      verdicts: rows.length,
      answered: answered.length,
      failedClosed: failedClosed.length,
      notOk: notOk.length,
      gradedPrimary: primary.length,
      gradedSecondary: secondary.length,
      excluded: Object.fromEntries(exclusions),
    },
    metrics: { primary: primaryMetrics, secondary: secondaryMetrics },
    refusals,
    skips,
    rows,
  }

  const path = join(HERE, 'results.json')
  writeFileSync(path, `${JSON.stringify(results, null, 2)}\n`)
  console.log(`\nwrote ${path}`)
}

main().catch((error: unknown) => {
  console.error(error)
  process.exitCode = 1
})
