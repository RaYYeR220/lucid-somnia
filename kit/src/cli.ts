#!/usr/bin/env node
import { parseArgs } from 'node:util'
import { pathToFileURL } from 'node:url'
import { formatEther, isAddress, parseEther } from 'viem'
import type { Address } from 'viem'
import {
  COLLATERAL_SYMBOL,
  EXPLORER_URL,
  INDEXER_URL,
  MIN_WINDOW_SLACK_SECONDS,
  RPC_URL,
  SUBSCRIPTION_OWNER_MINIMUM_BALANCE,
  addresses,
  explorerAddress,
  explorerTx,
} from './addresses.js'
import {
  MissingKeyError,
  accountFromEnv,
  clientsFromEnv,
  createLucidPublicClient,
} from './client.js'
import type { LucidClients, LucidPublicClient } from './client.js'
import {
  allDesks,
  arm,
  createDesk,
  deposit,
  deskOf,
  fundFromFaucet,
  readDesk,
  setPolicy,
  topUpGasCredit,
} from './desk.js'
import type { DeskSnapshot } from './desk.js'
import { formatEvent, watchDesk } from './events.js'
import { liveMarkets, secondsLeft, settledMarkets, winnerLabel } from './markets.js'
import type { Market } from './markets.js'
import {
  ASSETS,
  CADENCES,
  STRATEGY_NAMES,
  decodePolicy,
  describePolicy,
  encodePolicy,
  fromCollateral,
  strategyName,
  toCollateral,
} from './policy.js'
import type { AssetSymbol, Cadence, PolicyDraft, StrategyName } from './policy.js'
import { readArmedDesks, readProtocolStatus } from './protocol.js'
import { describeSubscription, getOwnedSubscriptions, hasSafeGasLimit } from './subscriptions.js'

const OPTIONS = {
  help: { type: 'boolean', short: 'h' },
  json: { type: 'boolean' },
  rpc: { type: 'string' },
  owner: { type: 'string' },

  // policy
  assets: { type: 'string' },
  cadences: { type: 'string' },
  'max-stake': { type: 'string' },
  'daily-budget': { type: 'string' },
  'max-open': { type: 'string' },
  'min-edge': { type: 'string' },
  'max-drawdown': { type: 'string' },
  'max-losses': { type: 'string' },
  strategy: { type: 'string' },

  // arm / fund
  on: { type: 'boolean' },
  off: { type: 'boolean' },
  amount: { type: 'string' },
  faucet: { type: 'boolean' },
  gas: { type: 'string' },

  // markets / watch
  limit: { type: 'string' },
  'min-seconds-left': { type: 'string' },
  settled: { type: 'boolean' },
  'no-router': { type: 'boolean' },
} as const

const POLICY_FLAGS = [
  'assets',
  'cadences',
  'max-stake',
  'daily-budget',
  'max-open',
  'min-edge',
  'max-drawdown',
  'max-losses',
  'strategy',
] as const

const DEFAULT_DRAFT: PolicyDraft = {
  maxStakePerWindow: '5',
  dailyBudget: '50',
  maxOpenMarkets: 2,
  maxDrawdownBps: 2_000,
  maxConsecutiveLosses: 3,
  minEdgeBps: 300,
  assets: ['BTC', 'ETH'],
  // 60 s windows can never clear the 90 s slack, so the default mandate leaves that bit off.
  cadences: [300, 900],
  strategy: 'AiEdge',
  armed: false,
}

