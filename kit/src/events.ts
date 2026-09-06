import { decodeEventLog } from 'viem'
import type { Address, Hex, Log } from 'viem'
import { deskAbi, routerAbi } from './abis.js'
import { addresses } from './addresses.js'
import { createLucidPublicClient } from './client.js'
import type { LucidPublicClient } from './client.js'
import { ASSETS, assetKey } from './policy.js'

/**
 * `LucidTypes.Refusal`, in declaration order. `None` is the only value that permits a trade;
 * every other value is a reason the desk said no out loud instead of failing quietly.
 */
export const REFUSALS = [
  'None',
  'NotArmed',
  'AssetNotAllowed',
  'CadenceNotAllowed',
  'WindowTooShort',
  'CapExceeded',
  'DailyBudgetExceeded',
  'MaxOpenReached',
  'RiskHalt',
  'AiUnavailable',
  'AiMalformed',
  'LowEdge',
  'VenueRejected',
  'NoCredit',
  'InsufficientFunds',
] as const

export type RefusalName = (typeof REFUSALS)[number]

/** Label for a refusal code, or `Unknown(n)` for a code minted by a newer contract than this kit. */
export function refusalName(code: number): string {
  return REFUSALS[code] ?? `Unknown(${code})`
}

/** One sentence per refusal, for interfaces that show a person why nothing happened. */
export const REFUSAL_REASONS: Readonly<Record<RefusalName, string>> = {
  None: 'the mandate allowed the trade',
  NotArmed: 'the desk is switched off',
  AssetNotAllowed: 'the mandate does not cover this asset',
  CadenceNotAllowed: 'the mandate does not cover this window length',
  WindowTooShort: 'too little time left to place an order safely',
  CapExceeded: 'the order would breach the per-window notional cap',
  DailyBudgetExceeded: "today's budget is spent",
  MaxOpenReached: 'every open-market slot is already taken',
  RiskHalt: 'drawdown or loss streak halted the desk',
  AiUnavailable: 'the agent committee did not answer in time',
  AiMalformed: 'the committee answered out of range',
  LowEdge: 'the committee and the book agree, so there is nothing to trade',
  VenueRejected: 'the venue would not accept the order',
  NoCredit: 'the desk has no gas credit left at the router',
  InsufficientFunds: 'not enough free collateral to fund the position',
}

/** `placeBinaryOrder` side encoding, as emitted in `Executed.kind`. */
export const ORDER_KINDS = ['BUY_YES', 'SELL_YES', 'BUY_NO', 'SELL_NO'] as const

export function orderKindName(kind: number): string {
  return ORDER_KINDS[kind] ?? `Unknown(${kind})`
}

/**
 * Reverses `keccak256(bytes(symbol))` for the symbols a desk can actually trade.
 * The log carries the hash, and a hash is not readable; this is a two-entry lookup, not a guess.
 */
export function assetSymbolFromKey(key: Hex): string {
  const normalized = key.toLowerCase()
  for (const symbol of ASSETS) {
    if (assetKey(symbol).toLowerCase() === normalized) return symbol
  }
  return `${key.slice(0, 10)}…`
}

/** Where the log came from. Desk logs are one user's story; router logs are the protocol's. */
export type LucidEventSource = 'desk' | 'router'

interface LogMeta {
  address: Address
  blockNumber: bigint | null
  transactionHash: Hex | null
  logIndex: number | null
}

export type LucidEvent = LogMeta &
  (
    | {
        source: 'desk'
        name: 'Considered'
        args: { marketId: Hex; intervalSec: number; assetKey: Hex }
      }
    | {
        source: 'desk'
        name: 'VerdictReceived'
        args: { marketId: Hex; probUpBps: number; pBookBps: number; responded: number }
      }
    | {
        source: 'desk'
        name: 'Executed'
        args: { marketId: Hex; kind: number; price: bigint; quantity: bigint; orderId: bigint }
      }
    | {
        source: 'desk'
        name: 'Refused'
        args: { marketId: Hex; reason: number; probUpBps: number; pBookBps: number }
      }
    | {
        source: 'desk'
        name: 'Settled'
        args: { marketId: Hex; pnl: bigint; equityAfter: bigint }
      }
    | {
        source: 'router'
        name: 'MarketSeen'
        args: { marketId: Hex; intervalSec: number; assetKey: Hex }
      }
    | {
        source: 'router'
        name: 'SettlementScheduled'
        args: { marketId: Hex; tsMillis: bigint; subscriptionId: bigint }
      }
    | {
        source: 'router'
        name: 'Skipped'
        args: { desk: Address; marketId: Hex; reason: string }
      }
  )

