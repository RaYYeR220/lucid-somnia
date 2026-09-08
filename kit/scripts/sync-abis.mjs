#!/usr/bin/env node
// Rebuilds src/abis.ts and src/deployed.ts from the Foundry build output next door.
//
// Hand-copied ABIs rot the moment a contract changes, and a stale ABI fails at the worst
// possible time: a silently mis-decoded event, or an encoded call the chain rejects. So the
// kit treats `contracts/out` as the single source of truth and this file as a build step,
// not as a one-off import. Run it after every `forge build`; the diff is the review.
//
//   node scripts/sync-abis.mjs [--contracts <dir>]

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const kitRoot = resolve(here, '..')

const flagIndex = process.argv.indexOf('--contracts')
const contractsRoot =
  flagIndex !== -1 && process.argv[flagIndex + 1]
    ? resolve(process.argv[flagIndex + 1])
    : resolve(kitRoot, '..', 'contracts')

/**
 * Which artifacts become which exported constant.
 * `file` is the Foundry layout: out/<file>.sol/<artifact>.json
 */
const TARGETS = [
  { export: 'routerAbi', file: 'LucidRouter', artifact: 'LucidRouter' },
  { export: 'deskAbi', file: 'LucidDesk', artifact: 'LucidDesk' },
  { export: 'factoryAbi', file: 'LucidFactory', artifact: 'LucidFactory' },
  { export: 'brainAbi', file: 'LucidBrain', artifact: 'LucidBrain' },
  // tUSDC on Shannon exposes a public faucet, which is how a desk funds itself with no
  // off-chain signature at all. The kit needs the same surface to fund one from a terminal.
  { export: 'collateralAbi', file: 'IDreamDex', artifact: 'IERC20Faucet' },
]

/** Foundry stamps `internalType` on every input; viem ignores it and it triples the file size. */
function stripInternalTypes(node) {
  if (Array.isArray(node)) return node.map(stripInternalTypes)
  if (node === null || typeof node !== 'object') return node
  const out = {}
  for (const [key, value] of Object.entries(node)) {
    if (key === 'internalType') continue
    out[key] = stripInternalTypes(value)
  }
  return out
}

function readAbi(file, artifact) {
  const path = join(contractsRoot, 'out', `${file}.sol`, `${artifact}.json`)
  let raw
  try {
    raw = readFileSync(path, 'utf8')
  } catch {
    throw new Error(`missing artifact ${path} — run \`forge build\` in ${contractsRoot} first`)
  }
  const parsed = JSON.parse(raw)
  if (!Array.isArray(parsed.abi)) throw new Error(`${path} has no \`abi\` array`)
  return stripInternalTypes(parsed.abi)
}

/** Deterministic, diffable formatting: one ABI entry per line, stable key order from the artifact. */
function renderAbi(name, abi) {
  const body = abi.map((entry) => `  ${JSON.stringify(entry)},`).join('\n')
  return `export const ${name} = [\n${body}\n] as const\n`
}

const banner = `// AUTO-SYNCED — do not edit by hand.
// Written by scripts/sync-abis.mjs from the Foundry artifacts in contracts/out.
// Refresh with: npm run sync-abis
`

const abiFile = [banner, ...TARGETS.map((t) => renderAbi(t.export, readAbi(t.file, t.artifact)))].join(
  '\n',
)

const deployedPath = join(contractsRoot, 'deployed.json')
const deployed = JSON.parse(readFileSync(deployedPath, 'utf8'))

const REQUIRED = ['chainId', 'deskImplementation', 'brain', 'router', 'factory', 'keeper', 'relay', 'venueId']
for (const key of REQUIRED) {
  if (deployed[key] === undefined) throw new Error(`${deployedPath} is missing \`${key}\``)
}

const deployedFile = `${banner}
/** Live Lucid deployment, copied from contracts/deployed.json when this file was written. */
export const deployed = {
  chainId: ${deployed.chainId},
  /** ERC-1167 master copy every user desk is cloned from. Never call it directly. */
  deskImplementation: '${deployed.deskImplementation}',
  brain: '${deployed.brain}',
  /**
   * Handles every reactivity callback, and owns the wake-up subscriptions it books itself.
   * Must hold >= 32 SOMI to keep them alive.
   */
  router: '${deployed.router}',
  /**
   * Owns the venue's \`MarketCreated\` subscription and names the router as its handler, on a bond
   * of its own. Absent on deployments that predate it, where the router owns that one too.
   */
  watch: ${deployed.watch ? `'${deployed.watch}'` : 'undefined'},
  factory: '${deployed.factory}',
  keeper: '${deployed.keeper}',
  relay: '${deployed.relay}',
  /** DreamDEX venue the router is armed against. */
  venueId: '${deployed.venueId}',
} as const
`

mkdirSync(join(kitRoot, 'src'), { recursive: true })
writeFileSync(join(kitRoot, 'src', 'abis.ts'), abiFile)
writeFileSync(join(kitRoot, 'src', 'deployed.ts'), deployedFile)

const counts = TARGETS.map((t) => `${t.export}=${readAbi(t.file, t.artifact).length}`).join(' ')
process.stdout.write(`synced src/abis.ts (${counts})\nsynced src/deployed.ts (chain ${deployed.chainId})\n`)
