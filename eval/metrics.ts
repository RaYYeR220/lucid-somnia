/**
 * Scoring. Every function here takes observed pairs and returns a number computed from them —
 * there is no default, no prior and no fallback value, so a metric that cannot be computed
 * comes back `null` rather than as a plausible-looking zero.
 *
 * The same rule covers absence: a field that says "there was nothing here" is never allowed to
 * stand in for a measurement. See `bookComparison`.
 */
import { BOOK_UNOBSERVED_BPS, BPS } from './config.js'

/** One graded forecast: a probability the chain recorded, and the outcome that later happened. */
export interface Observation {
  /** Committee probability that the window closes UP, on 0..1. */
  p: number
  /** True when the window actually closed UP. */
  up: boolean
}

export interface Accuracy {
  /** Forecasts that took a side at all (p !== 0.5). */
  decisive: number
  /** Forecasts that declined to take a side. Never counted as right or wrong. */
  abstained: number
  correct: number
  /** Null when nothing took a side — an average over zero calls is not a 50 % hit rate. */
  rate: number | null
  /** One-sided exact binomial probability of doing this well or better by chance. */
  pValue: number | null
}

/**
 * Directional accuracy against the 50 % line.
 *
 * A forecast of exactly 50 % is an abstention, not a coin flip the committee happened to lose:
 * counting it either way would manufacture a result out of a refusal to call.
 */
export function accuracy(observations: readonly Observation[]): Accuracy {
  let decisive = 0
  let correct = 0
  for (const o of observations) {
    if (o.p === 0.5) continue
    decisive += 1
    if (o.p > 0.5 === o.up) correct += 1
  }
  return {
    decisive,
    abstained: observations.length - decisive,
    correct,
    rate: decisive === 0 ? null : correct / decisive,
    pValue: decisive === 0 ? null : binomialTailAtLeast(correct, decisive),
  }
}

/** P(X >= k) for X ~ Binomial(n, 1/2), computed exactly with integer coefficients. */
export function binomialTailAtLeast(k: number, n: number): number {
  let tail = 0n
  for (let i = k; i <= n; i += 1) tail += choose(n, i)
  const total = 1n << BigInt(n)
  // Ratio of two exact integers, taken in floating point only at the very last step.
  return Number((tail * 10n ** 12n) / total) / 1e12
}

function choose(n: number, k: number): bigint {
  let result = 1n
  for (let i = 0; i < k; i += 1) {
    result = (result * BigInt(n - i)) / BigInt(i + 1)
  }
  return result
}

/** Mean squared error of the probability against the realised 0/1 outcome. Lower is better. */
export function brier(observations: readonly Observation[]): number | null {
  if (observations.length === 0) return null
  let sum = 0
  for (const o of observations) {
    const y = o.up ? 1 : 0
    sum += (o.p - y) ** 2
  }
  return sum / observations.length
}

export interface CalibrationBucket {
  /** Decile lower edge, inclusive. The top bucket is closed on the right so 1.0 has a home. */
  from: number
  to: number
  count: number
  meanForecast: number | null
  realisedUpRate: number | null
}

/** Ten deciles, each with what was promised and what actually happened. */
export function calibration(observations: readonly Observation[]): CalibrationBucket[] {
  const buckets: CalibrationBucket[] = Array.from({ length: 10 }, (_, i) => ({
    from: i / 10,
    to: (i + 1) / 10,
    count: 0,
    meanForecast: null,
    realisedUpRate: null,
  }))
  const sums = new Array<number>(10).fill(0)
  const ups = new Array<number>(10).fill(0)

  for (const o of observations) {
    const index = Math.min(9, Math.max(0, Math.floor(o.p * 10)))
    const bucket = buckets[index]
    if (bucket === undefined) continue
    bucket.count += 1
    sums[index] = (sums[index] ?? 0) + o.p
    ups[index] = (ups[index] ?? 0) + (o.up ? 1 : 0)
  }

  for (let i = 0; i < 10; i += 1) {
    const bucket = buckets[i]
    if (bucket === undefined || bucket.count === 0) continue
    bucket.meanForecast = (sums[i] ?? 0) / bucket.count
    bucket.realisedUpRate = (ups[i] ?? 0) / bucket.count
  }
  return buckets
}

/** One row's committee forecast beside the book quote the router read at the same instant. */
export interface BookPair {
  /** Committee probability that the window closes UP, in bps on 0..`BPS`. */
  probUpBps: number
  /**
   * The book field exactly as the chain reported it, in bps — including
   * `BOOK_UNOBSERVED_BPS`, which is not a probability. `null` means the row carried no book
   * field at all, which is a different fact again.
   */
  pBookBps: number | null
}

