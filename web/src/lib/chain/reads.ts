import type { Abi, Address } from 'viem'
import { publicClient } from './client'
import {
  COLLATERAL,
  SUBSCRIPTION_FLOOR_WEI,
  deployed,
} from './config'
import {
  brainAbi,
  collateralAbi,
  deskAbi,
  factoryAbi,
  keeperAbi,
  relayAbi,
  routerAbi,
  seriesAbi,
} from './synced'
import type { DeskState, Policy } from '../protocol'

const ZERO = '0x0000000000000000000000000000000000000000'

/**
 * The parameterless view reads below widen their ABI to `Abi` before handing it to viem.
 *
 * viem infers a literal union of every function name in an ABI, and these ABIs are synced from
 * the contracts — the router's alone is over a hundred entries and grows with every feature.
 * Past a certain size that inference hits TypeScript's instantiation-depth limit and the build
 * stops. Widening costs the name check on these calls only; the return type is still asserted at
 * each call site, and every name is covered by the live smoke test in `npm run verify`.
 */

/* ============================================================================
   Desks
   ========================================================================== */

export interface DeskSnapshot {
  address: Address
  owner: Address
  policy: Policy
  state: DeskState
  /** Free collateral plus everything committed to open windows, at cost. */
  equity: bigint
  /** tUSDC sitting in the desk right now. */
  collateralBalance: bigint
  /** Cost committed to windows that have not settled. */
  openNotional: bigint
  /**
   * Whether the *router* has this desk in its fan-out list. This is the flag that decides whether
   * the desk ever hears about a window, and it can disagree with `policy.armed`.
   */
  armedAtRouter: boolean
  /** SOMI the router holds on this desk's behalf, to pay for firings and committee deposits. */
  gasCredit: bigint
  /** The name its owner published it under, or an empty string when it is not published. */
  publishedName: string
}

/**
 * Everything worth knowing about one desk, read in parallel.
 *
 * Shannon has no Multicall3 at the canonical address, so these are concurrent `eth_call`s rather
 * than one aggregate. They are not atomic: a desk that settles a window mid-read could report
 * equity from before it and state from after. Fine for a status view, wrong for accounting.
 */
export async function readDesk(desk: Address): Promise<DeskSnapshot> {
  const [owner, policy, state, equity, openNotional, collateralBalance, armedAtRouter, gasCredit, publishedName] =
    await Promise.all([
      publicClient.readContract({ address: desk, abi: deskAbi, functionName: 'owner' }),
      publicClient.readContract({ address: desk, abi: deskAbi, functionName: 'policy' }),
      publicClient.readContract({ address: desk, abi: deskAbi, functionName: 'state' }),
      publicClient.readContract({ address: desk, abi: deskAbi, functionName: 'equity' }),
      publicClient.readContract({ address: desk, abi: deskAbi, functionName: 'openNotional' }),
      publicClient.readContract({
        address: COLLATERAL,
        abi: collateralAbi,
        functionName: 'balanceOf',
        args: [desk],
      }),
      publicClient.readContract({
        address: deployed.router,
        abi: routerAbi,
        functionName: 'deskArmed',
        args: [desk],
      }),
      publicClient.readContract({
        address: deployed.router,
        abi: routerAbi,
        functionName: 'gasCreditOf',
        args: [desk],
      }),
      publicClient
        .readContract({
          address: deployed.factory,
          abi: factoryAbi,
          functionName: 'strategyName',
          args: [desk],
        })
        .catch(() => ''),
    ])

  return {
    address: desk,
    owner,
    policy: { ...policy },
    state: { ...state },
    equity,
    openNotional,
    collateralBalance,
    armedAtRouter,
    gasCredit,
    publishedName,
  }
}

/** Every desk the factory has ever created, in creation order. */
export async function readAllDesks(): Promise<readonly Address[]> {
  return publicClient.readContract({
    address: deployed.factory,
    abi: factoryAbi,
    functionName: 'allDesks',
  })
}

/** Every desk, with its full snapshot. One round trip per desk, run concurrently. */
export async function readDeskTable(): Promise<DeskSnapshot[]> {
  const desks = await readAllDesks()
  return Promise.all(desks.map((desk) => readDesk(desk)))
}

/** A desk's cost basis in one window. `open` is what makes it a position rather than a memory. */
export async function readHolding(desk: Address, marketId: `0x${string}`) {
  const [cost, open] = await publicClient.readContract({
    address: desk,
    abi: deskAbi,
    functionName: 'held',
    args: [marketId],
  })
  return { cost, open }
}

/* ============================================================================
   Router
   ========================================================================== */

