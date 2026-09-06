import { createPublicClient, http, rpcSchema, toEventSelector, toFunctionSelector } from 'viem'
import type { Address, Hex } from 'viem'
import { DREAMDEX_MODULE, RPC_URL, shannon } from './addresses.js'
import type { ClientOptions } from './client.js'

/** Zero is the precompile's wildcard: no filter on that field. */
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const ZERO_TOPIC = `0x${'0'.repeat(64)}`

/** `BinaryMarketsModule.MarketCreated` — the log that wakes the Lucid router. */
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
 * The node's JSON shape for a subscription. Field names are snake_case and every number is a
 * hex quantity — this interface is the boundary where that stops being true.
 */
export interface RawSubscriptionInfo {
  id: Hex
  topics: readonly Hex[]
  origin: Address
  caller: Address
  emitter: Address
  owner: Address
  handler_contract_address: Address
  handler_function_selector: Hex
  gas_limit: Hex
  priority_fee_per_gas: Hex
  max_fee_per_gas: Hex
}

/**
 * Somnia's reactivity RPC namespace. Declaring it as an rpc schema keeps these two custom methods
 * as type-checked as `eth_call` — there is no `any` anywhere in this path.
 */
type ReactivityRpcSchema = [
  {
    Method: 'somnia_reactivityGetSubscriptions'
    Parameters: [owner: Address]
    ReturnType: readonly Hex[]
  },
  {
    Method: 'somnia_reactivityGetSubscriptionInfo'
    Parameters: [subscriptionId: Hex]
    ReturnType: readonly RawSubscriptionInfo[]
  },
]

/** One live reactivity subscription, in the types the rest of the kit uses. */
export interface SubscriptionInfo {
  id: bigint
  /** Four topic filters. A zero entry is a wildcard, not a match against zero. */
  topics: readonly Hex[]
  /** `tx.origin` filter, or the zero address for any origin. */
  origin: Address
  /** Reserved by the precompile; always zero today. */
  caller: Address
  /** Contract whose logs are watched, or the zero address for any contract. */
  emitter: Address
  /** Who pays for every firing, and the only address that can cancel it. */
  owner: Address
  /** Contract the synthetic transaction calls. */
  handlerContract: Address
  handlerSelector: Hex
  /** Gas provisioned per firing. Below ~5 M the handler is charged and never runs. */
  gasLimit: bigint
  priorityFeePerGas: bigint
  maxFeePerGas: bigint
}

function reactivityClient(options: ClientOptions = {}) {
  return createPublicClient({
    chain: shannon,
    transport: http(options.rpcUrl ?? RPC_URL),
    rpcSchema: rpcSchema<ReactivityRpcSchema>(),
  })
}

/** Normalises the node's snake_case, hex-quantity payload. Exported so it can be tested offline. */
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

/**
 * Every subscription id owned by an address.
 *
 * Read-only on purpose. Creating and cancelling subscriptions is a contract's job — the
 * precompile bills the *calling contract* and demands it hold 32 SOMI, so an EOA holding this
 * kit could not create one even if the kit offered to.
 */
export async function getSubscriptions(
  owner: Address,
  options: ClientOptions = {},
): Promise<bigint[]> {
  const ids = await reactivityClient(options).request({
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
 * to a caller: nothing is listening.
 */
export async function getSubscriptionInfo(
  id: bigint | number | Hex,
  options: ClientOptions = {},
): Promise<SubscriptionInfo | undefined> {
  const hexId = (typeof id === 'string' ? id : `0x${id.toString(16)}`) as Hex
  const rows = await reactivityClient(options).request({
    method: 'somnia_reactivityGetSubscriptionInfo',
    params: [hexId],
  })
  const [row] = rows
  return row === undefined ? undefined : parseSubscriptionInfo(row)
}

/** Every subscription an address owns, already decoded. Removed ids are dropped silently. */
export async function getOwnedSubscriptions(
  owner: Address,
  options: ClientOptions = {},
): Promise<SubscriptionInfo[]> {
  const ids = await getSubscriptions(owner, options)
  const infos = await Promise.all(ids.map((id) => getSubscriptionInfo(id, options)))
  return infos.filter((info): info is SubscriptionInfo => info !== undefined)
}

function isWildcard(topic: Hex | undefined): boolean {
  return topic === undefined || topic.toLowerCase() === ZERO_TOPIC
}

function shortAddress(address: string): string {
  return `${address.slice(0, 8)}…${address.slice(-4)}`
}

/**
 * What this subscription will actually do, in one line.
 *
 * A raw subscription is four opaque topics and a selector; the interesting part is the sentence
 * they add up to. Anything the kit cannot name is described structurally rather than guessed at
 * — a wrong label here would be worse than none.
 */
export function describeSubscription(info: SubscriptionInfo): string {
  const topic0 = info.topics[0]
  const target = `${shortAddress(info.handlerContract)}${
    info.handlerSelector.toLowerCase() === SELECTOR_ON_EVENT ? '.onEvent' : `[${info.handlerSelector}]`
  }`
  const gas = `${(Number(info.gasLimit) / 1_000_000).toFixed(1)}M gas`

  if (topic0 === undefined || isWildcard(topic0)) {
    const scope =
      info.emitter.toLowerCase() === ZERO_ADDRESS
        ? 'every log on the chain'
        : `every log from ${shortAddress(info.emitter)}`
    return `wildcard — calls ${target} on ${scope} (${gas})`
  }

  const t0 = topic0.toLowerCase()

  if (t0 === TOPIC_SCHEDULE.toLowerCase()) {
    const when = info.topics[1]
    if (when !== undefined && !isWildcard(when)) {
      // Schedule indexes its timestamp, so the second topic *is* the firing time, in millis.
      return `one-shot timer — calls ${target} at ${new Date(
        Number(BigInt(when)),
      ).toISOString()} (${gas})`
    }
    return `timer — calls ${target} on every scheduled tick (${gas})`
  }

  if (t0 === TOPIC_BLOCK_TICK.toLowerCase()) {
    return `block tick — calls ${target} at the end of every block (${gas})`
  }

  if (t0 === TOPIC_EPOCH_TICK.toLowerCase()) {
    return `epoch tick — calls ${target} at every epoch boundary (${gas})`
  }

  if (t0 === TOPIC_MARKET_CREATED.toLowerCase()) {
    const venue =
      info.emitter.toLowerCase() === DREAMDEX_MODULE.toLowerCase()
        ? 'DreamDEX'
        : shortAddress(info.emitter)
    return `market listener — calls ${target} in the same block as every new ${venue} market (${gas})`
  }

  const where =
    info.emitter.toLowerCase() === ZERO_ADDRESS
      ? 'any contract'
      : shortAddress(info.emitter)
  return `log listener — calls ${target} on topic ${topic0.slice(0, 10)}… from ${where} (${gas})`
}

/**
 * Below this the handler is billed for the full limit and never executes — no revert, no state
 * change, no log. Measured on Shannon: 2 M silently fails, 3 M and above works. The kit draws the
 * line at 5 M to leave headroom for a fan-out that grows.
 */
export const SAFE_HANDLER_GAS_FLOOR = 5_000_000n

/** True when the subscription is provisioned above the gas floor a handler needs to actually run. */
export function hasSafeGasLimit(info: SubscriptionInfo): boolean {
  return info.gasLimit >= SAFE_HANDLER_GAS_FLOOR
}
