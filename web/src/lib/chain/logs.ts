import { decodeEventLog } from 'viem'
import type { Address, Hex, Log } from 'viem'
import { publicClient } from './client'
import { LOG_PAGE_SIZE, deployed } from './config'
import { brainAbi, deskAbi, routerAbi } from './synced'

/**
 * `eth_getLogs` is capped at 1 000 blocks per query and Shannon lands a block roughly every
 * 100 ms, so history is read by paging backwards in 950-block windows. There is no unbounded
 * range anywhere in this file, and every result carries the span it was read over so the
 * interface can say how far back it looked instead of implying it looked at everything.
 */
export interface ScanRange {
  head: bigint
  /** The oldest block actually queried. */
  from: bigint
  /** How many blocks the scan covered. */
  blocks: number
  /**
   * True when the scan stopped at its page budget — there is older history it did not read.
   * False when it walked back to block zero, which is the only case where "everything" is honest.
   */
  truncated: boolean
}

export interface Scan<T> extends ScanRange {
  events: T[]
}

interface PageOptions {
  /** How many 950-block pages to walk. Each is one round trip. */
  pages: number
  /** Stop early once this many decoded events are in hand. */
  enough?: number
  head?: bigint
}

/**
 * How many pages are in flight at once.
 *
 * Once the head block is pinned, the pages are independent, so they are fetched in concurrent
 * batches rather than one at a time — forty sequential round trips is several seconds on a slow
 * connection, and the reader is looking at a skeleton for every one of them. Batching keeps the
 * newest blocks first, so an early exit still stops at the newest events.
 */
const PAGE_CONCURRENCY = 8

async function pageBackwards(
  address: Address,
  options: PageOptions,
  onLogs: (logs: Log[]) => number,
): Promise<ScanRange> {
  const head = options.head ?? (await publicClient.getBlockNumber())
  let cursor = head
  let collected = 0
  let walked = 0

  for (let page = 0; page < options.pages; page += PAGE_CONCURRENCY) {
    const batch: { from: bigint; to: bigint }[] = []
    let reachedStart = false
    for (let i = 0; i < PAGE_CONCURRENCY && page + i < options.pages; i += 1) {
      const from = cursor - (LOG_PAGE_SIZE - 1n)
      if (from < 0n) {
        // Nothing older exists, so the scan is complete rather than cut short.
        if (cursor >= 0n) batch.push({ from: 0n, to: cursor })
        cursor = -1n
        reachedStart = true
        break
      }
      batch.push({ from, to: cursor })
      cursor = from - 1n
    }
    if (batch.length === 0) return { head, from: 0n, blocks: Number(head) + 1, truncated: false }

    const results = await Promise.all(
      batch.map(({ from, to }) => publicClient.getLogs({ address, fromBlock: from, toBlock: to })),
    )
    for (const logs of results) collected += onLogs(logs as Log[])

    const oldest = batch[batch.length - 1]!.from
    walked = Number(head - oldest) + 1

    if (options.enough !== undefined && collected >= options.enough) {
      return { head, from: oldest, blocks: walked, truncated: false }
    }
    if (reachedStart) return { head, from: 0n, blocks: walked, truncated: false }
  }

  return { head, from: cursor + 1n, blocks: walked, truncated: true }
}

/* ============================================================================
   Desk events — one desk's decision trail.
   ========================================================================== */

export interface DeskEventBase {
  blockNumber: bigint
  transactionHash: Hex
  logIndex: number
}

export type DeskEvent = DeskEventBase &
  (
    | { name: 'Considered'; marketId: Hex; intervalSec: number; assetKey: Hex }
    | { name: 'VerdictReceived'; marketId: Hex; probUpBps: number; pBookBps: number; responded: number }
    | { name: 'Executed'; marketId: Hex; kind: number; price: bigint; quantity: bigint; orderId: bigint }
    | { name: 'Refused'; marketId: Hex; reason: number; probUpBps: number; pBookBps: number }
    | { name: 'Settled'; marketId: Hex; pnl: bigint; equityAfter: bigint }
    | { name: 'ArmedSet'; on: boolean }
    | { name: 'PolicySet' }
  )

const DESK_EVENT_NAMES = new Set([
  'Considered',
  'VerdictReceived',
  'Executed',
  'Refused',
  'Settled',
  'ArmedSet',
  'PolicySet',
])

