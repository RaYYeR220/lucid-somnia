import type { Address } from 'viem'
import { routerAbi } from './abis.js'
import { SUBSCRIPTION_OWNER_MINIMUM_BALANCE, addresses } from './addresses.js'
import type { LucidPublicClient } from './client.js'
import { readDesk } from './desk.js'
import type { DeskSnapshot } from './desk.js'
import { getOwnedSubscriptions } from './subscriptions.js'
import type { SubscriptionInfo } from './subscriptions.js'

export interface ProtocolStatus {
  router: Address
  /** STT the router holds. Everything below depends on this number. */
  routerBalance: bigint
  /**
   * The precompile checks the *subscribing contract's* balance on every renewal, so a router
   * that drops under 32 SOMI does not fail loudly — its subscriptions are removed and the whole
   * protocol goes quiet. This flag is the single most important line in `lucid status`.
   */
  aboveSubscriptionFloor: boolean
  /** How far the router is above (positive) or below (negative) the floor. */
  floorMargin: bigint
  /** STT the router has earmarked for desks, which is not free to pay for subscriptions. */
  totalGasCredit: bigint
  subscriptions: SubscriptionInfo[]
  armedDesks: Address[]
  venueSubscriptionId: bigint
  venueModule: Address
  brain: Address
  factory: Address
}

/** One round trip's worth of "is the protocol actually alive right now". */
export async function readProtocolStatus(
  publicClient: LucidPublicClient,
): Promise<ProtocolStatus> {
  const router = addresses.router
  const [routerBalance, totalGasCredit, armed, venueSubscriptionId, venueModule, brain, factory] =
    await Promise.all([
      publicClient.getBalance({ address: router }),
      publicClient.readContract({ address: router, abi: routerAbi, functionName: 'totalGasCredit' }),
      publicClient.readContract({ address: router, abi: routerAbi, functionName: 'armedDesks' }),
      publicClient.readContract({
        address: router,
        abi: routerAbi,
        functionName: 'venueSubscriptionId',
      }),
      publicClient.readContract({ address: router, abi: routerAbi, functionName: 'venueModule' }),
      publicClient.readContract({ address: router, abi: routerAbi, functionName: 'brain' }),
      publicClient.readContract({ address: router, abi: routerAbi, functionName: 'factory' }),
    ])

  const subscriptions = await getOwnedSubscriptions(router)

  return {
    router,
    routerBalance,
    aboveSubscriptionFloor: routerBalance >= SUBSCRIPTION_OWNER_MINIMUM_BALANCE,
    floorMargin: routerBalance - SUBSCRIPTION_OWNER_MINIMUM_BALANCE,
    totalGasCredit,
    subscriptions,
    armedDesks: [...armed],
    venueSubscriptionId,
    venueModule,
    brain,
    factory,
  }
}

/** Snapshots of every desk the router will currently fan out to. */
export async function readArmedDesks(
  publicClient: LucidPublicClient,
  desks: readonly Address[],
): Promise<DeskSnapshot[]> {
  return Promise.all(desks.map((desk) => readDesk(publicClient, desk)))
}