const HELP = `lucid — inspect and drive Lucid desks on Somnia Shannon (chain 50312)

USAGE
  lucid <command> [options]

COMMANDS
  status                     Protocol overview: addresses, router balance vs the 32-SOMI
                             subscription floor, live reactivity subscriptions, armed desks.
  desk create                Deploy your desk with an opening mandate.               [needs key]
  desk policy [desk]         Show the mandate, or replace it when policy flags are given.
  desk arm [desk] --on|--off Arm or disarm the desk at the desk and the router.       [needs key]
  desk fund [desk]           Move collateral in, or top up the desk's STT credit.     [needs key]
  desk status [desk]         Owner, mandate, equity, balances, armed-at-router flag.
  markets                    Live windows from the DreamDEX indexer (--settled for history).
  watch <desk>               Stream that desk's decision trail as it happens.
  subs <address>             Decode the reactivity subscriptions an address owns.

OPTIONS
  -h, --help                 Show this help.
      --json                 Machine-readable output.
      --rpc <url>            Override the RPC endpoint.
      --owner <address>      Look up a desk by owner instead of passing the desk address.

  policy flags (desk create / desk policy)
      --assets <list>        Comma-separated, from: ${ASSETS.join(', ')}.
      --cadences <list>      Comma-separated seconds, from: ${CADENCES.join(', ')}.
      --max-stake <${COLLATERAL_SYMBOL}>    Per-window notional cap.
      --daily-budget <${COLLATERAL_SYMBOL}> Cap on one UTC day.
      --max-open <n>         Concurrent open markets.
      --min-edge <bps>       Required disagreement with the book.
      --max-drawdown <bps>   Fall below the high-water mark that halts the desk.
      --max-losses <n>       Consecutive losses that halt the desk.
      --strategy <name>      AiEdge or Maker.

  desk arm
      --on / --off           Which way to flip it.

  desk fund
      --amount <${COLLATERAL_SYMBOL}>       Collateral to move in (deposited from your wallet).
      --faucet               Mint the amount from the testnet faucet instead of depositing.
      --gas <STT>            Credit the router with STT for handler gas and AI verdicts.

  markets
      --assets, --cadences   Same syntax as the policy flags.
      --min-seconds-left <n> Window slack to require. Default ${MIN_WINDOW_SLACK_SECONDS}.
      --limit <n>            How many rows.
      --settled              Show finalized windows instead of live ones.

  watch
      --no-router            Desk events only; skip the router's own log.

ENVIRONMENT
  PRIVATE_KEY                Read only by the commands marked [needs key]. Every read command
                             works with no key set at all.

Endpoints: RPC ${RPC_URL}
           indexer ${INDEXER_URL}
           explorer ${EXPLORER_URL}
`

type Values = ReturnType<typeof parseArgs<{ options: typeof OPTIONS; allowPositionals: true }>>['values']

class UsageError extends Error {
  override readonly name = 'UsageError'
}

function out(line = ''): void {
  process.stdout.write(`${line}\n`)
}

/** JSON with bigints as decimal strings — a bigint would otherwise throw on serialisation. */
function printJson(value: unknown): void {
  out(JSON.stringify(value, (_key, v: unknown) => (typeof v === 'bigint' ? v.toString() : v), 2))
}

function requireAddress(value: string | undefined, what: string): Address {
  if (value === undefined) throw new UsageError(`missing ${what}`)
  if (!isAddress(value)) throw new UsageError(`${what} is not an address: ${value}`)
  return value
}

function intOption(values: Values, name: keyof typeof OPTIONS, fallback: number): number {
  const raw = values[name]
  if (typeof raw !== 'string') return fallback
  const parsed = Number(raw)
  if (!Number.isFinite(parsed)) throw new UsageError(`--${String(name)} must be a number`)
  return parsed
}

function listOption(values: Values, name: 'assets' | 'cadences'): string[] | undefined {
  const raw = values[name]
  if (typeof raw !== 'string') return undefined
  return raw
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
}

/** Validates rather than casts: an unknown symbol becomes a usage error, never a silent 0 bit. */
function asAssets(list: readonly string[]): AssetSymbol[] {
  return list.map((name) => {
    const found = ASSETS.find((asset) => asset === name)
    if (found === undefined) {
      throw new UsageError(`unknown asset ${name}; expected one of ${ASSETS.join(', ')}`)
    }
    return found
  })
}

function asCadences(list: readonly string[]): Cadence[] {
  return list.map((raw) => {
    const found = CADENCES.find((cadence) => cadence === Number(raw))
    if (found === undefined) {
      throw new UsageError(`unknown cadence ${raw}; expected one of ${CADENCES.join(', ')}`)
    }
    return found
  })
}

function asStrategy(name: string): StrategyName {
  const found = STRATEGY_NAMES.find((candidate) => candidate === name)
  if (found === undefined) {
    throw new UsageError(`unknown strategy ${name}; expected one of ${STRATEGY_NAMES.join(', ')}`)
  }
  return found
}

