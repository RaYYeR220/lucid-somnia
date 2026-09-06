'use client'

import { useEffect, useState } from 'react'
import type { Address } from 'viem'
import { publicClient } from './chain/client'
import { deployed } from './chain/config'
import {
  readAllDesks,
  readBrainStatus,
  readDeskTable,
  readDesk,
  readKeeperStatus,
  readRelayStatus,
  readRouterStatus,
  readSeriesStatus,
} from './chain/reads'
import { scanBrainEvents, scanDeskEvents, scanRouterEvents } from './chain/logs'
import { getOwnedSubscriptions } from './chain/subscriptions'
import { fetchLiveWindows, fetchSettledWindows } from './indexer'
import { useQuery } from './query'

/**
 * A wall clock that ticks once a second on the client and never on the server.
 *
 * Countdowns are the one thing on these pages that cannot be rendered at build time without
 * lying, so they start as `null` and every consumer draws a skeleton until the first tick lands.
 * That also makes the markup hydration-safe: the server never renders a time at all.
 */
export function useNow(intervalMs = 1000): number | null {
  const [now, setNow] = useState<number | null>(null)
  useEffect(() => {
    setNow(Math.floor(Date.now() / 1000))
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs)
    return () => clearInterval(timer)
  }, [intervalMs])
  return now
}

/** True once the component has mounted in a browser. */
export function useMounted(): boolean {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  return mounted
}

/* ============================================================================
   Shared reads. Every hook below is keyed, so two components asking the same
   question make one request.
   ========================================================================== */

export function useBlockNumber() {
  return useQuery('block', () => publicClient.getBlockNumber(), { refreshMs: 4000 })
}

export function useRouterStatus() {
  return useQuery('router', () => readRouterStatus(), { refreshMs: 15_000 })
}

export function useBrainStatus() {
  return useQuery('brain', () => readBrainStatus(), { refreshMs: 30_000 })
}

export function useKeeperStatus(routerKeeper: Address | undefined) {
  return useQuery(
    routerKeeper === undefined ? null : `keeper:${routerKeeper}`,
    () => readKeeperStatus(routerKeeper as Address),
    { refreshMs: 30_000 },
  )
}

export function useRelayStatus(routerRelay: Address | undefined) {
  return useQuery(
    routerRelay === undefined ? null : `relay:${routerRelay}`,
    () => readRelayStatus(routerRelay as Address),
    { refreshMs: 30_000 },
  )
}

export function useSeriesStatus(routerSeries: Address | undefined) {
  return useQuery(
    routerSeries === undefined ? null : `series:${routerSeries}`,
    () => readSeriesStatus(routerSeries as Address),
    { refreshMs: 30_000 },
  )
}

export function useSubscriptions() {
  return useQuery('subs', () => getOwnedSubscriptions(deployed.router), { refreshMs: 15_000 })
}

export function useDeskTable() {
  return useQuery('desks', () => readDeskTable(), { refreshMs: 20_000 })
}

export function useDesk(address: Address | undefined) {
  return useQuery(address === undefined ? null : `desk:${address}`, () => readDesk(address as Address), {
    refreshMs: 15_000,
  })
}

/**
 * One desk's decision trail. `pages` bounds the scan; each page is one 950-block `eth_getLogs`
 * round trip, and the result reports the span it covered so the interface can say so.
 */
export function useDeskEvents(address: Address | undefined, pages = 45) {
  return useQuery(
    address === undefined ? null : `deskLogs:${address}:${pages}`,
    () => scanDeskEvents(address as Address, pages),
    { refreshMs: 30_000 },
  )
}

export function useRouterEvents(pages = 14) {
  return useQuery(`routerLogs:${pages}`, () => scanRouterEvents(pages), { refreshMs: 30_000 })
}

export function useBrainEvents(pages = 24) {
  return useQuery(`brainLogs:${pages}`, () => scanBrainEvents(pages), { refreshMs: 30_000 })
}

export function useLiveWindows(limit = 40) {
  return useQuery(`liveWindows:${limit}`, () => fetchLiveWindows(limit), { refreshMs: 20_000 })
}

export function useSettledWindows(limit = 24) {
  return useQuery(`settledWindows:${limit}`, () => fetchSettledWindows(limit), { refreshMs: 60_000 })
}

/* ============================================================================
   Protocol-wide activity — every desk's decision trail, over one bounded span.
   ========================================================================== */

export interface ProtocolActivity {
  /** Per desk, in factory order. */
  desks: { address: Address; scan: Awaited<ReturnType<typeof scanDeskEvents>> }[]
  /** The span every scan covered, so the interface can say how far back it looked. */
  head: bigint
  from: bigint
  blocks: number
  considered: number
  verdicts: number
  executed: number
  refused: number
  settled: number
  /** Refusal counts by reason code, commonest first. */
  refusalTally: { code: number; count: number }[]
}

/**
 * Every desk's events over the same block span, aggregated.
 *
 * The span is bounded and reported rather than implied: `eth_getLogs` is capped at 1 000 blocks
 * per query, so "all of history" is not a thing this front end can honestly offer without an
 * indexer it does not have.
 */
export function useProtocolActivity(pages = 30) {
  return useQuery(
    `activity:${pages}`,
    async (): Promise<ProtocolActivity> => {
      const head = await publicClient.getBlockNumber()
      const addresses = await readAllDesks()
      const scans = await Promise.all(addresses.map((address) => scanDeskEvents(address, pages, head)))

      let considered = 0
      let verdicts = 0
      let executed = 0
      let refused = 0
      let settled = 0
      const byReason = new Map<number, number>()
      let from = head

      for (const scan of scans) {
        if (scan.from < from) from = scan.from
        for (const event of scan.events) {
          if (event.name === 'Considered') considered += 1
          else if (event.name === 'VerdictReceived') verdicts += 1
          else if (event.name === 'Executed') executed += 1
          else if (event.name === 'Settled') settled += 1
          else if (event.name === 'Refused') {
            refused += 1
            byReason.set(event.reason, (byReason.get(event.reason) ?? 0) + 1)
          }
        }
      }

      return {
        desks: addresses.map((address, index) => ({ address, scan: scans[index]! })),
        head,
        from,
        blocks: Number(head - from) + 1,
        considered,
        verdicts,
        executed,
        refused,
        settled,
        refusalTally: [...byReason.entries()]
          .map(([code, count]) => ({ code, count }))
          .sort((a, b) => b.count - a.count),
      }
    },
    { refreshMs: 30_000 },
  )
}
