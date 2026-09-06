import { toEventSelector, toFunctionSelector } from 'viem'
import type { Address, Hex } from 'viem'
import { publicClient } from './client'
import type { RawSubscriptionInfo } from './client'
import { DREAMDEX_MODULE } from './config'

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const ZERO_TOPIC = `0x${'0'.repeat(64)}`

/** `BinaryMarketsModule.MarketCreated` — the log that wakes the router. */
export const TOPIC_MARKET_CREATED = toEventSelector(
  'MarketCreated(bytes32,address,address,uint256,uint32,bytes32,address,address,uint256,uint256,uint64,uint8,uint8,uint64,uint64,uint8,string,uint256,string,bytes)',
)

/** The precompile's own system events. A subscription on one of these is a timer, not a listener. */
export const TOPIC_SCHEDULE = toEventSelector('Schedule(uint256)')
export const TOPIC_BLOCK_TICK = toEventSelector('BlockTick(uint64)')
export const TOPIC_EPOCH_TICK = toEventSelector('EpochTick(uint64,uint64)')

/** The default handler entry point, `ISomniaEventHandler.onEvent`. */
export const SELECTOR_ON_EVENT = toFunctionSelector('onEvent(address,bytes32[],bytes)')

/**
 * Below this a handler is billed for the full limit and never executes — no revert, no state
 * change, no log. Measured on Shannon: 2 M silently fails, 3 M and above works.
 */
export const SAFE_HANDLER_GAS_FLOOR = 5_000_000n

export interface SubscriptionInfo {
  id: bigint
  /** Four topic filters. A zero entry is a wildcard, not a match against zero. */
  topics: readonly Hex[]
  origin: Address
  caller: Address
  /** The contract whose logs are watched, or the zero address for any contract. */
  emitter: Address
  /** Who pays for every firing, and the only address that can cancel it. */
  owner: Address
  handlerContract: Address
  handlerSelector: Hex
  gasLimit: bigint
  priorityFeePerGas: bigint
  maxFeePerGas: bigint
}

export function parseSubscriptionInfo(raw: RawSubscriptionInfo): SubscriptionInfo {
  return {
    id: BigInt(raw.id),
    topics: raw.topics,
    origin: raw.origin,
    caller: raw.caller,
    emitter: raw.emitter,
    owner: raw.owner,
    handlerContract: raw.handler_contract_address,
    handlerSelector: raw.handler_function_selector,
    gasLimit: BigInt(raw.gas_limit),
    priorityFeePerGas: BigInt(raw.priority_fee_per_gas),
    maxFeePerGas: BigInt(raw.max_fee_per_gas),
  }
}

/** Every subscription id an address owns. */
export async function getSubscriptionIds(owner: Address): Promise<bigint[]> {
  const ids = await publicClient.request({
    method: 'somnia_reactivityGetSubscriptions',
    params: [owner],
  })
  return ids.map((id) => BigInt(id))
}

/**
 * One subscription's configuration, or `undefined` if it has been removed.
 *
 * The node answers with an array — empty for an id that no longer exists. A cancelled
 * subscription and a never-created one are indistinguishable here, and both mean the same thing
 * to a reader: nothing is listening.
 */
export async function getSubscriptionInfo(id: bigint): Promise<SubscriptionInfo | undefined> {
  const rows = await publicClient.request({
    method: 'somnia_reactivityGetSubscriptionInfo',
    params: [`0x${id.toString(16)}` as Hex],
  })
  const row = rows[0]
  return row === undefined ? undefined : parseSubscriptionInfo(row)
}

/** Every subscription an address owns, already decoded. Removed ids are dropped silently. */
export async function getOwnedSubscriptions(owner: Address): Promise<SubscriptionInfo[]> {
  const ids = await getSubscriptionIds(owner)
  const infos = await Promise.all(ids.map((id) => getSubscriptionInfo(id)))
  return infos.filter((info): info is SubscriptionInfo => info !== undefined)
}

