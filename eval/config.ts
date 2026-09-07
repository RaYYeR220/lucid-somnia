/**
 * Everything the harness needs to point itself at the live deployment.
 *
 * Addresses are read from `contracts/deployed.json` at run time rather than copied here, so a
 * redeploy cannot leave the harness silently grading a contract nobody is running any more.
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Address } from 'viem'

export const HERE = dirname(fileURLToPath(import.meta.url))
export const REPO_ROOT = join(HERE, '..')

export const CHAIN_ID = 50312
export const RPC_URL = process.env['LUCID_RPC_URL'] ?? 'https://api.infra.testnet.somnia.network'
export const INDEXER_URL = process.env['LUCID_INDEXER_URL'] ?? 'https://dev.smk.somnia.host/v1/graphql'
export const EXPLORER_API = 'https://shannon-explorer.somnia.network/api'

/**
 * Somnia rejects an `eth_getLogs` span wider than 1000 blocks outright
 * (`block range exceeds 1000`). 950 leaves headroom for the inclusive endpoint arithmetic.
 */
export const LOG_PAGE_BLOCKS = 950n

/** Parallel `eth_getLogs` pages. Blocks are ~100 ms here, so a day of history is ~860k blocks. */
export const LOG_PAGE_CONCURRENCY = 8

/**
 * Used only when the deployment block cannot be resolved from the explorer and no override is
 * given. A scan that starts here is partial, and the harness labels it as such rather than
 * reporting a sample size it cannot vouch for.
 */
export const FALLBACK_LOOKBACK_BLOCKS = 900_000n

interface DeployedJson {
  chainId: number
  brain: string
  router: string
  factory: string
  /** Seed desks. Older deployments named a single `demoDesk`; later ones name one per strategy. */
  demoDesk?: string
  deskAiEdge?: string
  deskMaker?: string
}

export interface Deployment {
  chainId: number
  brain: Address
  router: Address
  factory: Address
  /**
   * The desks named in `deployed.json`. These are a floor, not the registry: `LucidRouter.allDesks()`
   * is the authoritative set, because it answers for every desk ever registered rather than for the
   * ones a `DeskCreated` scan happened to catch inside its block range.
   */
  seedDesks: Address[]
}

export function loadDeployment(): Deployment {
  const raw = readFileSync(join(REPO_ROOT, 'contracts', 'deployed.json'), 'utf8')
  const parsed = JSON.parse(raw) as DeployedJson
  if (parsed.chainId !== CHAIN_ID) {
    throw new Error(`deployed.json is for chain ${parsed.chainId}, expected ${CHAIN_ID}`)
  }
  return {
    chainId: parsed.chainId,
    brain: parsed.brain as Address,
    router: parsed.router as Address,
    factory: parsed.factory as Address,
    seedDesks: [parsed.demoDesk, parsed.deskAiEdge, parsed.deskMaker]
      .filter((a): a is string => typeof a === 'string' && a.length > 0)
      .map((a) => a.toLowerCase() as Address),
  }
}

/**
 * The probability scale used everywhere in this protocol. Mirrored from `LucidTypes.BPS` in
 * `contracts/src/types/LucidTypes.sol`.
 */
export const BPS = 10_000

/**
 * What a book-probability field carries when there was no book to read.
 *
 * Mirrored from `LucidTypes.BOOK_UNOBSERVED` in `contracts/src/types/LucidTypes.sol`, where it is
 * `type(uint16).max`. It sits outside the 0..`BPS` probability range on purpose: it is the marker
 * for the ABSENCE of a quote, not a quote of 655.35 %.
 *
 * The contracts learned this the hard way — subtracting the sentinel from a verdict produced a
 * 60435 bps "edge" and sized six times equity against a window nobody had quoted. The rule the
 * desk now states is quoted in `contracts/src/LucidDesk.sol`: a value that encodes ABSENCE must
 * never be an arithmetic input. This harness is bound by the same rule, which is why every metric
 * that touches a book value filters on this constant before it divides anything.
 */
export const BOOK_UNOBSERVED_BPS = 65_535

/**
 * `LucidTypes.Refusal`, in declaration order — the desk emits the enum as a `uint8`, so the
 * ordering here is the only thing that turns a log into a reason. Mirrored from
 * `contracts/src/types/LucidTypes.sol`. A reordering there without a matching one here would
 * mislabel every refusal, so an index past the end is reported as `Unknown` rather than being
 * folded silently into a neighbouring reason.
 *
 * The last three were appended when `VenueRejected` was split: it used to stand for an unreadable
 * book, an unquotable price range and the venue refusing an order all at once, which made a
 * refusal table unable to say which of the three had happened.
 */
export const REFUSAL_NAMES = [
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
  'NoBook',
  'BookUnreadable',
  'Unquotable',
  'MintFailed',
] as const

export type RefusalName = (typeof REFUSAL_NAMES)[number] | 'Unknown'

export function refusalName(index: number): RefusalName {
  return REFUSAL_NAMES[index] ?? 'Unknown'
}
