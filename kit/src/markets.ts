import type { Address, Hex } from 'viem'
import { INDEXER_URL, MIN_WINDOW_SLACK_SECONDS } from './addresses.js'
import { ASSETS, CADENCES } from './policy.js'

/**
 * DreamDEX's terminal market status.
 *
 * It is `"Finalized"`. It is never `"Resolved"` — that value simply does not exist in the
 * indexer, and a filter written against it silently returns an empty set forever.
 */
export const TERMINAL_STATUS = 'Finalized'

/** The indexer's marketType enum is uppercase; `"Binary"` matches nothing. */
export const BINARY_MARKET_TYPE = 'BINARY'

export class IndexerError extends Error {
  override readonly name = 'IndexerError'
}

/** One `Market` row exactly as Hasura returns it: every number is a string, nulls are real. */
export interface MarketRow {
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
  payoutNumerators: readonly string[] | null
  payoutDenominator: string | null
  resolvedAtTimestamp: string | null
}

/** A market row in the types the rest of the kit works in. */
export interface Market {
  marketId: Hex
  asset: string
  question: string
  /** Oracle strike, in the oracle's two-decimal scale (`8008333` is 80 083.33). */
  strike: bigint
  tradingStart: number
  expiry: number
  /** Window length in seconds — this is what `Policy.allowedCadences` is a mask over. */
  intervalSec: number
  clobStatus: string
  marketAddress: Address
  poolAddress: Address
  yesTokenId: bigint
  noTokenId: bigint
  nonce: number
  venueId: Hex
  /** Last traded price in raw 6-decimal collateral, so `550000` is 0.55. Null on an untraded book. */
  lastPrice: bigint | null
  finalized: boolean
  voided: boolean
  winningOutcome: number | null
  payoutNumerators: readonly bigint[]
  payoutDenominator: bigint | null
  resolvedAtTimestamp: number | null
}

const MARKET_FIELDS = `
  marketId
  asset
  question
  strike
  tradingStart
  expiry
  intervalSec
  clobStatus
  marketAddress
  poolAddress
  yesTokenId
  noTokenId
  nonce
  venueId
  lastPrice
  finalized
  voided
  winningOutcome
  payoutNumerators
  payoutDenominator
  resolvedAtTimestamp
`

interface GraphQLResponse<T> {
  data?: T
  errors?: readonly { message: string }[]
}

export interface IndexerOptions {
  /** Override the endpoint, e.g. to point at the mainnet indexer. */
  url?: string
  /** Abort signal, so a CLI that is Ctrl-C'd does not leave the request hanging. */
  signal?: AbortSignal
}

/**
 * Minimal typed GraphQL POST. The indexer needs no auth and imposes no rate limit, so there is
 * nothing here worth a client library — and a dependency-free query keeps `viem` the kit's only
 * runtime dependency.
 */
export async function queryIndexer<T>(
  query: string,
  variables: Record<string, unknown>,
  options: IndexerOptions = {},
): Promise<T> {
  const response = await fetch(options.url ?? INDEXER_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query, variables }),
    ...(options.signal ? { signal: options.signal } : {}),
  })
  if (!response.ok) {
    throw new IndexerError(`indexer returned HTTP ${response.status} ${response.statusText}`)
  }
  const payload = (await response.json()) as GraphQLResponse<T>
  if (payload.errors && payload.errors.length > 0) {
    throw new IndexerError(payload.errors.map((e) => e.message).join('; '))
  }
  if (payload.data === undefined) throw new IndexerError('indexer returned no data')
  return payload.data
}

function toBigInt(value: string | null): bigint {
  return value === null ? 0n : BigInt(value)
}

function toNumber(value: string | null): number {
  return value === null ? 0 : Number(value)
}

/** Normalises one Hasura row. Nothing here filters; parsing and policy stay separable. */
export function parseMarketRow(row: MarketRow): Market {
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
    yesTokenId: toBigInt(row.yesTokenId),
    noTokenId: toBigInt(row.noTokenId),
    nonce: toNumber(row.nonce),
    venueId: (row.venueId ?? '0x') as Hex,
    lastPrice: row.lastPrice === null ? null : BigInt(row.lastPrice),
    finalized: row.finalized ?? false,
    voided: row.voided ?? false,
    winningOutcome: row.winningOutcome,
    payoutNumerators: (row.payoutNumerators ?? []).map((n) => BigInt(n)),
    payoutDenominator: row.payoutDenominator === null ? null : BigInt(row.payoutDenominator),
    resolvedAtTimestamp: row.resolvedAtTimestamp === null ? null : Number(row.resolvedAtTimestamp),
  }
}