function draftFrom(values: Values, base: PolicyDraft): PolicyDraft {
  const assets = listOption(values, 'assets')
  const cadences = listOption(values, 'cadences')
  return {
    maxStakePerWindow: values['max-stake'] ?? base.maxStakePerWindow,
    dailyBudget: values['daily-budget'] ?? base.dailyBudget,
    maxOpenMarkets: intOption(values, 'max-open', base.maxOpenMarkets),
    maxDrawdownBps: intOption(values, 'max-drawdown', base.maxDrawdownBps),
    maxConsecutiveLosses: intOption(values, 'max-losses', base.maxConsecutiveLosses),
    minEdgeBps: intOption(values, 'min-edge', base.minEdgeBps),
    assets: assets === undefined ? base.assets : asAssets(assets),
    cadences: cadences === undefined ? base.cadences : asCadences(cadences),
    strategy: values.strategy === undefined ? base.strategy : asStrategy(values.strategy),
    armed: base.armed,
  }
}

function hasPolicyFlags(values: Values): boolean {
  return POLICY_FLAGS.some((flag) => values[flag] !== undefined)
}

/** The desk to act on: an explicit address, `--owner`'s desk, or the signer's own desk. */
async function resolveDesk(
  client: LucidPublicClient,
  positional: string | undefined,
  values: Values,
): Promise<Address> {
  if (positional !== undefined) return requireAddress(positional, 'desk address')

  const owner =
    values.owner !== undefined
      ? requireAddress(values.owner, '--owner')
      : ownerFromEnvOrUndefined()
  if (owner === undefined) {
    throw new UsageError('pass a desk address, or --owner <address>, or set PRIVATE_KEY')
  }
  const desk = await deskOf(client, owner)
  if (desk === undefined) throw new UsageError(`${owner} has no desk yet — run \`lucid desk create\``)
  return desk
}

function ownerFromEnvOrUndefined(): Address | undefined {
  try {
    return accountFromEnv().address
  } catch (error) {
    if (error instanceof MissingKeyError) return undefined
    throw error
  }
}

function fmtStt(wei: bigint): string {
  return `${Number(formatEther(wei)).toFixed(4)} STT`
}

function fmtCollateral(raw: bigint): string {
  return `${fromCollateral(raw)} ${COLLATERAL_SYMBOL}`
}

// -- commands ---------------------------------------------------------------

async function cmdStatus(values: Values): Promise<void> {
  const client = publicClient(values)
  const status = await readProtocolStatus(client)

  if (values.json === true) {
    printJson(status)
    return
  }

  out('LUCID — Somnia Shannon 50312')
  out('')
  out('Contracts')
  for (const [name, address] of Object.entries(addresses)) {
    out(`  ${name.padEnd(20)} ${address}`)
  }
  out('')
  out('Router')
  out(`  balance              ${fmtStt(status.routerBalance)}`)
  out(`  subscription floor   ${fmtStt(SUBSCRIPTION_OWNER_MINIMUM_BALANCE)}`)
  out(
    `  headroom             ${status.aboveSubscriptionFloor ? '+' : ''}${fmtStt(
      status.floorMargin,
    )}  ${
      status.aboveSubscriptionFloor
        ? 'OK'
        : 'BELOW FLOOR — the precompile will drop every subscription'
    }`,
  )
  out(`  desk gas credit      ${fmtStt(status.totalGasCredit)} reserved for desks`)
  out(`  venue module         ${status.venueModule}`)
  out(`  venue subscription   #${status.venueSubscriptionId}`)
  out('')
  out(`Subscriptions (${status.subscriptions.length})`)
  if (status.subscriptions.length === 0) {
    out('  none — the router is deaf; nothing will wake it on a new market')
  }
  for (const sub of status.subscriptions) {
    out(`  #${sub.id}  ${describeSubscription(sub)}`)
    if (!hasSafeGasLimit(sub)) {
      out('       warning: below the 5M gas floor — the handler is billed and never runs')
    }
  }
  out('')

  const [everyDesk, armed] = await Promise.all([
    allDesks(client),
    readArmedDesks(client, status.armedDesks),
  ])
  out(`Desks — ${everyDesk.length} created, ${armed.length} armed`)
  if (armed.length === 0) out('  none armed')
  for (const snapshot of armed) {
    out(
      `  ${snapshot.address}  equity ${fmtCollateral(snapshot.equity)}  credit ${fmtStt(
        snapshot.gasCredit,
      )}  ${strategyName(snapshot.policy.strategy)}`,
    )
  }
  out('')
  out(`Explorer: ${explorerAddress(addresses.router)}`)
}