export type LucidEventName = LucidEvent['name']

/** The desk-side events the kit decodes, in the order one window produces them. */
export const DESK_EVENTS = [
  'Considered',
  'VerdictReceived',
  'Executed',
  'Refused',
  'Settled',
] as const

/** The router-side events that explain the protocol's own behaviour. */
export const ROUTER_EVENTS = ['MarketSeen', 'SettlementScheduled', 'Skipped'] as const

type RawLog = Pick<Log, 'address' | 'topics' | 'data'> &
  Partial<Pick<Log, 'blockNumber' | 'transactionHash' | 'logIndex'>>

function meta(log: RawLog): LogMeta {
  return {
    address: log.address,
    blockNumber: log.blockNumber ?? null,
    transactionHash: log.transactionHash ?? null,
    logIndex: log.logIndex ?? null,
  }
}

/**
 * Decodes one log against the desk ABI. Returns `undefined` rather than throwing for anything
 * this kit does not model: a stream is a firehose, and an unrecognised log is normal, not an error.
 */
export function decodeDeskLog(log: RawLog): LucidEvent | undefined {
  let decoded
  try {
    decoded = decodeEventLog({ abi: deskAbi, topics: log.topics, data: log.data })
  } catch {
    return undefined
  }
  if (!(DESK_EVENTS as readonly string[]).includes(decoded.eventName)) return undefined
  // The name check above has already narrowed this to a member of the union; viem's own
  // inference cannot follow a runtime `includes`, so the assertion states what the guard proved.
  return { source: 'desk', ...meta(log), name: decoded.eventName, args: decoded.args } as LucidEvent
}

/** Decodes one log against the router ABI. Same contract as {@link decodeDeskLog}. */
export function decodeRouterLog(log: RawLog): LucidEvent | undefined {
  let decoded
  try {
    decoded = decodeEventLog({ abi: routerAbi, topics: log.topics, data: log.data })
  } catch {
    return undefined
  }
  if (!(ROUTER_EVENTS as readonly string[]).includes(decoded.eventName)) return undefined
  return { source: 'router', ...meta(log), name: decoded.eventName, args: decoded.args } as LucidEvent
}

/**
 * Decodes a log by its emitter: router address means router ABI, anything else is a desk.
 * The two ABIs share event names (`MarketSeen` and `Considered` are the same shape), so the
 * emitter is the only honest discriminator.
 */
export function decodeLucidLog(log: RawLog): LucidEvent | undefined {
  return log.address.toLowerCase() === addresses.router.toLowerCase()
    ? decodeRouterLog(log)
    : decodeDeskLog(log)
}

/** One line per event, in the terms a person reads a trading log in. */
export function formatEvent(event: LucidEvent): string {
  switch (event.name) {
    case 'Considered':
      return `Considered  ${short(event.args.marketId)} ${assetSymbolFromKey(
        event.args.assetKey,
      )} ${event.args.intervalSec}s`
    case 'VerdictReceived':
      return `Verdict     ${short(event.args.marketId)} committee ${pct(
        event.args.probUpBps,
      )} vs book ${pct(event.args.pBookBps)} (${event.args.responded} validators)`
    case 'Executed':
      return `Executed    ${short(event.args.marketId)} ${orderKindName(event.args.kind)} ${
        event.args.quantity
      } @ ${price(event.args.price)} order #${event.args.orderId}`
    case 'Refused':
      return `Refused     ${short(event.args.marketId)} ${refusalName(
        event.args.reason,
      )} — ${reasonText(event.args.reason)}`
    case 'Settled':
      return `Settled     ${short(event.args.marketId)} pnl ${signed(event.args.pnl)} equity ${usdc(
        event.args.equityAfter,
      )}`
    case 'MarketSeen':
      return `MarketSeen  ${short(event.args.marketId)} ${assetSymbolFromKey(
        event.args.assetKey,
      )} ${event.args.intervalSec}s`
    case 'SettlementScheduled':
      return `Scheduled   ${short(event.args.marketId)} at ${new Date(
        Number(event.args.tsMillis),
      ).toISOString()} (sub ${event.args.subscriptionId})`
    case 'Skipped':
      return `Skipped     ${short(event.args.marketId)} desk ${short(event.args.desk)} — ${
        event.args.reason
      }`
  }
}

