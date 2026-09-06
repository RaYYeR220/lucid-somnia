import type { Address, Hex } from 'viem'
import { INDEXER_URL, MIN_WINDOW_SLACK_SECONDS } from './chain/config'

/**
 * DreamDEX's terminal market status.
 *
 * It is `"Finalized"`. It is never `"Resolved"` — that value does not exist in the indexer, and a
 * filter written against it silently returns an empty set forever.
 */
export const TERMINAL_STATUS = 'Finalized'

/** The indexer's `marketType` enum is uppercase; `"Binary"` matches nothing. */
export const BINARY_MARKET_TYPE = 'BINARY'

export class IndexerError extends Error {
  override readonly name = 'IndexerError'
}

/** One `Market` row exactly as Hasura returns it: every number is a string, nulls are real. */
interface MarketRow {
  marketId: string
  asset: string | null
  question: string | null
  strike: string | null
  tradingStart: string | null
  expiry: string | null
  intervalSec: string | null
  clobStatus: string | null
  marketAddress: string | null
  poolAddress: string | null
  yesTokenId: string | null
  noTokenId: string | null
  nonce: string | null
  venueId: string | null
  lastPrice: string | null
  finalized: boolean | null
  voided: boolean | null
  winningOutcome: number | null
  resolvedAtTimestamp: string | null
}

export interface Market {
  marketId: Hex
  asset: string
  question: string
  /** The oracle strike, in the oracle's two-decimal scale. `0` means the window settles against
   * the price it opened at, which the venue records only once trading starts. */
  strike: bigint
  tradingStart: number
  expiry: number
  /** Window length in seconds — what `Policy.allowedCadences` is a mask over. */
  intervalSec: number
  /** The indexer's own status. It lags the chain, so never trade on it; see `isLive`. */
  clobStatus: string
  marketAddress: Address
  poolAddress: Address
  nonce: number
  venueId: Hex
  /** Last traded price in raw six-decimal collateral. `null` on a book that never traded. */
  lastPrice: bigint | null
  finalized: boolean
  voided: boolean
  winningOutcome: number | null
  resolvedAtTimestamp: number | null
}

const MARKET_FIELDS = `
  marketId asset question strike tradingStart expiry intervalSec clobStatus
  marketAddress poolAddress yesTokenId noTokenId nonce venueId lastPrice
  finalized voided winningOutcome resolvedAtTimestamp
`

interface GraphQLResponse<T> {
  data?: T
  errors?: readonly { message: string }[]
}

/**
 * A dependency-free typed GraphQL POST, issued by the reader's own browser.
 *
 * Two deliberate choices. The content type is `text/plain`, which Hasura accepts and which keeps
 * the request CORS-*simple* — no `OPTIONS` preflight, so there is one round trip instead of two
 * and no dependence on a shared cache getting a preflight right. And a failed request is retried
 * with a short backoff, because this runs on somebody's laptop over whatever network they have,
 * and a single dropped fetch should not turn a working page into an error state.
 */
async function queryIndexer<T>(
  query: string,
  variables: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<T> {
  const body = JSON.stringify({ query, variables })
  let lastError: unknown

  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0) {
      await new Promise((resolve) => setTimeout(resolve, 250 * attempt))
    }
    try {
      const response = await fetch(INDEXER_URL, {
        method: 'POST',
        headers: { 'content-type': 'text/plain;charset=UTF-8' },
        body,
        ...(signal ? { signal } : {}),
      })
      if (!response.ok) {
        // A 5xx is the gateway failing, not the query being wrong, so it goes down the retry
        // path. A 4xx is an answer, and repeating it would only waste the reader's time.
        const message = `the DreamDEX indexer returned HTTP ${response.status}`
        if (response.status >= 500) throw new Error(message)
        throw new IndexerError(message)
      }
      // The gateway in front of the indexer answers `200 upstream request timeout` in plain text
      // when it gives up, so a body that is not JSON is a transport failure, not a query error.
      const text = await response.text()
      let payload: GraphQLResponse<T>
      try {
        payload = JSON.parse(text) as GraphQLResponse<T>
      } catch {
        throw new Error(`the DreamDEX indexer answered "${text.slice(0, 60).trim()}"`)
      }
      if (payload.errors && payload.errors.length > 0) {
        // A GraphQL error is the server answering, not the network failing: do not retry it.
        throw new IndexerError(payload.errors.map((e) => e.message).join('; '))
      }
      if (payload.data === undefined) throw new IndexerError('the DreamDEX indexer returned no data')
      return payload.data
    } catch (cause) {
      lastError = cause
      if (cause instanceof IndexerError) throw cause
      if (signal?.aborted === true) throw cause
    }
  }

  throw new IndexerError(
    `the DreamDEX indexer could not be reached from your browser (${
      lastError instanceof Error ? lastError.message : String(lastError)
    })`,
  )
}