export interface BookComparison {
  /** Rows carrying a real quote. These, and only these, are averaged. */
  n: number
  /** Mean |committee - book| on 0..1. Null when no row carried a real quote. */
  meanAbsoluteDeviation: number | null
  /** Rows with no book field at all: no desk verdict was joined to them. */
  noBookField: number
  /** Rows whose book field was the unobserved sentinel: the venue quoted neither side. */
  bookUnobserved: number
  /** Rows whose book field was neither a probability nor the sentinel. */
  outOfRange: number
}

/**
 * Mean absolute deviation between the committee and the book, over the rows that HAD a book.
 *
 * The exclusions are the point of this function, not housekeeping around it. `pBookBps` carries
 * `BOOK_UNOBSERVED_BPS` when the venue quoted neither side of the book, and that value is a marker
 * for the absence of a quote rather than a very confident one. Reading it as a probability turns
 * 65535 bps into 6.5535 and reports a deviation of about 6.13 against verdicts that live on 0..1 —
 * a number six times wider than the widest disagreement that can exist, produced entirely by
 * arithmetic on a value that was never a measurement. The contracts already state the rule this
 * obeys, in `LucidDesk._intendedStake`: a value that encodes ABSENCE must never be an arithmetic
 * input.
 *
 * So the sentinel rows are removed from the average rather than folded into it, and they are
 * counted on the way out, because "no book to compare against" is a finding about the venue and
 * silently averaging over a smaller set would hide it. A book quoted at exactly 0 is kept: zero is
 * a real quote, and dropping it would be the same mistake in the other direction.
 */
export function bookComparison(rows: readonly BookPair[]): BookComparison {
  let sum = 0
  let n = 0
  let noBookField = 0
  let bookUnobserved = 0
  let outOfRange = 0

  for (const row of rows) {
    const book = row.pBookBps
    if (book === null) {
      noBookField += 1
      continue
    }
    if (book === BOOK_UNOBSERVED_BPS) {
      bookUnobserved += 1
      continue
    }
    // Anything else outside the scale is not a probability either, and this harness has no way to
    // know what it was meant to be. Counted and named rather than clamped into the average.
    if (!Number.isFinite(book) || book < 0 || book > BPS) {
      outOfRange += 1
      continue
    }
    n += 1
    sum += Math.abs(row.probUpBps - book) / BPS
  }

  return {
    n,
    meanAbsoluteDeviation: n === 0 ? null : sum / n,
    noBookField,
    bookUnobserved,
    outOfRange,
  }
}

/** A self-check that failed. Thrown rather than logged: a broken metric must stop the run. */
export class MetricsSelfCheckError extends Error {
  override readonly name = 'MetricsSelfCheckError'
}

/**
 * Both halves of the sentinel rule, asserted on every run before any real number is computed:
 * absence is excluded, and a genuine quote of zero is not.
 *
 * This is deliberately not a test file somebody has to remember to run. The bug it guards against
 * did not look like a crash — it looked like a plausible metric, and it was reported as one. A
 * check that only fires when someone remembers to type `npm test` would not have caught it.
 */
export function assertBookSentinelIsExcluded(): void {
  const absent = bookComparison([{ probUpBps: 5100, pBookBps: BOOK_UNOBSERVED_BPS }])
  if (absent.meanAbsoluteDeviation !== null || absent.n !== 0 || absent.bookUnobserved !== 1) {
    throw new MetricsSelfCheckError(
      `the unobserved-book sentinel (${BOOK_UNOBSERVED_BPS}) reached the deviation: ` +
        `got n=${absent.n}, mad=${String(absent.meanAbsoluteDeviation)}`,
    )
  }

  // Zero is a price somebody quoted. Excluding it would understate the disagreement instead of
  // overstating it, which is the same class of error wearing the opposite sign.
  const zeroQuote = bookComparison([{ probUpBps: 5100, pBookBps: 0 }])
  if (zeroQuote.n !== 1 || zeroQuote.meanAbsoluteDeviation !== 0.51 || zeroQuote.bookUnobserved !== 0) {
    throw new MetricsSelfCheckError(
      `a genuine book quote of 0 was dropped: got n=${zeroQuote.n}, ` +
        `mad=${String(zeroQuote.meanAbsoluteDeviation)}`,
    )
  }

  // And the mixed case: the average must be over the real quote alone, not over both.
  const mixed = bookComparison([
    { probUpBps: 5100, pBookBps: BOOK_UNOBSERVED_BPS },
    { probUpBps: 5100, pBookBps: 5000 },
    { probUpBps: 5100, pBookBps: null },
  ])
  if (mixed.n !== 1 || mixed.meanAbsoluteDeviation !== 0.01 || mixed.noBookField !== 1) {
    throw new MetricsSelfCheckError(
      `a mixed sample averaged the wrong rows: got n=${mixed.n}, ` +
        `mad=${String(mixed.meanAbsoluteDeviation)}, noBookField=${mixed.noBookField}`,
    )
  }
}