export interface RouterStatus {
  address: Address
  /** SOMI the router holds. Everything below depends on this number. */
  balance: bigint
  aboveFloor: boolean
  /** How far above (positive) or below (negative) the 32 SOMI floor the router sits. */
  floorMargin: bigint
  /** SOMI earmarked for desks, which is not free to pay for subscriptions. */
  totalGasCredit: bigint
  venue: `0x${string}`
  venueModule: Address
  venueSubscriptionId: bigint
  brain: Address
  factory: Address
  keeper: Address
  relay: Address
  series: Address
  armedDesks: readonly Address[]
  handlerGasLimit: bigint
  maxFanout: bigint
}

export async function readRouterStatus(): Promise<RouterStatus> {
  const router = deployed.router
  const read = <T>(functionName: string) =>
    publicClient.readContract({ address: router, abi: routerAbi as Abi, functionName }) as Promise<T>

  const [
    balance,
    totalGasCredit,
    venue,
    venueModule,
    venueSubscriptionId,
    brain,
    factory,
    keeper,
    relay,
    series,
    armedDesks,
    handlerGasLimit,
    maxFanout,
  ] = await Promise.all([
    publicClient.getBalance({ address: router }),
    read<bigint>('totalGasCredit'),
    read<`0x${string}`>('venue'),
    read<Address>('venueModule'),
    read<bigint>('venueSubscriptionId'),
    read<Address>('brain'),
    read<Address>('factory'),
    read<Address>('keeper'),
    read<Address>('relay'),
    read<Address>('series'),
    read<readonly Address[]>('armedDesks'),
    read<bigint>('HANDLER_GAS_LIMIT'),
    read<bigint>('MAX_FANOUT'),
  ])

  return {
    address: router,
    balance,
    aboveFloor: balance >= SUBSCRIPTION_FLOOR_WEI,
    floorMargin: balance - SUBSCRIPTION_FLOOR_WEI,
    totalGasCredit,
    venue,
    venueModule,
    venueSubscriptionId,
    brain,
    factory,
    keeper,
    relay,
    series,
    armedDesks,
    handlerGasLimit,
    maxFanout,
  }
}

/** The desks positioned in one window. Deleted at settlement, so this is a live roster. */
export async function readInterestedIn(marketId: `0x${string}`): Promise<readonly Address[]> {
  return publicClient.readContract({
    address: deployed.router,
    abi: routerAbi,
    functionName: 'interestedIn',
    args: [marketId],
  })
}

/* ============================================================================
   Brain — the committee
   ========================================================================== */

export interface BrainStatus {
  address: Address
  balance: bigint
  /** What one full verdict costs the router: the price stage plus the inference stage. */
  quote: bigint
  quoteStage1: bigint
  quoteStage2: bigint
  committeeSize: number
  committeeThreshold: number
  feedCommitteeSize: number
  feedThreshold: number
  /** Seconds a window must have left before the brain will accept the question at all. */
  requiredSlack: bigint
  /** The brain's own measured round trip, in seconds. Zero until a stage has completed. */
  feedLatencyEma: bigint
  verdictLatencyEma: bigint
  systemPrompt: string
  agentId: bigint
  feedAgentId: bigint
  oracleAgentId: bigint
  maxFeedAgeMillis: bigint
  minSources: number
}

export async function readBrainStatus(): Promise<BrainStatus> {
  const brain = deployed.brain
  const read = <T>(functionName: string) =>
    publicClient.readContract({ address: brain, abi: brainAbi as Abi, functionName }) as Promise<T>

  const [
    balance,
    quote,
    quoteStage1,
    quoteStage2,
    committeeSize,
    committeeThreshold,
    feedCommitteeSize,
    feedThreshold,
    requiredSlack,
    feedLatencyEma,
    verdictLatencyEma,
    systemPrompt,
    agentId,
    feedAgentId,
    oracleAgentId,
    maxFeedAgeMillis,
    minSources,
  ] = await Promise.all([
    publicClient.getBalance({ address: brain }),
    read<bigint>('quote'),
    read<bigint>('quoteStage1'),
    read<bigint>('quoteStage2'),
    read<number>('committeeSize'),
    read<number>('committeeThreshold'),
    read<number>('feedCommitteeSize'),
    read<number>('feedThreshold'),
    read<bigint>('requiredSlack'),
    read<bigint>('feedLatencyEma'),
    read<bigint>('verdictLatencyEma'),
    read<string>('systemPrompt'),
    read<bigint>('AGENT_ID'),
    read<bigint>('feedAgentId'),
    read<bigint>('oracleAgentId'),
    read<bigint>('maxFeedAgeMillis'),
    read<number>('minSources'),
  ])

  return {
    address: brain,
    balance,
    quote,
    quoteStage1,
    quoteStage2,
    committeeSize,
    committeeThreshold,
    feedCommitteeSize,
    feedThreshold,
    requiredSlack,
    feedLatencyEma,
    verdictLatencyEma,
    systemPrompt,
    agentId,
    feedAgentId,
    oracleAgentId,
    maxFeedAgeMillis,
    minSources,
  }
}

