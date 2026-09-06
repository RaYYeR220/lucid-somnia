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
  demoDesk: string
}

export interface Deployment {
  chainId: number
  brain: Address
  router: Address
  factory: Address
  demoDesk: Address
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
    demoDesk: parsed.demoDesk as Address,
  }
}

/**
 * `LucidTypes.Refusal`, in declaration order — the desk emits the enum as a `uint8`, so the
 * ordering here is the only thing that turns a log into a reason. Mirrored from
 * `contracts/src/types/LucidTypes.sol`. A reordering there without a matching one here would
 * mislabel every refusal, so an index past the end is reported as `Unknown` rather than being
 * folded silently into a neighbouring reason.
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
] as const

export type RefusalName = (typeof REFUSAL_NAMES)[number] | 'Unknown'

export function refusalName(index: number): RefusalName {
  return REFUSAL_NAMES[index] ?? 'Unknown'
}