/** The realised base rate of the sample. Context for any accuracy number, not a metric of skill. */
export function upRate(observations: readonly Observation[]): number | null {
  if (observations.length === 0) return null
  return observations.filter((o) => o.up).length / observations.length
}


export interface Dispersion {
  distinctForecasts: number
  min: number | null
  max: number | null
  /** Population standard deviation of the forecast. Zero means the committee said one thing. */
  stdev: number | null
}

/**
 * How much the forecast actually moved across the sample.
 *
 * This is the difference between a committee that is wrong and a committee that never says
 * anything. A degenerate forecast — one distinct value, zero spread — cannot be graded for
 * skill at all: it scores exactly what the constant control scores, by construction rather
 * than by contest, and reporting only the Brier would hide that.
 */
export function dispersion(observations: readonly Observation[]): Dispersion {
  if (observations.length === 0) {
    return { distinctForecasts: 0, min: null, max: null, stdev: null }
  }
  const values = observations.map((o) => o.p)
  const mean = values.reduce((a, b) => a + b, 0) / values.length
  const variance = values.reduce((acc, v) => acc + (v - mean) ** 2, 0) / values.length
  return {
    distinctForecasts: new Set(values).size,
    min: Math.min(...values),
    max: Math.max(...values),
    stdev: Math.sqrt(variance),
  }
}

// ── negative controls ───────────────────────────────────────────────────────

/**
 * Deterministic PRNG. The seed is fixed and stated in the report so the control is reproducible:
 * a control whose number moves between runs cannot be argued with, only re-rolled.
 */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export interface CoinFlipControl {
  trials: number
  seed: number
  meanBrier: number
  /** Fraction of random twins that scored a Brier at least as good as the committee's. */
  brierBeatenFraction: number
  meanAccuracy: number | null
  /** Fraction of random twins that matched or beat the committee's directional hit rate. */
  accuracyBeatenFraction: number | null
}

/**
 * The false twin: identical confidence, no information.
 *
 * For each observation it keeps the committee's own distance from 50 % and flips only the sign.
 * A twin that guessed with flat 50 % everywhere would be a strawman — it can never be confidently
 * wrong, so beating it proves nothing about skill. Keeping the boldness and randomising the
 * direction isolates the only thing under test: whether the direction carried information.
 */
export function coinFlipControl(
  observations: readonly Observation[],
  committeeBrier: number | null,
  committeeAccuracy: number | null,
  trials: number,
  seed: number,
): CoinFlipControl | null {
  if (observations.length === 0 || committeeBrier === null) return null
  const random = mulberry32(seed)
  let brierSum = 0
  let brierBeaten = 0
  let accuracySum = 0
  let accuracyTrials = 0
  let accuracyBeaten = 0

  for (let t = 0; t < trials; t += 1) {
    let squared = 0
    let decisive = 0
    let correct = 0
    for (const o of observations) {
      const edge = o.p - 0.5
      const flipped = random() < 0.5 ? 0.5 - edge : 0.5 + edge
      const y = o.up ? 1 : 0
      squared += (flipped - y) ** 2
      if (flipped !== 0.5) {
        decisive += 1
        if (flipped > 0.5 === o.up) correct += 1
      }
    }
    const trialBrier = squared / observations.length
    brierSum += trialBrier
    if (trialBrier <= committeeBrier) brierBeaten += 1
    if (decisive > 0) {
      const rate = correct / decisive
      accuracySum += rate
      accuracyTrials += 1
      if (committeeAccuracy !== null && rate >= committeeAccuracy) accuracyBeaten += 1
    }
  }

  return {
    trials,
    seed,
    meanBrier: brierSum / trials,
    brierBeatenFraction: brierBeaten / trials,
    meanAccuracy: accuracyTrials === 0 ? null : accuracySum / accuracyTrials,
    accuracyBeatenFraction:
      accuracyTrials === 0 || committeeAccuracy === null ? null : accuracyBeaten / accuracyTrials,
  }
}

/**
 * The flat predictor: 50 % on everything, forever.
 *
 * Its Brier is 0.25 by construction on any sample, which is exactly what makes it useful — it is
 * the score to beat before a forecast has said anything at all.
 */
export function constantHalfControl(observations: readonly Observation[]): {
  brier: number | null
  accuracy: null
} {
  return {
    brier: brier(observations.map((o) => ({ p: 0.5, up: o.up }))),
    accuracy: null,
  }
}