export interface LiveMarketsOptions extends IndexerOptions {
  /** Defaults to every asset a desk can trade. */
  assets?: readonly string[]
  /** Defaults to every cadence a desk can trade. */
  cadences?: readonly number[]
  /** How much of the window must still be left. Defaults to the protocol's 90-second slack. */
  minSecondsLeft?: number
  limit?: number
  /** Unix seconds; injectable so the filter is testable without a clock. */
  now?: number
}

/** Seconds of trading left in a window, floored at zero. */
export function secondsLeft(market: Market, now: number): number {
  return Math.max(0, market.expiry - now)
}

/**
 * The live-window filter, as a pure function so it can be tested without the network.
 *
 * It deliberately ignores `clobStatus`. The indexer lags behind the chain by seconds to minutes,
 * and a row that still says `Trading` is routinely already past its expiry — trade it and
 * `placeBinaryOrder` reverts `OrderAlreadyExpired`. Wall-clock time against `expiry` is the only
 * signal that does not lie, and the same 90-second slack is enforced on-chain by `PolicyLib`.
 */
export function filterLiveMarkets(markets: readonly Market[], options: LiveMarketsOptions = {}): Market[] {
  const assets = options.assets ?? ASSETS
  const cadences = options.cadences ?? CADENCES
  const minSecondsLeft = options.minSecondsLeft ?? MIN_WINDOW_SLACK_SECONDS
  const now = options.now ?? Math.floor(Date.now() / 1000)
  const cutoff = now + minSecondsLeft

  return markets
    .filter((m) => m.expiry > cutoff)
    .filter((m) => !m.finalized && !m.voided)
    .filter((m) => assets.includes(m.asset))
    .filter((m) => cadences.includes(m.intervalSec))
    .sort((a, b) => a.expiry - b.expiry)
}

/** Parse then filter, so a fixture response can be exercised end to end offline. */
export function selectLiveMarkets(rows: readonly MarketRow[], options: LiveMarketsOptions = {}): Market[] {
  return filterLiveMarkets(rows.map(parseMarketRow), options)
}

const LIVE_QUERY = `
query LucidLiveMarkets($cutoff: numeric!, $assets: [String!], $cadences: [numeric!], $limit: Int!) {
  Market(
    limit: $limit
    order_by: { expiry: asc }
    where: {
      marketType: { _eq: "${BINARY_MARKET_TYPE}" }
      expiry: { _gt: $cutoff }
      asset: { _in: $assets }
      intervalSec: { _in: $cadences }
      finalized: { _eq: false }
    }
  ) {${MARKET_FIELDS}}
}`

/**
 * Every window a desk could still legally enter, soonest expiry first.
 *
 * The `expiry > now + slack` cut is applied twice on purpose: once server-side so the response
 * stays small, and once locally so a slow round trip cannot hand back a window that expired
 * while the request was in flight.
 */
export async function liveMarkets(options: LiveMarketsOptions = {}): Promise<Market[]> {
  const now = options.now ?? Math.floor(Date.now() / 1000)
  const minSecondsLeft = options.minSecondsLeft ?? MIN_WINDOW_SLACK_SECONDS
  const assets = options.assets ?? ASSETS
  const cadences = options.cadences ?? CADENCES

  const data = await queryIndexer<{ Market: MarketRow[] }>(
    LIVE_QUERY,
    {
      cutoff: String(now + minSecondsLeft),
      assets,
      cadences: cadences.map(String),
      limit: options.limit ?? 50,
    },
    options,
  )
  return selectLiveMarkets(data.Market, { ...options, now, minSecondsLeft, assets, cadences })
}

export interface SettledMarketsOptions extends IndexerOptions {
  limit?: number
  assets?: readonly string[]
}

const SETTLED_QUERY = `
query LucidSettledMarkets($assets: [String!], $limit: Int!) {
  Market(
    limit: $limit
    order_by: { resolvedAtTimestamp: desc }
    where: {
      marketType: { _eq: "${BINARY_MARKET_TYPE}" }
      clobStatus: { _eq: "${TERMINAL_STATUS}" }
      asset: { _in: $assets }
    }
  ) {${MARKET_FIELDS}}
}`

/**
 * The most recently settled windows, newest first — the replay set the brain's accuracy is
 * graded against. Filtered on `clobStatus == "Finalized"`, the venue's only terminal status.
 */
export async function settledMarkets(options: SettledMarketsOptions = {}): Promise<Market[]> {
  const data = await queryIndexer<{ Market: MarketRow[] }>(
    SETTLED_QUERY,
    { assets: options.assets ?? ASSETS, limit: options.limit ?? 20 },
    options,
  )
  return data.Market.map(parseMarketRow)
}

/**
 * Which side paid out. Outcome index 0 is YES on this venue, and a voided market pays both
 * legs, so neither side "won".
 */
export function winnerLabel(market: Market): string {
  if (market.voided) return 'VOID'
  if (market.winningOutcome === null) return 'pending'
  return market.winningOutcome === 0 ? 'YES' : 'NO'
}
