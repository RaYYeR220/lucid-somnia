/**
 * Read-only chain access: log paging under Somnia's 1000-block ceiling, and the one piece of
 * history the RPC itself cannot answer — where the brain was deployed.
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createPublicClient, defineChain, http, parseAbiItem } from 'viem'
import type { AbiEvent, Address, GetLogsReturnType, PublicClient } from 'viem'
import {
  CHAIN_ID,
  EXPLORER_API,
  FALLBACK_LOOKBACK_BLOCKS,
  HERE,
  LOG_PAGE_BLOCKS,
  LOG_PAGE_CONCURRENCY,
  RPC_URL,
} from './config.js'

export const shannon = defineChain({
  id: CHAIN_ID,
  name: 'Somnia Shannon',
  nativeCurrency: { name: 'Somnia', symbol: 'STT', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  testnet: true,
})

export function createClient(): PublicClient {
  // `batch` is off deliberately: the public endpoint answers a batched getLogs with a single
  // range error that names no page, which makes a failure impossible to localise.
  return createPublicClient({ chain: shannon, transport: http(RPC_URL) })
}

// ── event shapes ────────────────────────────────────────────────────────────

export const BRAIN_VERDICT_EVENT = parseAbiItem(
  'event VerdictReceived(bytes32 indexed marketId, uint256 indexed requestId, uint16 probUpBps, uint8 responded, uint8 agreed, bool ok, int256[] scores)',
) satisfies AbiEvent

export const DESK_VERDICT_EVENT = parseAbiItem(
  'event VerdictReceived(bytes32 indexed marketId, uint16 probUpBps, uint16 pBookBps, uint8 responded)',
) satisfies AbiEvent

export const DESK_REFUSED_EVENT = parseAbiItem(
  'event Refused(bytes32 indexed marketId, uint8 reason, uint16 probUpBps, uint16 pBookBps)',
) satisfies AbiEvent

export const ROUTER_SKIPPED_EVENT = parseAbiItem(
  'event Skipped(address indexed desk, bytes32 indexed marketId, string reason)',
) satisfies AbiEvent

export const FACTORY_DESK_CREATED_EVENT = parseAbiItem(
  'event DeskCreated(address indexed owner, address indexed desk)',
) satisfies AbiEvent

// ── paging ──────────────────────────────────────────────────────────────────

export interface BlockRange {
  fromBlock: bigint
  toBlock: bigint
}

function pagesFor(range: BlockRange): BlockRange[] {
  const pages: BlockRange[] = []
  for (let from = range.fromBlock; from <= range.toBlock; from += LOG_PAGE_BLOCKS) {
    const to = from + LOG_PAGE_BLOCKS - 1n
    pages.push({ fromBlock: from, toBlock: to > range.toBlock ? range.toBlock : to })
  }
  return pages
}

/** Logs for one event with `strict: true` — every arg present, nothing partial to guard. */
export type EventLogs<E extends AbiEvent> = GetLogsReturnType<
  E,
  E extends AbiEvent ? [E] : undefined,
  true,
  bigint,
  bigint
>

async function getLogsPage<E extends AbiEvent>(
  client: PublicClient,
  address: Address | undefined,
  event: E,
  page: BlockRange,
): Promise<EventLogs<E>> {
  const logs = await client.getLogs({
    ...(address === undefined ? {} : { address }),
    event,
    strict: true,
    fromBlock: page.fromBlock,
    toBlock: page.toBlock,
  })
  return logs
}

export interface ScanProgress {
  (done: number, total: number): void
}

/**
 * Every matching log in `range`, paged under the 1000-block ceiling and returned in block order.
 *
 * Pages run concurrently but are reassembled by index: a scan that returned logs in completion
 * order would put a later verdict before an earlier one and quietly corrupt any join that
 * assumes chronology.
 */
export async function scanLogs<E extends AbiEvent>(
  client: PublicClient,
  address: Address | undefined,
  event: E,
  range: BlockRange,
  onProgress?: ScanProgress,
): Promise<EventLogs<E>> {
  const pages = pagesFor(range)
  const results = new Array<EventLogs<E> | undefined>(pages.length).fill(undefined)
  let done = 0
  let next = 0

  const worker = async (): Promise<void> => {
    for (;;) {
      const index = next++
      const page = pages[index]
      if (page === undefined) return
      results[index] = await getLogsPage(client, address, event, page)
      done += 1
      onProgress?.(done, pages.length)
    }
  }

  await Promise.all(Array.from({ length: Math.min(LOG_PAGE_CONCURRENCY, pages.length) }, worker))

  const flat: EventLogs<E>[number][] = []
  for (const chunk of results) {
    if (chunk === undefined) continue
    flat.push(...chunk)
  }
  return flat
}

// ── deployment block ────────────────────────────────────────────────────────

const CACHE_PATH = join(HERE, '.scan-cache.json')

interface ScanCache {
  [address: string]: string
}

function readCache(): ScanCache {
  if (!existsSync(CACHE_PATH)) return {}
  try {
    return JSON.parse(readFileSync(CACHE_PATH, 'utf8')) as ScanCache
  } catch {
    return {}
  }
}

function writeCache(cache: ScanCache): void {
  writeFileSync(CACHE_PATH, `${JSON.stringify(cache, null, 2)}\n`)
}

export type DeployBlockSource = 'env' | 'cache' | 'explorer' | 'fallback'

export interface DeployBlock {
  block: bigint
  source: DeployBlockSource
  /** False when the start block is a guess, which makes the whole scan a lower bound. */
  exact: boolean
}

/**
 * Where to start scanning.
 *
 * Binary-searching `eth_getCode` — the usual trick — does not work here: the public Shannon
 * endpoint prunes state and answers `0x` for any historical block, including ones where the
 * contract demonstrably existed. The block explorer's creation record is the only free source
 * of the real number, so it is fetched once and then cached to disk; after the first run the
 * harness needs nothing but the RPC and the indexer.
 */
export async function resolveDeployBlock(address: Address, head: bigint): Promise<DeployBlock> {
  const override = process.env['LUCID_FROM_BLOCK']
  if (override !== undefined && override.trim() !== '') {
    return { block: BigInt(override.trim()), source: 'env', exact: true }
  }

  const cache = readCache()
  const key = address.toLowerCase()
  const cached = cache[key]
  if (cached !== undefined) return { block: BigInt(cached), source: 'cache', exact: true }

  try {
    const url = `${EXPLORER_API}?module=account&action=txlist&address=${address}&sort=asc&page=1&offset=1`
    const response = await fetch(url, { signal: AbortSignal.timeout(20_000) })
    if (response.ok) {
      const payload = (await response.json()) as {
        result?: readonly { blockNumber?: string; contractAddress?: string }[]
      }
      const first = payload.result?.[0]
      if (first?.blockNumber !== undefined && first.contractAddress?.toLowerCase() === key) {
        const block = BigInt(first.blockNumber)
        cache[key] = block.toString()
        writeCache(cache)
        return { block, source: 'explorer', exact: true }
      }
    }
  } catch {
    // Fall through to the labelled guess. An unreachable explorer must not stop a scan that
    // the RPC alone can still perform over a bounded window.
  }

  const floor = head > FALLBACK_LOOKBACK_BLOCKS ? head - FALLBACK_LOOKBACK_BLOCKS : 0n
  return { block: floor, source: 'fallback', exact: false }
}