function isWildcard(topic: Hex | undefined): boolean {
  return topic === undefined || topic.toLowerCase() === ZERO_TOPIC
}

/** What kind of thing a subscription is, once its topics are read. */
export type SubscriptionKind = 'market-listener' | 'timer' | 'block-tick' | 'epoch-tick' | 'log-listener' | 'wildcard'

export interface DecodedSubscription extends SubscriptionInfo {
  kind: SubscriptionKind
  /** A short label, for a heading. */
  title: string
  /** What this subscription will actually do, in one sentence. */
  description: string
  /** When a one-shot timer will fire, in unix seconds. Absent for a listener. */
  firesAt?: number
  /** True when the handler is provisioned above the gas floor it needs to actually run. */
  safeGas: boolean
}

function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/**
 * A raw subscription is four opaque topics and a selector; the interesting part is the sentence
 * they add up to. Anything this build cannot name is described structurally rather than guessed
 * at — a wrong label here would be worse than none.
 */
export function decodeSubscription(info: SubscriptionInfo): DecodedSubscription {
  const safeGas = info.gasLimit >= SAFE_HANDLER_GAS_FLOOR
  const handler =
    info.handlerSelector.toLowerCase() === SELECTOR_ON_EVENT.toLowerCase()
      ? 'onEvent'
      : info.handlerSelector
  const target = `${shortAddress(info.handlerContract)}.${handler}`
  const topic0 = info.topics[0]

  if (isWildcard(topic0)) {
    const scope =
      info.emitter.toLowerCase() === ZERO_ADDRESS
        ? 'every log on the chain'
        : `every log from ${shortAddress(info.emitter)}`
    return {
      ...info,
      kind: 'wildcard',
      title: 'Wildcard listener',
      description: `Runs ${target} on ${scope}.`,
      safeGas,
    }
  }

  const t0 = topic0!.toLowerCase()

  if (t0 === TOPIC_SCHEDULE.toLowerCase()) {
    const when = info.topics[1]
    if (when !== undefined && !isWildcard(when)) {
      // `Schedule` indexes its timestamp, so the second topic *is* the firing time, in millis.
      const firesAt = Number(BigInt(when) / 1000n)
      return {
        ...info,
        kind: 'timer',
        title: 'One-shot timer',
        description: `Runs ${target} once, at the scheduled millisecond, then disappears.`,
        firesAt,
        safeGas,
      }
    }
    return {
      ...info,
      kind: 'timer',
      title: 'Timer',
      description: `Runs ${target} on every scheduled tick.`,
      safeGas,
    }
  }

  if (t0 === TOPIC_BLOCK_TICK.toLowerCase()) {
    return {
      ...info,
      kind: 'block-tick',
      title: 'Block tick',
      description: `Runs ${target} at the end of every block.`,
      safeGas,
    }
  }

  if (t0 === TOPIC_EPOCH_TICK.toLowerCase()) {
    return {
      ...info,
      kind: 'epoch-tick',
      title: 'Epoch tick',
      description: `Runs ${target} at every epoch boundary.`,
      safeGas,
    }
  }

  if (t0 === TOPIC_MARKET_CREATED.toLowerCase()) {
    const venue =
      info.emitter.toLowerCase() === DREAMDEX_MODULE.toLowerCase()
        ? 'DreamDEX'
        : shortAddress(info.emitter)
    return {
      ...info,
      kind: 'market-listener',
      title: 'Market listener',
      description: `Runs ${target} in the same block as every new ${venue} window. Nothing polls; validators execute the handler when the log lands.`,
      safeGas,
    }
  }

  const where =
    info.emitter.toLowerCase() === ZERO_ADDRESS ? 'any contract' : shortAddress(info.emitter)
  return {
    ...info,
    kind: 'log-listener',
    title: 'Log listener',
    description: `Runs ${target} on topic ${topic0!.slice(0, 10)}… from ${where}.`,
    safeGas,
  }
}