function decodeDesk(log: Log): DeskEvent | undefined {
  let decoded
  try {
    decoded = decodeEventLog({ abi: deskAbi, topics: log.topics, data: log.data })
  } catch {
    // A stream is a firehose; an unrecognised log is normal, not an error.
    return undefined
  }
  if (!DESK_EVENT_NAMES.has(decoded.eventName)) return undefined
  if (log.blockNumber === null || log.transactionHash === null || log.logIndex === null) return undefined
  const base: DeskEventBase = {
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    logIndex: log.logIndex,
  }
  return { ...base, name: decoded.eventName, ...decoded.args } as DeskEvent
}

/** One desk's history, newest first, over a bounded span of blocks. */
export async function scanDeskEvents(desk: Address, pages = 45, head?: bigint): Promise<Scan<DeskEvent>> {
  const events: DeskEvent[] = []
  const range = await pageBackwards(desk, head === undefined ? { pages } : { pages, head }, (logs) => {
    let added = 0
    for (const log of logs) {
      const event = decodeDesk(log)
      if (event !== undefined) {
        events.push(event)
        added += 1
      }
    }
    return added
  })
  events.sort(byNewestFirst)
  return { ...range, events }
}

/* ============================================================================
   Router events — the protocol's own behaviour.
   ========================================================================== */

export type RouterEvent = DeskEventBase &
  (
    | { name: 'MarketSeen'; marketId: Hex; intervalSec: number; assetKey: Hex }
    | { name: 'SettlementScheduled'; marketId: Hex; tsMillis: bigint; subscriptionId: bigint }
    | { name: 'DecisionScheduled'; marketId: Hex; tsMillis: bigint; subscriptionId: bigint }
    | { name: 'Skipped'; desk: Address; marketId: Hex; reason: string }
    | { name: 'VerdictRequested'; marketId: Hex; fee: bigint; deskCount: bigint }
    | { name: 'Debited'; desk: Address; marketId: Hex; amount: bigint }
    | { name: 'ToppedUp'; desk: Address; amount: bigint; balance: bigint }
    | { name: 'TradeReported'; desk: Address; marketId: Hex; kind: number; stake: bigint }
  )

const ROUTER_EVENT_NAMES = new Set([
  'MarketSeen',
  'SettlementScheduled',
  'DecisionScheduled',
  'Skipped',
  'VerdictRequested',
  'Debited',
  'ToppedUp',
  'TradeReported',
])

function decodeRouter(log: Log): RouterEvent | undefined {
  let decoded
  try {
    decoded = decodeEventLog({ abi: routerAbi, topics: log.topics, data: log.data })
  } catch {
    return undefined
  }
  if (!ROUTER_EVENT_NAMES.has(decoded.eventName)) return undefined
  if (log.blockNumber === null || log.transactionHash === null || log.logIndex === null) return undefined
  return {
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    logIndex: log.logIndex,
    name: decoded.eventName,
    ...decoded.args,
  } as RouterEvent
}

export async function scanRouterEvents(pages = 14, head?: bigint): Promise<Scan<RouterEvent>> {
  const events: RouterEvent[] = []
  const range = await pageBackwards(
    deployed.router,
    head === undefined ? { pages } : { pages, head },
    (logs) => {
      let added = 0
      for (const log of logs) {
        const event = decodeRouter(log)
        if (event !== undefined) {
          events.push(event)
          added += 1
        }
      }
      return added
    },
  )
  events.sort(byNewestFirst)
  return { ...range, events }
}

/* ============================================================================
   Brain events — the only place per-validator scores exist.
   ========================================================================== */

export type BrainEvent = DeskEventBase &
  (
    | {
        name: 'VerdictReceived'
        marketId: Hex
        requestId: bigint
        probUpBps: number
        responded: number
        agreed: number
        ok: boolean
        /**
         * Every raw validator answer that decoded, in subcommittee order, including the
         * out-of-range ones that were discarded before the median was taken.
         */
        scores: readonly bigint[]
      }
    | {
        name: 'PriceReceived'
        marketId: Hex
        requestId: bigint
        spot: bigint
        used: number
        prices: readonly bigint[]
      }
    | { name: 'PriceGuardRejected'; marketId: Hex; requestId: bigint; stale: number; thin: number }
    | { name: 'PriceUnusable'; marketId: Hex; requestId: bigint }
    | { name: 'VerdictRequested'; marketId: Hex; requestId: bigint; size: number; threshold: number; deposit: bigint }
    | { name: 'PriceRequested'; marketId: Hex; requestId: bigint; assetKey: Hex; deposit: bigint }
    | { name: 'WindowTooTight'; marketId: Hex; secondsLeft: bigint; requiredSlack: bigint }
    | { name: 'VerdictTooLate'; marketId: Hex; expiry: bigint; arrivedAt: bigint }
    | { name: 'LateAbort'; marketId: Hex; secondsLeft: bigint; needed: bigint }
    | { name: 'StageTwoUnfunded'; marketId: Hex; needed: bigint; available: bigint }
    | { name: 'LatencyObserved'; stage: number; observed: bigint; ema: bigint }
    | { name: 'NoFeed'; marketId: Hex; assetKey: Hex }
  )

