#!/usr/bin/env node
// Rebuilds src/lib/chain/synced.ts from the repository's own sources of truth.
//
// The ABIs are never typed by hand and never live in two places. They come from the Foundry
// artifacts in ../contracts/out when a build is present, and otherwise from kit/src/abis.ts,
// which is itself written from the same artifacts. Addresses come from contracts/deployed.json,
// the file the deploy script writes. Run it before every build; `npm run build` already does.
//
//   node scripts/sync-chain.mjs

import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const webRoot = resolve(here, '..')
const repoRoot = resolve(webRoot, '..')
const contractsRoot = join(repoRoot, 'contracts')
const outRoot = join(contractsRoot, 'out')

/**
 * Which artifact becomes which exported constant.
 * `file` is the Foundry layout: out/<file>.sol/<artifact>.json
 */
const TARGETS = [
  { name: 'routerAbi', file: 'LucidRouter', artifact: 'LucidRouter' },
  { name: 'deskAbi', file: 'LucidDesk', artifact: 'LucidDesk' },
  { name: 'factoryAbi', file: 'LucidFactory', artifact: 'LucidFactory' },
  { name: 'brainAbi', file: 'LucidBrain', artifact: 'LucidBrain' },
  { name: 'keeperAbi', file: 'LucidKeeper', artifact: 'LucidKeeper' },
  { name: 'relayAbi', file: 'LucidRelay', artifact: 'LucidRelay' },
  { name: 'seriesAbi', file: 'LucidSeries', artifact: 'LucidSeries' },
  // tUSDC on Shannon exposes a public faucet; the interface artifact carries the ERC-20 surface.
  { name: 'collateralAbi', file: 'IDreamDex', artifact: 'IERC20Faucet' },
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

function readArtifactAbi(file, artifact) {
  const path = join(outRoot, `${file}.sol`, `${artifact}.json`)
  const parsed = JSON.parse(readFileSync(path, 'utf8'))
  if (!Array.isArray(parsed.abi)) throw new Error(`${path} has no \`abi\` array`)
  return stripInternalTypes(parsed.abi)
}

/**
 * Fallback for a checkout with no Foundry build: kit/src/abis.ts carries the same artifacts,
 * already written. It covers fewer contracts than the artifacts do, so the fallback is a
 * degraded build, not an equivalent one — say so rather than emitting a half file silently.
 */
function readKitAbis() {
  const path = join(repoRoot, 'kit', 'src', 'abis.ts')
  if (!existsSync(path)) return null
  const source = readFileSync(path, 'utf8')
  const found = new Map()
  const re = /export const (\w+) = \[\n([\s\S]*?)\n\] as const/g
  let match
  while ((match = re.exec(source)) !== null) {
    const entries = match[2]
      .split('\n')
      .map((line) => line.trim().replace(/,$/, ''))
      .filter(Boolean)
      .map((line) => JSON.parse(line))
    found.set(match[1], entries)
  }
  return found
}

const haveArtifacts = existsSync(outRoot)
const kitAbis = haveArtifacts ? null : readKitAbis()
if (!haveArtifacts && kitAbis === null) {
  // A deployment platform builds `web/` on its own, without the contracts workspace beside it.
  // The generated file is committed precisely so that build can succeed; regenerating it is a
  // developer convenience, not a build requirement. Failing here would make the app undeployable
  // for the sake of a step that has nothing left to do.
  const committed = join(webRoot, 'src', 'lib', 'chain', 'synced.ts')
  if (existsSync(committed)) {
    console.log('sync-chain: no contract artifacts here — keeping the committed src/lib/chain/synced.ts')
    process.exit(0)
  }
  throw new Error(
    `no ABI source found — expected Foundry artifacts in ${outRoot} (run \`forge build\` in contracts/) ` +
      `or an already-synced kit/src/abis.ts`,
  )
}

const abis = TARGETS.map((target) => {
  if (haveArtifacts) return { ...target, abi: readArtifactAbi(target.file, target.artifact) }
  const abi = kitAbis.get(target.name)
  if (abi === undefined) {
    process.stderr.write(
      `warning: ${target.name} is absent from kit/src/abis.ts; emitting an empty ABI. ` +
        `Run \`forge build\` in contracts/ for the complete set.\n`,
    )
    return { ...target, abi: [] }
  }
  return { ...target, abi }
})

/** Deterministic, diffable formatting: one ABI entry per line. */
function renderAbi(name, abi) {
  const body = abi.map((entry) => `  ${JSON.stringify(entry)},`).join('\n')
  return `export const ${name} = [\n${body}\n] as const\n`
}

const deployedPath = join(contractsRoot, 'deployed.json')
const deployed = JSON.parse(readFileSync(deployedPath, 'utf8'))

const REQUIRED = [
  'chainId',
  'deskImplementation',
  'brain',
  'router',
  'factory',
  'keeper',
  'relay',
  'series',
  'venueId',
]
for (const key of REQUIRED) {
  if (deployed[key] === undefined) throw new Error(`${deployedPath} is missing \`${key}\``)
}

/**
 * Every desk address the deploy wrote alongside the protocol.
 *
 * The key names track whatever the deploy script felt like calling them — `demoDesk` in one
 * deployment, `deskAiEdge` and `deskMaker` in the next — so they are matched by shape: any key
 * that starts with `desk` and is not the clone implementation.
 */
const seedDesks = Object.entries(deployed)
  .filter(
    ([key, value]) =>
      /^(desk|demoDesk)/.test(key) &&
      key !== 'deskImplementation' &&
      typeof value === 'string' &&
      /^0x[0-9a-fA-F]{40}$/.test(value),
  )
  .map(([, value]) => value)

const banner = `// AUTO-SYNCED — do not edit by hand.
// Written by web/scripts/sync-chain.mjs from ${haveArtifacts ? 'the Foundry artifacts in contracts/out' : 'kit/src/abis.ts'}
// and contracts/deployed.json. Refresh with: npm run sync-chain
`

const deployedBlock = `/** The live deployment, copied from contracts/deployed.json when this file was written. */
export const deployed = {
  chainId: ${deployed.chainId},
  /** ERC-1167 master copy every user desk is cloned from. Never call it directly. */
  deskImplementation: '${deployed.deskImplementation}',
  brain: '${deployed.brain}',
  /** Handles every reactivity callback and owns the wake-ups it books; must hold >= 32 SOMI. */
  router: '${deployed.router}',
  /**
   * Owns the venue's MarketCreated subscription on a bond of its own, with the router as its
   * handler. Undefined on deployments that predate it, where the router owns that one too.
   */
  watch: ${deployed.watch ? `'${deployed.watch}'` : 'undefined'},
  factory: '${deployed.factory}',
  keeper: '${deployed.keeper}',
  relay: '${deployed.relay}',
  series: '${deployed.series}',
  /** The market creator LucidSeries rolls a window through when the venue's scheduler stalls. */
  marketCreator: '${deployed.marketCreator ?? '0x0000000000000000000000000000000000000000'}',
  /** The DreamDEX venue the router is armed against. */
  venueId: '${deployed.venueId}',
  /** Our own venue, used only by the failover roller. */
  ownVenueId: '${deployed.ownVenueId ?? '0x' + '0'.repeat(64)}',
  /**
   * Desks deployed alongside the protocol, so a build with no network still has a page to
   * pre-render. The deploy script names them by strategy and the set changes between
   * deployments, so they are collected by shape rather than by a fixed key.
   */
  seedDesks: [${seedDesks.map((address) => `'${address}'`).join(', ')}] as readonly string[],
} as const
`

const file = [banner, deployedBlock, ...abis.map((t) => renderAbi(t.name, t.abi))].join('\n')

const target = join(webRoot, 'src', 'lib', 'chain', 'synced.ts')
mkdirSync(dirname(target), { recursive: true })
writeFileSync(target, file)

const counts = abis.map((t) => `${t.name}=${t.abi.length}`).join(' ')
process.stdout.write(
  `synced src/lib/chain/synced.ts from ${haveArtifacts ? 'contracts/out' : 'kit/src/abis.ts'}\n` +
    `  chain ${deployed.chainId} · ${counts}\n`,
)