function toBigInt(value: string | null): bigint {
  return value === null ? 0n : BigInt(value)
}

function toNumber(value: string | null): number {
  return value === null ? 0 : Number(value)
}

function parseMarketRow(row: MarketRow): Market {
  return {
    marketId: row.marketId as Hex,
    asset: row.asset ?? '',
    question: row.question ?? '',
    strike: toBigInt(row.strike),
    tradingStart: toNumber(row.tradingStart),
    expiry: toNumber(row.expiry),
    intervalSec: toNumber(row.intervalSec),
    clobStatus: row.clobStatus ?? '',
    marketAddress: (row.marketAddress ?? '0x') as Address,
    poolAddress: (row.poolAddress ?? '0x') as Address,
    nonce: toNumber(row.nonce),
    venueId: (row.venueId ?? '0x') as Hex,
    lastPrice: row.lastPrice === null ? null : BigInt(row.lastPrice),
    finalized: row.finalized ?? false,
    voided: row.voided ?? false,
    winningOutcome: row.winningOutcome,
    resolvedAtTimestamp: row.resolvedAtTimestamp === null ? null : Number(row.resolvedAtTimestamp),
  }
}

/** Seconds of trading left in a window, floored at zero. */
export function secondsLeft(market: Market, now: number): number {
  return Math.max(0, market.expiry - now)
}

/**
 * Whether a desk could still legally enter this window.
 *
 * `clobStatus` is deliberately ignored. The indexer lags the chain by seconds to minutes, and a
 * row that still says `Trading` is routinely already past its expiry. Wall-clock time against
 * `expiry` is the only signal that does not lie, and the same 90-second slack is enforced
 * on chain by `PolicyLib`.
 */
export function isLive(market: Market, now: number): boolean {
  return !market.finalized && !market.voided && market.expiry > now + MIN_WINDOW_SLACK_SECONDS
}

const LIVE_QUERY = `
query LucidLiveWindows($cutoff: numeric!, $limit: Int!) {
  Market(
    limit: $limit
    order_by: { expiry: asc }
    where: {
      marketType: { _eq: "${BINARY_MARKET_TYPE}" }
      expiry: { _gt: $cutoff }
      finalized: { _eq: false }
    }
  ) {${MARKET_FIELDS}}
}`

/**
 * Every window still open, soonest expiry first.
 *
 * The `expiry > now + slack` cut is applied twice on purpose: once server-side so the response
 * stays small, and once locally so a slow round trip cannot hand back a window that expired
 * while the request was in flight.
 */
export async function fetchLiveWindows(limit = 40, signal?: AbortSignal): Promise<Market[]> {
  const now = Math.floor(Date.now() / 1000)
  const data = await queryIndexer<{ Market: MarketRow[] }>(
    LIVE_QUERY,
    { cutoff: String(now + MIN_WINDOW_SLACK_SECONDS), limit },
    signal,
  )
  return data.Market.map(parseMarketRow)
    .filter((m) => isLive(m, now))
    .sort((a, b) => a.expiry - b.expiry)
}

const SETTLED_QUERY = `
query LucidSettledWindows($limit: Int!) {
  Market(
    limit: $limit
    order_by: { resolvedAtTimestamp: desc_nulls_last }
    where: {
      marketType: { _eq: "${BINARY_MARKET_TYPE}" }
      clobStatus: { _eq: "${TERMINAL_STATUS}" }
    }
  ) {${MARKET_FIELDS}}
}`

/** The most recently settled windows, newest first. Filtered on the venue's only terminal status. */
export async function fetchSettledWindows(limit = 24, signal?: AbortSignal): Promise<Market[]> {
  const data = await queryIndexer<{ Market: MarketRow[] }>(SETTLED_QUERY, { limit }, signal)
  return data.Market.map(parseMarketRow)
}

const BY_IDS_QUERY = `
query LucidWindowsById($ids: [String!]) {
  Market(where: { marketId: { _in: $ids } }) {${MARKET_FIELDS}}
}`

/** The rows behind a set of market ids the chain already named. */
export async function fetchWindowsById(ids: readonly string[], signal?: AbortSignal): Promise<Market[]> {
  if (ids.length === 0) return []
  const data = await queryIndexer<{ Market: MarketRow[] }>(BY_IDS_QUERY, { ids }, signal)
  return data.Market.map(parseMarketRow)
}

/** Which side paid out. Outcome index 0 is UP on this venue; a voided window pays both legs. */
export function winnerLabel(market: Market): 'UP' | 'DOWN' | 'VOID' | 'pending' {
  if (market.voided) return 'VOID'
  if (market.winningOutcome === null) return 'pending'
  return market.winningOutcome === 0 ? 'UP' : 'DOWN'
}