const BRAIN_EVENT_NAMES = new Set([
  'VerdictReceived',
  'PriceReceived',
  'PriceGuardRejected',
  'PriceUnusable',
  'VerdictRequested',
  'PriceRequested',
  'WindowTooTight',
  'VerdictTooLate',
  'LateAbort',
  'StageTwoUnfunded',
  'LatencyObserved',
  'NoFeed',
])

function decodeBrain(log: Log): BrainEvent | undefined {
  let decoded
  try {
    decoded = decodeEventLog({ abi: brainAbi, topics: log.topics, data: log.data })
  } catch {
    return undefined
  }
  if (!BRAIN_EVENT_NAMES.has(decoded.eventName)) return undefined
  if (log.blockNumber === null || log.transactionHash === null || log.logIndex === null) return undefined
  return {
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    logIndex: log.logIndex,
    name: decoded.eventName,
    ...decoded.args,
  } as BrainEvent
}

export async function scanBrainEvents(pages = 24, head?: bigint): Promise<Scan<BrainEvent>> {
  const events: BrainEvent[] = []
  const range = await pageBackwards(
    deployed.brain,
    head === undefined ? { pages } : { pages, head },
    (logs) => {
      let added = 0
      for (const log of logs) {
        const event = decodeBrain(log)
        if (event !== undefined) {
          events.push(event)
          added += 1
        }
      }
      return added
    },
  )
  events.sort(byNewestFirst)
  return { ...range, events }
}

function byNewestFirst(a: DeskEventBase, b: DeskEventBase): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber > b.blockNumber ? -1 : 1
  return b.logIndex - a.logIndex
}

/* ============================================================================
   Windows — one desk's decision trail, folded back into the windows it belongs to.
   ========================================================================== */

export interface DeskWindow {
  marketId: Hex
  intervalSec: number
  assetKey: Hex
  /** The block the desk first touched this window in. */
  firstBlock: bigint
  lastBlock: bigint
  considered: boolean
  verdict?: { probUpBps: number; pBookBps: number; responded: number }
  executions: { kind: number; price: bigint; quantity: bigint; orderId: bigint }[]
  refusal?: { reason: number; probUpBps: number; pBookBps: number }
  settlement?: { pnl: bigint; equityAfter: bigint }
  transactionHash: Hex
}

/**
 * Folds a desk's flat event list into one entry per window, newest first.
 *
 * The canonical order for a window is `Considered → VerdictReceived → (Refused | Executed…) →
 * Settled`, and every stage is optional: a scan that starts mid-window sees the tail of one and
 * the head of another. Nothing here invents a stage that was not in the log.
 */
export function foldDeskWindows(events: readonly DeskEvent[]): DeskWindow[] {
  const byMarket = new Map<Hex, DeskWindow>()

  // Oldest first, so `firstBlock` and execution order come out right.
  for (const event of [...events].reverse()) {
    if (!('marketId' in event)) continue
    let window = byMarket.get(event.marketId)
    if (window === undefined) {
      window = {
        marketId: event.marketId,
        intervalSec: 0,
        assetKey: '0x' as Hex,
        firstBlock: event.blockNumber,
        lastBlock: event.blockNumber,
        considered: false,
        executions: [],
        transactionHash: event.transactionHash,
      }
      byMarket.set(event.marketId, window)
    }
    window.lastBlock = event.blockNumber

    switch (event.name) {
      case 'Considered':
        window.considered = true
        window.intervalSec = event.intervalSec
        window.assetKey = event.assetKey
        break
      case 'VerdictReceived':
        window.verdict = {
          probUpBps: event.probUpBps,
          pBookBps: event.pBookBps,
          responded: event.responded,
        }
        break
      case 'Executed':
        window.executions.push({
          kind: event.kind,
          price: event.price,
          quantity: event.quantity,
          orderId: event.orderId,
        })
        break
      case 'Refused':
        window.refusal = {
          reason: event.reason,
          probUpBps: event.probUpBps,
          pBookBps: event.pBookBps,
        }
        break
      case 'Settled':
        window.settlement = { pnl: event.pnl, equityAfter: event.equityAfter }
        break
      default:
        break
    }
  }

  return [...byMarket.values()].sort((a, b) => (a.lastBlock > b.lastBlock ? -1 : a.lastBlock < b.lastBlock ? 1 : 0))
}
