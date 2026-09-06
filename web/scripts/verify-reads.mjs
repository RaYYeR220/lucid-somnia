#!/usr/bin/env node
// Calls every read this app makes against the live deployment, and says which ones answered.
//
// The synced ABIs are widened to `Abi` at the parameterless-read helpers in
// src/lib/chain/reads.ts, because inferring a literal union over a hundred-plus-entry ABI hits
// TypeScript's instantiation-depth limit. This script is what replaces that lost name check: run
// it after `npm run sync-chain` and a name the deployment does not have shows up here rather than
// as an em dash on somebody's screen.
//
//   node scripts/verify-reads.mjs

import { createPublicClient, http } from 'viem'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const webRoot = resolve(here, '..')

const RPC_URL = 'https://api.infra.testnet.somnia.network'

// The synced module is TypeScript, so it is parsed rather than imported: this script has to
// run with plain node, with no build step and no dev dependency.
const synced = readFileSync(join(webRoot, 'src', 'lib', 'chain', 'synced.ts'), 'utf8')

function extractAbi(name) {
  const match = synced.match(new RegExp(`export const ${name} = \\[\\n([\\s\\S]*?)\\n\\] as const`))
  if (match === null) throw new Error(`synced.ts has no ${name}`)
  return match[1]
    .split('\n')
    .map((line) => line.trim().replace(/,$/, ''))
    .filter(Boolean)
    .map((line) => JSON.parse(line))
}

function extractDeployed() {
  const out = {}
  for (const [, key, value] of synced.matchAll(/^\s{2}(\w+): '(0x[0-9a-fA-F]+)',$/gm)) {
    out[key] = value
  }
  return out
}

const deployed = extractDeployed()
const abis = {
  router: extractAbi('routerAbi'),
  desk: extractAbi('deskAbi'),
  factory: extractAbi('factoryAbi'),
  brain: extractAbi('brainAbi'),
  keeper: extractAbi('keeperAbi'),
  relay: extractAbi('relayAbi'),
  series: extractAbi('seriesAbi'),
}

const client = createPublicClient({ transport: http(RPC_URL) })

/** Exactly the parameterless view calls the app makes, per contract. */
const READS = {
  router: [
    'totalGasCredit',
    'venue',
    'venueModule',
    'venueSubscriptionId',
    'brain',
    'factory',
    'keeper',
    'relay',
    'series',
    'armedDesks',
    'HANDLER_GAS_LIMIT',
    'MAX_FANOUT',
  ],
  brain: [
    'quote',
    'quoteStage1',
    'quoteStage2',
    'committeeSize',
    'committeeThreshold',
    'feedCommitteeSize',
    'feedThreshold',
    'requiredSlack',
    'feedLatencyEma',
    'verdictLatencyEma',
    'systemPrompt',
    'AGENT_ID',
    'feedAgentId',
    'oracleAgentId',
    'maxFeedAgeMillis',
    'minSources',
  ],
  keeper: ['counts', 'router'],
  relay: ['relayedCount', 'failedCount', 'MAX_PENDING'],
  series: [
    'status',
    'stalenessSeconds',
    'seriesId',
    'intervalSec',
    'maxRollsPerDay',
    'minCreatorFloat',
    'creator',
  ],
  factory: ['allDesks', 'deskCount', 'publishedDesks'],
}

const DESK_READS = ['owner', 'policy', 'state', 'equity', 'openNotional']

let failures = 0

function line(ok, label, detail) {
  const mark = ok ? 'ok  ' : 'FAIL'
  process.stdout.write(`${mark} ${label}${detail === undefined ? '' : `  ${detail}`}\n`)
  if (!ok) failures += 1
}

async function check(contract, address, functionName, args) {
  try {
    const value = await client.readContract({
      address,
      abi: abis[contract],
      functionName,
      ...(args ? { args } : {}),
    })
    const shown = typeof value === 'string' && value.length > 48 ? `${value.slice(0, 45)}…` : String(value)
    line(true, `${contract}.${functionName}()`, shown.length > 70 ? `${shown.slice(0, 70)}…` : shown)
  } catch (error) {
    line(false, `${contract}.${functionName}()`, error.shortMessage ?? error.message)
  }
}

process.stdout.write(`Reading the live deployment on chain 50312\n\n`)

for (const [contract, names] of Object.entries(READS)) {
  const address = deployed[contract]
  if (address === undefined) {
    line(false, `${contract}`, 'no address in synced.ts')
    continue
  }
  for (const name of names) await check(contract, address, name)
}

// The reactivity precompile is read over custom RPC methods, not `eth_call`.
try {
  const ids = await client.request({
    method: 'somnia_reactivityGetSubscriptions',
    params: [deployed.router],
  })
  line(true, 'somnia_reactivityGetSubscriptions(router)', `${ids.length} subscription(s)`)
  if (ids[0] !== undefined) {
    const rows = await client.request({
      method: 'somnia_reactivityGetSubscriptionInfo',
      params: [ids[0]],
    })
    line(rows.length > 0, 'somnia_reactivityGetSubscriptionInfo(id)', `${rows.length} row(s)`)
  }
} catch (error) {
  line(false, 'somnia_reactivity*', error.shortMessage ?? error.message)
}

// Then one real desk, if there is one.
try {
  const desks = await client.readContract({
    address: deployed.factory,
    abi: abis.factory,
    functionName: 'allDesks',
  })
  if (desks.length === 0) {
    line(true, 'factory.allDesks()', 'no desks deployed yet — desk reads skipped')
  } else {
    for (const name of DESK_READS) await check('desk', desks[0], name)
  }
} catch (error) {
  line(false, 'factory.allDesks()', error.shortMessage ?? error.message)
}

// And the public indexer, which is the app's only other source.
try {
  const response = await fetch('https://dev.smk.somnia.host/v1/graphql', {
    method: 'POST',
    headers: { 'content-type': 'text/plain;charset=UTF-8' },
    body: JSON.stringify({ query: '{ Market(limit: 1) { marketId } }' }),
  })
  const text = await response.text()
  const parsed = JSON.parse(text)
  line(parsed.data !== undefined, 'DreamDEX indexer', 'answered a Market query')
} catch (error) {
  line(false, 'DreamDEX indexer', error.message)
}

process.stdout.write(`\n${failures === 0 ? 'every read answered' : `${failures} read(s) failed`}\n`)
process.exit(failures === 0 ? 0 : 1)