function reasonText(code: number): string {
  const name = REFUSALS[code]
  return name === undefined ? 'unknown refusal code' : REFUSAL_REASONS[name]
}

function short(value: string): string {
  return value.length > 12 ? `${value.slice(0, 8)}…${value.slice(-4)}` : value
}

function pct(bps: number): string {
  return `${(bps / 100).toFixed(1)}%`
}

/** Venue prices are raw 6-decimal collateral, so `550000` is 0.55 of a contract. */
function price(raw: bigint): string {
  return (Number(raw) / 1e6).toFixed(4)
}

function usdc(raw: bigint): string {
  return (Number(raw) / 1e6).toFixed(2)
}

function signed(raw: bigint): string {
  const value = Number(raw) / 1e6
  return `${value >= 0 ? '+' : ''}${value.toFixed(2)}`
}

export interface WatchDeskOptions {
  publicClient?: LucidPublicClient
  /** Also stream the router's own events, so refusals have their protocol context. */
  includeRouter?: boolean
  /** Milliseconds between polls. Shannon blocks are sub-second; 1000 is plenty. */
  pollingInterval?: number
  onError?: (error: Error) => void
}

/**
 * Streams one desk's decision trail.
 *
 * Deliberately a subscription you own and cancel, not a loop this kit runs for you: Lucid has no
 * daemon anywhere, and a library that quietly kept a process alive would be the very thing the
 * protocol exists to avoid. Call the returned function to stop.
 */
export function watchDesk(
  deskAddress: Address,
  onEvent: (event: LucidEvent) => void,
  options: WatchDeskOptions = {},
): () => void {
  const client = options.publicClient ?? createLucidPublicClient()
  const pollingInterval = options.pollingInterval ?? 1_000
  const onError = options.onError
  const unwatchers: (() => void)[] = []

  unwatchers.push(
    client.watchContractEvent({
      address: deskAddress,
      abi: deskAbi,
      pollingInterval,
      poll: true,
      onLogs: (logs) => {
        for (const log of logs) {
          const decoded = decodeDeskLog(log)
          if (decoded !== undefined) onEvent(decoded)
        }
      },
      ...(onError ? { onError } : {}),
    }),
  )

  if (options.includeRouter !== false) {
    unwatchers.push(
      client.watchContractEvent({
        address: addresses.router,
        abi: routerAbi,
        pollingInterval,
        poll: true,
        onLogs: (logs) => {
          for (const log of logs) {
            const decoded = decodeRouterLog(log)
            if (decoded === undefined) continue
            // Router logs are protocol-wide. Only `Skipped` names a desk, so that is the only
            // one worth filtering; `MarketSeen` and `SettlementScheduled` are context for all.
            if (
              decoded.name === 'Skipped' &&
              decoded.args.desk.toLowerCase() !== deskAddress.toLowerCase()
            ) {
              continue
            }
            onEvent(decoded)
          }
        },
        ...(onError ? { onError } : {}),
      }),
    )
  }

  return () => {
    for (const unwatch of unwatchers) unwatch()
  }
}

/** Reads a desk's history instead of following it forward. Useful for a post-mortem. */
export async function getDeskHistory(
  publicClient: LucidPublicClient,
  deskAddress: Address,
  fromBlock: bigint,
  toBlock: bigint | 'latest' = 'latest',
): Promise<LucidEvent[]> {
  const logs = await publicClient.getLogs({ address: deskAddress, fromBlock, toBlock })
  const out: LucidEvent[] = []
  for (const log of logs) {
    const decoded = decodeDeskLog(log)
    if (decoded !== undefined) out.push(decoded)
  }
  return out
}