async function cmdDeskCreate(values: Values): Promise<void> {
  const clients = writeClients(values)
  const draft = draftFrom(values, DEFAULT_DRAFT)
  const policy = encodePolicy(draft)

  const existing = await deskOf(clients.publicClient, clients.walletClient.account.address)
  if (existing !== undefined) {
    throw new UsageError(`${clients.walletClient.account.address} already owns desk ${existing}`)
  }

  const { hash, desk } = await createDesk(clients, policy)
  if (values.json === true) {
    printJson({ desk, hash, policy })
    return
  }
  out(`desk    ${desk}`)
  out(`tx      ${explorerTx(hash)}`)
  out('')
  for (const line of describePolicy(policy)) out(line)
  out('')
  out('The desk is created disarmed and empty. Next:')
  out(`  lucid desk fund ${desk} --faucet --amount 500 --gas 0.5`)
  out(`  lucid desk arm ${desk} --on`)
}

async function cmdDeskPolicy(values: Values, positional: string | undefined): Promise<void> {
  const client = publicClient(values)
  const desk = await resolveDesk(client, positional, values)
  const snapshot = await readDesk(client, desk)

  if (!hasPolicyFlags(values)) {
    if (values.json === true) {
      printJson({ desk, policy: snapshot.policy })
      return
    }
    out(`Desk ${desk}`)
    for (const line of describePolicy(snapshot.policy)) out(line)
    return
  }

  const clients = writeClients(values)
  // Start from the live mandate, so a single flag edits one field instead of silently resetting
  // every other rule the owner set.
  const draft = draftFrom(values, decodePolicy(snapshot.policy))
  const policy = encodePolicy({ ...draft, armed: snapshot.policy.armed })
  const hash = await setPolicy(clients, desk, policy)

  if (values.json === true) {
    printJson({ desk, hash, policy })
    return
  }
  out(`tx      ${explorerTx(hash)}`)
  out('')
  for (const line of describePolicy(policy)) out(line)
}

async function cmdDeskArm(values: Values, positional: string | undefined): Promise<void> {
  if (values.on === true && values.off === true) throw new UsageError('pass --on or --off, not both')
  if (values.on !== true && values.off !== true) throw new UsageError('pass --on or --off')
  const on = values.on === true

  const clients = writeClients(values)
  const desk = await resolveDesk(clients.publicClient, positional, values)
  const hash = await arm(clients, desk, on)

  if (values.json === true) {
    printJson({ desk, armed: on, hash })
    return
  }
  out(`desk ${desk} ${on ? 'armed' : 'disarmed'}`)
  out(`tx   ${explorerTx(hash)}`)
}

async function cmdDeskFund(values: Values, positional: string | undefined): Promise<void> {
  const clients = writeClients(values)
  const desk = await resolveDesk(clients.publicClient, positional, values)
  const results: Record<string, string> = {}

  if (typeof values.amount === 'string') {
    const amount = toCollateral(values.amount)
    if (values.faucet === true) {
      results.faucet = await fundFromFaucet(clients, desk, amount)
      if (values.json !== true) {
        out(`minted  ${fmtCollateral(amount)} into the desk`)
        out(`tx      ${explorerTx(results.faucet)}`)
      }
    } else {
      const { hash, approvalHash } = await deposit(clients, desk, amount)
      results.approve = approvalHash
      results.deposit = hash
      if (values.json !== true) {
        out(`deposit ${fmtCollateral(amount)} from ${clients.walletClient.account.address}`)
        out(`tx      ${explorerTx(hash)}`)
      }
    }
  }

  if (typeof values.gas === 'string') {
    const wei = parseEther(values.gas)
    results.gasCredit = await topUpGasCredit(clients, desk, wei)
    if (values.json !== true) {
      out(`credit  ${fmtStt(wei)} to the router for this desk`)
      out(`tx      ${explorerTx(results.gasCredit)}`)
    }
  }

  if (Object.keys(results).length === 0) {
    throw new UsageError('nothing to do — pass --amount <tUSDC> and/or --gas <STT>')
  }
  if (values.json === true) printJson({ desk, ...results })
}

