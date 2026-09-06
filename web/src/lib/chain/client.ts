import { createPublicClient, http, rpcSchema } from 'viem'
import type { Address, Hex } from 'viem'
import { RPC_URL, shannon } from './config'

/**
 * The node's JSON shape for a reactivity subscription: snake_case keys, every number a hex
 * quantity. This type is the boundary where that stops being true.
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

/**
 * One read-only client for the whole app, created once.
 *
 * There is no wallet client anywhere in this project and no write path of any kind: Lucid's
 * front end reads the chain and nothing else, which is the only way it can honestly claim there
 * is no server behind it.
 */
export const publicClient = createPublicClient({
  chain: shannon,
  transport: http(RPC_URL, { batch: { wait: 12 }, retryCount: 2 }),
  rpcSchema: rpcSchema<ReactivityRpcSchema>(),
})

export type LucidPublicClient = typeof publicClient