/** The stored verdict for one window, or `undefined` when nothing was ever stored. */
export async function readVerdict(marketId: `0x${string}`) {
  const verdict = await publicClient.readContract({
    address: deployed.brain,
    abi: brainAbi,
    functionName: 'verdictOf',
    args: [marketId],
  })
  return { ...verdict }
}

/* ============================================================================
   Keeper, relay, series
   ========================================================================== */

export interface KeeperStatus {
  address: Address
  /** Whether the router will actually call it. Zero on the router means it is not attached. */
  attachedAtRouter: boolean
  routerOnKeeper: Address
  finalized: bigint
  released: bigint
  synced: bigint
  poked: bigint
  voided: bigint
  failures: bigint
}

export async function readKeeperStatus(routerKeeper: Address): Promise<KeeperStatus> {
  const keeper = deployed.keeper
  const [counts, routerOnKeeper] = await Promise.all([
    publicClient.readContract({ address: keeper, abi: keeperAbi, functionName: 'counts' }),
    publicClient.readContract({ address: keeper, abi: keeperAbi, functionName: 'router' }),
  ])
  const [finalized, released, synced, poked, voided, failures] = counts
  return {
    address: keeper,
    attachedAtRouter: routerKeeper.toLowerCase() === keeper.toLowerCase(),
    routerOnKeeper,
    finalized,
    released,
    synced,
    poked,
    voided,
    failures,
  }
}

export interface RelayStatus {
  address: Address
  relayed: bigint
  failed: bigint
  maxPending: bigint
  attachedAtRouter: boolean
}

export async function readRelayStatus(routerRelay: Address): Promise<RelayStatus> {
  const relay = deployed.relay
  const read = <T>(functionName: string) =>
    publicClient.readContract({ address: relay, abi: relayAbi as Abi, functionName }) as Promise<T>
  const [relayed, failed, maxPending] = await Promise.all([
    read<bigint>('relayedCount'),
    read<bigint>('failedCount'),
    read<bigint>('MAX_PENDING'),
  ])
  return {
    address: relay,
    relayed,
    failed,
    maxPending,
    attachedAtRouter: routerRelay.toLowerCase() === relay.toLowerCase(),
  }
}

export interface SeriesStatus {
  address: Address
  mode: number
  /** True while a market of the watched cadence has been seen recently enough. */
  venueHealthy: boolean
  lastVenueMarketAt: bigint
  lastRollAt: bigint
  rollsToday: number
  creatorFloat: bigint
  stalenessSeconds: number
  seriesId: number
  intervalSec: number
  maxRollsPerDay: bigint
  minCreatorFloat: bigint
  creator: Address
  attachedAtRouter: boolean
}

export async function readSeriesStatus(routerSeries: Address): Promise<SeriesStatus> {
  const series = deployed.series
  const read = <T>(functionName: string) =>
    publicClient.readContract({ address: series, abi: seriesAbi as Abi, functionName }) as Promise<T>

  const [status, stalenessSeconds, seriesId, intervalSec, maxRollsPerDay, minCreatorFloat, creator] =
    await Promise.all([
      read<readonly [number, boolean, bigint, bigint, number, bigint]>('status'),
      read<number>('stalenessSeconds'),
      read<number>('seriesId'),
      read<number>('intervalSec'),
      read<bigint>('maxRollsPerDay'),
      read<bigint>('minCreatorFloat'),
      read<Address>('creator'),
    ])

  const [mode, venueHealthy, lastVenueMarketAt, lastRollAt, rollsToday, creatorFloat] = status
  return {
    address: series,
    mode,
    venueHealthy,
    lastVenueMarketAt,
    lastRollAt,
    rollsToday,
    creatorFloat,
    stalenessSeconds,
    seriesId,
    intervalSec,
    maxRollsPerDay,
    minCreatorFloat,
    creator,
    attachedAtRouter: routerSeries.toLowerCase() === series.toLowerCase(),
  }
}

export function isZeroAddress(address: string): boolean {
  return address.toLowerCase() === ZERO
}