async function cmdDeskStatus(values: Values, positional: string | undefined): Promise<void> {
  const client = publicClient(values)
  const desk = await resolveDesk(client, positional, values)
  const snapshot = await readDesk(client, desk)

  if (values.json === true) {
    printJson(snapshot)
    return
  }
  printDesk(snapshot)
}

function printDesk(snapshot: DeskSnapshot): void {
  out(`Desk ${snapshot.address}`)
  out(`Owner           ${snapshot.owner}`)
  out(`Equity          ${fmtCollateral(snapshot.equity)}`)
  out(`Free collateral ${fmtCollateral(snapshot.collateralBalance)}`)
  out(`Open notional   ${fmtCollateral(snapshot.openNotional)}`)
  out(`Spent today     ${fmtCollateral(snapshot.state.spentToday)}`)
  out(`High-water mark ${fmtCollateral(snapshot.state.highWaterMark)}`)
  out(`Open markets    ${snapshot.state.openMarkets}`)
  out(`Loss streak     ${snapshot.state.consecutiveLosses}`)
  out(`Gas credit      ${fmtStt(snapshot.gasCredit)}`)
  out(
    `Armed at router ${snapshot.armedAtRouter ? 'yes' : 'no'}${
      snapshot.armedAtRouter === snapshot.policy.armed
        ? ''
        : ' — DISAGREES with the desk flag; run `lucid desk arm` to reconcile'
    }`,
  )
  out('')
  for (const line of describePolicy(snapshot.policy)) out(line)
  out('')
  out(explorerAddress(snapshot.address))
}

async function cmdMarkets(values: Values): Promise<void> {
  const assets = listOption(values, 'assets')
  const cadences = listOption(values, 'cadences')?.map(Number)
  const limit = intOption(values, 'limit', values.settled === true ? 20 : 50)

  const markets =
    values.settled === true
      ? await settledMarkets({ limit, ...(assets ? { assets } : {}) })
      : await liveMarkets({
          limit,
          minSecondsLeft: intOption(values, 'min-seconds-left', MIN_WINDOW_SLACK_SECONDS),
          ...(assets ? { assets } : {}),
          ...(cadences ? { cadences } : {}),
        })

  if (values.json === true) {
    printJson(markets)
    return
  }
  if (markets.length === 0) {
    out(values.settled === true ? 'no settled markets' : 'no live windows meet the slack requirement')
    return
  }

  const now = Math.floor(Date.now() / 1000)
  if (values.settled === true) {
    out('asset  window   settled at            winner  market')
    for (const m of markets) out(settledRow(m))
    return
  }
  out('asset  window   left     book   market')
  for (const m of markets) out(liveRow(m, now))
  out('')
  out(`${markets.length} window${markets.length === 1 ? '' : 's'} a desk could still enter.`)
}

function liveRow(market: Market, now: number): string {
  const left = secondsLeft(market, now)
  const book = market.lastPrice === null ? '   —  ' : (Number(market.lastPrice) / 1e6).toFixed(3)
  return `${market.asset.padEnd(6)} ${`${market.intervalSec}s`.padEnd(8)} ${`${left}s`.padEnd(
    8,
  )} ${book.padEnd(6)} ${market.marketId}`
}

function settledRow(market: Market): string {
  const when =
    market.resolvedAtTimestamp === null
      ? 'unknown'
      : new Date(market.resolvedAtTimestamp * 1000).toISOString().replace('.000Z', 'Z')
  return `${market.asset.padEnd(6)} ${`${market.intervalSec}s`.padEnd(8)} ${when.padEnd(
    21,
  )} ${winnerLabel(market).padEnd(7)} ${market.marketId}`
}

