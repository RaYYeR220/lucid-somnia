/**
 * The DreamDEX indexer, and the one question this harness asks it: how did this window
 * actually settle?
 */
import type { Hex } from 'viem'
import { INDEXER_URL } from './config.js'

/**
 * DreamDEX's terminal market status is the string `"Finalized"`.
 *
 * It is never `"Resolved"`. That value does not exist in this schema, and a filter written
 * against it returns an empty set forever without erroring — a silent zero-sample bug that
 * reads exactly like "no markets have settled yet".
 */
export const TERMINAL_STATUS = 'Finalized'

/** The `marketType` enum is uppercase. `"Binary"` matches nothing. */
export const BINARY_MARKET_TYPE = 'BINARY'

export class IndexerError extends Error {
  override readonly name = 'IndexerError'
}

/** One Hasura row, in the types Hasura actually returns: numerics are strings, nulls are real. */
export interface MarketRow {
  marketId: string
  asset: string | null
  question: string | null
  strike: string | null
  expiry: string | null
  intervalSec: string | null
  clobStatus: string | null
  lastPrice: string | null
  finalized: boolean | null
  voided: boolean | null
  winningOutcome: number | null
  payoutNumerators: readonly string[] | null
  payoutDenominator: string | null
  resolvedAtTimestamp: string | null
}

const MARKET_FIELDS = `
  marketId
  asset
  question
  strike
  expiry
  intervalSec
  clobStatus
  lastPrice
  finalized
  voided
  winningOutcome
  payoutNumerators
  payoutDenominator
  resolvedAtTimestamp
`

const BY_ID_QUERY = `
query LucidEvalMarkets($ids: [String!]) {
  Market(where: { marketId: { _in: $ids } }) {${MARKET_FIELDS}}
}`

interface GraphQLResponse<T> {
  data?: T
  errors?: readonly { message: string }[]
}

async function query<T>(gql: string, variables: Record<string, unknown>): Promise<T> {
  const response = await fetch(INDEXER_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query: gql, variables }),
    signal: AbortSignal.timeout(30_000),
  })
  if (!response.ok) {
    throw new IndexerError(`indexer returned HTTP ${response.status} ${response.statusText}`)
  }
  const payload = (await response.json()) as GraphQLResponse<T>
  if (payload.errors !== undefined && payload.errors.length > 0) {
    throw new IndexerError(payload.errors.map((e) => e.message).join('; '))
  }
  if (payload.data === undefined) throw new IndexerError('indexer returned no data')
  return payload.data
}

/** Fetch every named market, chunked so one oversized `_in` list cannot fail the whole join. */
export async function marketsById(ids: readonly Hex[]): Promise<Map<string, MarketRow>> {
  const out = new Map<string, MarketRow>()
  const unique = [...new Set(ids.map((id) => id.toLowerCase()))]
  const CHUNK = 100
  for (let i = 0; i < unique.length; i += CHUNK) {
    const chunk = unique.slice(i, i + CHUNK)
    const data = await query<{ Market: MarketRow[] }>(BY_ID_QUERY, { ids: chunk })
    for (const row of data.Market) out.set(row.marketId.toLowerCase(), row)
  }
  return out
}

// ── settlement ──────────────────────────────────────────────────────────────

export type UnresolvedReason =
  | 'not-in-indexer'
  | 'not-finalized'
  | 'voided'
  | 'no-payout'
  | 'inconsistent-payout'

export interface Resolved {
  resolved: true
  /** True when the window closed at or above its strike — the event the committee was pricing. */
  up: boolean
  resolvedAtTimestamp: number | null
}

export interface Unresolved {
  resolved: false
  reason: UnresolvedReason
}

export type Settlement = Resolved | Unresolved

/**
 * The settled outcome of one window, or why there isn't one.
 *
 * The trap this guards is real and observed: a market can carry `clobStatus: "Finalized"` with
 * an all-zero payout vector and a null `winningOutcome`, because the oracle stopped publishing
 * before the window closed. Nothing paid out and no side won. Treating that as a loss for the
 * committee would invent a wrong answer out of an absent one, so it is excluded instead — and
 * counted, so the exclusion is visible rather than convenient.
 *
 * Outcome index 0 is YES on this venue, and YES is "at or above the strike", i.e. UP.
 */
export function settlementOf(row: MarketRow | undefined): Settlement {
  if (row === undefined) return { resolved: false, reason: 'not-in-indexer' }
  if (row.clobStatus !== TERMINAL_STATUS || row.finalized !== true) {
    return { resolved: false, reason: 'not-finalized' }
  }
  if (row.voided === true) return { resolved: false, reason: 'voided' }

  const numerators = (row.payoutNumerators ?? []).map((n) => BigInt(n))
  const denominator = row.payoutDenominator === null ? 0n : BigInt(row.payoutDenominator)
  const paidSomething = denominator > 0n && numerators.some((n) => n > 0n)
  if (!paidSomething || row.winningOutcome === null) {
    return { resolved: false, reason: 'no-payout' }
  }

  // The outcome index and the payout vector are two independent statements of the same fact.
  // When they disagree, neither is trustworthy enough to grade a forecast against.
  const winner = row.winningOutcome
  const winnerNumerator = numerators[winner]
  if (winnerNumerator === undefined || winnerNumerator === 0n) {
    return { resolved: false, reason: 'inconsistent-payout' }
  }
  const others = numerators.filter((_, i) => i !== winner)
  if (others.some((n) => n > 0n)) return { resolved: false, reason: 'inconsistent-payout' }

  return {
    resolved: true,
    up: winner === 0,
    resolvedAtTimestamp: row.resolvedAtTimestamp === null ? null : Number(row.resolvedAtTimestamp),
  }
}
