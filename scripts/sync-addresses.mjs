#!/usr/bin/env node
// Regenerates the address tables in README.md and JUDGES.md from contracts/deployed.json.
//
// The tables sit between `<!-- addresses:start -->` and `<!-- addresses:end -->` markers and are
// written by this script, never by hand. A redeploy changes every address at once, and an address
// table that is edited in three places by hand is a table that is wrong in one of them.
//
// Node 18+, no dependencies.
//
//   node scripts/sync-addresses.mjs           rewrite the blocks
//   node scripts/sync-addresses.mjs --check   exit 1 if anything is out of date, change nothing

import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..')
const DEPLOYED = join(ROOT, 'contracts', 'deployed.json')
const TARGETS = [join(ROOT, 'README.md'), join(ROOT, 'JUDGES.md')]

const START = '<!-- addresses:start -->'
const END = '<!-- addresses:end -->'

/** Explorers keyed by chain id. A chain we have no explorer for gets a table with no links. */
const EXPLORERS = {
  50312: { name: 'Somnia Shannon', url: 'https://shannon-explorer.somnia.network' },
  5031: { name: 'Somnia', url: 'https://explorer.somnia.network' },
}

/**
 * Display names, in the order the table lists them. The router is first because it is the only
 * contract that talks to the reactivity precompile, and everything else is reachable from it.
 */
const LABELS = [
  ['router', 'LucidRouter'],
  ['brain', 'LucidBrain'],
  ['deskImplementation', 'LucidDesk (clone implementation)'],
  ['factory', 'LucidFactory'],
  ['keeper', 'LucidKeeper'],
  ['relay', 'LucidRelay'],
  ['series', 'LucidSeries'],
  ['demoDesk', 'Demo desk (clone)'],
  ['marketCreator', 'MarketCreator (ours)'],
]

/** Labels for the bytes32 identifiers that are not contracts and must not go in the table. */
const ID_LABELS = {
  venueId: 'DreamDEX venue this deployment serves',
  ownVenueId: 'Our own venue, used by the failover roller',
}

const isAddress = (v) => typeof v === 'string' && /^0x[0-9a-fA-F]{40}$/.test(v)
const isBytes32 = (v) => typeof v === 'string' && /^0x[0-9a-fA-F]{64}$/.test(v)

/** `deskImplementation` -> `Desk implementation`, for a key nobody has named yet. */
function humanise(key) {
  const spaced = key.replace(/([a-z0-9])([A-Z])/g, '$1 $2')
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

function render(deployed) {
  const chainId = Number(deployed.chainId)
  const explorer = EXPLORERS[chainId]
  if (!explorer) {
    console.warn(`warning: no explorer known for chain ${chainId}; addresses will not be linked`)
  }

  const named = new Map(LABELS)
  const ordered = []
  for (const [key, label] of LABELS) {
    if (isAddress(deployed[key])) ordered.push([label, deployed[key]])
  }
  for (const [key, value] of Object.entries(deployed)) {
    if (isAddress(value) && !named.has(key)) ordered.push([humanise(key), value])
  }

  const lines = []
  lines.push(START)
  lines.push('<!-- Written by scripts/sync-addresses.mjs from contracts/deployed.json. Do not edit by hand. -->')
  lines.push('')
  lines.push('| contract | address |')
  lines.push('| --- | --- |')
  for (const [label, address] of ordered) {
    const cell = explorer ? `[\`${address}\`](${explorer.url}/address/${address})` : `\`${address}\``
    lines.push(`| \`${label}\` | ${cell} |`)
  }
  lines.push('')

  const chainName = explorer ? explorer.name : 'chain'
  lines.push(`- Chain: ${chainName}, id \`${chainId}\`.`)
  if (explorer) lines.push(`- Explorer: <${explorer.url}>`)
  // Named ids first, in the order they are documented, then anything else that looks like one.
  const idKeys = Object.keys(ID_LABELS).filter((k) => isBytes32(deployed[k]))
  for (const key of Object.keys(deployed)) {
    if (isBytes32(deployed[key]) && !idKeys.includes(key)) idKeys.push(key)
  }
  for (const key of idKeys) {
    lines.push(`- ${ID_LABELS[key] ?? humanise(key)}: \`${deployed[key]}\``)
  }
  lines.push('')
  lines.push(END)
  return { lines, count: ordered.length }
}

function replaceBlock(source, block, file) {
  const start = source.indexOf(START)
  const end = source.indexOf(END)
  if (start === -1 || end === -1) {
    throw new Error(`${file}: missing ${START} / ${END} markers`)
  }
  if (end < start) {
    throw new Error(`${file}: ${END} appears before ${START}`)
  }
  // Preserve whatever line ending the file already uses; a doc that flips to CRLF on every sync
  // produces a diff nobody can read.
  const eol = source.includes('\r\n') ? '\r\n' : '\n'
  return source.slice(0, start) + block.join(eol) + source.slice(end + END.length)
}

function main() {
  const check = process.argv.includes('--check')

  let deployed
  try {
    deployed = JSON.parse(readFileSync(DEPLOYED, 'utf8'))
  } catch (error) {
    console.error(`cannot read ${relative(ROOT, DEPLOYED)}: ${error.message}`)
    console.error('run contracts/deploy.sh first, or point this script at a repository that has one')
    process.exit(2)
  }

  const { lines: block, count: addressCount } = render(deployed)
  let stale = 0

  for (const file of TARGETS) {
    const name = relative(ROOT, file)
    let source
    try {
      source = readFileSync(file, 'utf8')
    } catch (error) {
      console.error(`cannot read ${name}: ${error.message}`)
      process.exit(2)
    }

    let updated
    try {
      updated = replaceBlock(source, block, name)
    } catch (error) {
      console.error(String(error.message))
      process.exit(2)
    }

    if (updated === source) {
      console.log(`${name}: up to date`)
      continue
    }
    stale += 1
    if (check) {
      console.log(`${name}: OUT OF DATE`)
      continue
    }
    writeFileSync(file, updated)
    console.log(`${name}: updated`)
  }

  if (check && stale > 0) {
    console.error(`\n${stale} file(s) out of date — run: node scripts/sync-addresses.mjs`)
    process.exit(1)
  }
  if (!check) {
    console.log(`\n${addressCount} address(es) from contracts/deployed.json, chain ${deployed.chainId}`)
  }
}

main()