async function cmdWatch(values: Values, positional: string | undefined): Promise<void> {
  const client = publicClient(values)
  const desk = await resolveDesk(client, positional, values)

  out(`watching ${desk} — Ctrl-C to stop`)
  out('')

  const stop = watchDesk(
    desk,
    (event) => {
      const stamp = new Date().toISOString().slice(11, 19)
      if (values.json === true) {
        printJson(event)
      } else {
        out(`${stamp}  ${formatEvent(event)}`)
      }
    },
    {
      publicClient: client,
      includeRouter: values['no-router'] !== true,
      onError: (error) => process.stderr.write(`watch error: ${error.message}\n`),
    },
  )

  // The stream is the whole command, so it owns the process until a person stops it. Nothing
  // here survives the terminal closing, which is the point: Lucid's keeper is the chain's.
  await new Promise<void>((resolve) => {
    process.on('SIGINT', () => {
      stop()
      out('')
      out('stopped')
      resolve()
    })
  })
}

async function cmdSubs(values: Values, positional: string | undefined): Promise<void> {
  const owner = requireAddress(positional ?? addresses.router, 'address')
  const subs = await getOwnedSubscriptions(owner, { ...(values.rpc ? { rpcUrl: values.rpc } : {}) })

  if (values.json === true) {
    printJson(subs)
    return
  }
  out(`${owner} owns ${subs.length} subscription${subs.length === 1 ? '' : 's'}`)
  out('')
  for (const sub of subs) {
    out(`#${sub.id}`)
    out(`  ${describeSubscription(sub)}`)
    out(`  emitter  ${sub.emitter}`)
    out(`  handler  ${sub.handlerContract} ${sub.handlerSelector}`)
    out(`  gas      ${sub.gasLimit} ${hasSafeGasLimit(sub) ? '' : '(BELOW THE 5M FLOOR)'}`)
    out(`  fees     priority ${sub.priorityFeePerGas} / max ${sub.maxFeePerGas} wei per gas`)
    out('')
  }
  if (subs.length === 0) {
    out('Nothing is listening for this address. On Lucid that means no market can wake the router.')
  }
}

// -- wiring -----------------------------------------------------------------

function publicClient(values: Values): LucidPublicClient {
  return createLucidPublicClient(values.rpc !== undefined ? { rpcUrl: values.rpc } : {})
}

function writeClients(values: Values): LucidClients {
  return clientsFromEnv(values.rpc !== undefined ? { rpcUrl: values.rpc } : {})
}

async function runDesk(values: Values, positionals: readonly string[]): Promise<void> {
  const [sub, target] = positionals
  switch (sub) {
    case 'create':
      return cmdDeskCreate(values)
    case 'policy':
      return cmdDeskPolicy(values, target)
    case 'arm':
      return cmdDeskArm(values, target)
    case 'fund':
      return cmdDeskFund(values, target)
    case 'status':
    case undefined:
      return cmdDeskStatus(values, target)
    default:
      throw new UsageError(`unknown desk subcommand: ${sub}`)
  }
}

export async function main(argv: readonly string[]): Promise<number> {
  let parsed
  try {
    parsed = parseArgs({ args: [...argv], options: OPTIONS, allowPositionals: true })
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    return 2
  }
  const { values, positionals } = parsed
  const [command, ...rest] = positionals

  if (values.help === true || command === undefined || command === 'help') {
    out(HELP)
    return command === undefined && values.help !== true ? 1 : 0
  }

  try {
    switch (command) {
      case 'status':
        await cmdStatus(values)
        break
      case 'desk':
        await runDesk(values, rest)
        break
      case 'markets':
        await cmdMarkets(values)
        break
      case 'watch':
        await cmdWatch(values, rest[0])
        break
      case 'subs':
        await cmdSubs(values, rest[0])
        break
      default:
        throw new UsageError(`unknown command: ${command}`)
    }
    return 0
  } catch (error) {
    if (error instanceof UsageError) {
      process.stderr.write(`${error.message}\n\nRun \`lucid --help\`.\n`)
      return 2
    }
    if (error instanceof MissingKeyError) {
      process.stderr.write(`${error.message}\n`)
      return 3
    }
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    return 1
  }
}

// Run only when this file *is* the program, so tests can import `main` without launching a CLI.
const entry = process.argv[1]
if (entry !== undefined && import.meta.url === pathToFileURL(entry).href) {
  process.exitCode = await main(process.argv.slice(2))
}
