import { parseEventLogs } from 'viem'
import type { Address, Hex } from 'viem'
import { collateralAbi, deskAbi, factoryAbi, routerAbi } from './abis.js'
import { COLLATERAL, addresses } from './addresses.js'
import type { LucidClients, LucidPublicClient } from './client.js'
import type { Policy } from './policy.js'

/** The Shannon faucet caps one call at 10 000 tUSDC. Asking for more reverts the whole call. */
export const FAUCET_MAX_PER_CALL = 10_000_000_000n

export class DeskError extends Error {
  override readonly name = 'DeskError'
}

/** `LucidTypes.DeskState` — the risk accounting the desk enforces its mandate against. */
export interface DeskState {
  /** UTC day index the spend counter belongs to. A stale key means the budget rolls on next use. */
  dayKey: bigint
  spentToday: bigint
  highWaterMark: bigint
  openMarkets: number
  consecutiveLosses: number
}

export interface DeskSnapshot {
  address: Address
  owner: Address
  policy: Policy
  state: DeskState
  /** Free collateral plus everything committed to open windows, at cost. */
  equity: bigint
  /** tUSDC actually sitting in the desk right now. */
  collateralBalance: bigint
  /** Notional committed to windows that have not settled. */
  openNotional: bigint
  /**
   * Whether the *router* has this desk in its fan-out list. This is the flag that decides
   * whether the desk ever hears about a market, and it can disagree with `policy.armed`:
   * the factory sets the opening policy before it registers the clone, so a freshly created
   * desk can look armed to itself and be invisible to the chain until `arm(true)` lands.
   */
  armedAtRouter: boolean
  /** STT the router holds on this desk's behalf to pay for handler firings and AI verdicts. */
  gasCredit: bigint
}

async function confirm(clients: LucidClients, hash: Hex): Promise<Hex> {
  const receipt = await clients.publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new DeskError(`transaction ${hash} reverted`)
  return hash
}

/**
 * Deploys the caller's desk and hands back its address.
 *
 * One desk per address, enforced by the factory: a second call reverts `DeskExists`. The opening
 * policy is applied inside the same transaction, so the desk is never briefly live with no
 * mandate at all.
 */
export async function createDesk(
  clients: LucidClients,
  policy: Policy,
): Promise<{ hash: Hex; desk: Address }> {
  const { request, result } = await clients.publicClient.simulateContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: 'createDesk',
    args: [policy],
    account: clients.walletClient.account,
  })
  const hash = await clients.walletClient.writeContract(request)
  const receipt = await clients.publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new DeskError(`createDesk reverted (${hash})`)

  // Prefer the log over the simulated return value: the log is what actually happened.
  const [event] = parseEventLogs({ abi: factoryAbi, eventName: 'DeskCreated', logs: receipt.logs })
  return { hash, desk: event?.args.desk ?? result }
}

/** The desk owned by `owner`, or `undefined` when they have none. */
export async function deskOf(
  publicClient: LucidPublicClient,
  owner: Address,
): Promise<Address | undefined> {
  const desk = await publicClient.readContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: 'deskOf',
    args: [owner],
  })
  return desk === '0x0000000000000000000000000000000000000000' ? undefined : desk
}

/** Replaces the whole mandate. Also syncs the armed flag to the router, best-effort. */
export async function setPolicy(
  clients: LucidClients,
  desk: Address,
  policy: Policy,
): Promise<Hex> {
  const { request } = await clients.publicClient.simulateContract({
    address: desk,
    abi: deskAbi,
    functionName: 'setPolicy',
    args: [policy],
    account: clients.walletClient.account,
  })
  return confirm(clients, await clients.walletClient.writeContract(request))
}

/**
 * Turns the desk on or off. Unlike `setPolicy` this path is not best-effort: if the router call
 * fails the whole transaction reverts, because a desk that believes it is armed while the router
 * has never heard of it is funded, configured, and silently dead.
 */
export async function arm(clients: LucidClients, desk: Address, on: boolean): Promise<Hex> {
  const { request } = await clients.publicClient.simulateContract({
    address: desk,
    abi: deskAbi,
    functionName: 'arm',
    args: [on],
    account: clients.walletClient.account,
  })
  return confirm(clients, await clients.walletClient.writeContract(request))
}

/**
 * Moves collateral from the owner into the desk. Returns both hashes: the ERC-20 approval and
 * the deposit itself.
 */
export async function deposit(
  clients: LucidClients,
  desk: Address,
  amount: bigint,
): Promise<{ hash: Hex; approvalHash: Hex }> {
  const owner = clients.walletClient.account.address
  const balance = await clients.publicClient.readContract({
    address: COLLATERAL,
    abi: collateralAbi,
    functionName: 'balanceOf',
    args: [owner],
  })
  if (balance < amount) {
    throw new DeskError(`owner holds ${balance} collateral units, needs ${amount}`)
  }

  // The approval is issued every time rather than read first: the venue's ERC-20 surface exposes
  // no `allowance`, and on a testnet token one extra cheap transaction is a better trade than a
  // whole class of "approved once, then raised the deposit" failures.
  const approve = await clients.publicClient.simulateContract({
    address: COLLATERAL,
    abi: collateralAbi,
    functionName: 'approve',
    args: [desk, amount],
    account: clients.walletClient.account,
  })
  const approvalHash = await confirm(
    clients,
    await clients.walletClient.writeContract(approve.request),
  )

  const { request } = await clients.publicClient.simulateContract({
    address: desk,
    abi: deskAbi,
    functionName: 'deposit',
    args: [amount],
    account: clients.walletClient.account,
  })
  const hash = await confirm(clients, await clients.walletClient.writeContract(request))
  return { hash, approvalHash }
}

/** Sends collateral back to the owner. Nothing else in the desk can pay anyone. */
export async function withdraw(
  clients: LucidClients,
  desk: Address,
  amount: bigint,
): Promise<Hex> {
  const { request } = await clients.publicClient.simulateContract({
    address: desk,
    abi: deskAbi,
    functionName: 'withdraw',
    args: [amount],
    account: clients.walletClient.account,
  })
  return confirm(clients, await clients.walletClient.writeContract(request))
}

/**
 * Mints testnet collateral straight into the desk. The faucet is callable by contracts, which is
 * what lets a desk fund itself with no EOA anywhere in the path.
 */
export async function fundFromFaucet(
  clients: LucidClients,
  desk: Address,
  amount: bigint,
): Promise<Hex> {
  if (amount > FAUCET_MAX_PER_CALL) {
    throw new DeskError(
      `faucet caps one call at ${FAUCET_MAX_PER_CALL} units (10 000 tUSDC), asked for ${amount}`,
    )
  }
  const { request } = await clients.publicClient.simulateContract({
    address: desk,
    abi: deskAbi,
    functionName: 'fundFromFaucet',
    args: [amount],
    account: clients.walletClient.account,
  })
  return confirm(clients, await clients.walletClient.writeContract(request))
}

/**
 * Credits the router with STT for this desk's share of handler gas and committee deposits.
 *
 * The credit is held by the router, not the desk, because the router is the contract the
 * precompile bills. A desk with no credit is skipped with `Skipped(NO_CREDIT)` rather than
 * quietly dropped.
 */
export async function topUpGasCredit(
  clients: LucidClients,
  desk: Address,
  value: bigint,
): Promise<Hex> {
  const { request } = await clients.publicClient.simulateContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: 'topUp',
    args: [desk],
    value,
    account: clients.walletClient.account,
  })
  return confirm(clients, await clients.walletClient.writeContract(request))
}

/**
 * Everything worth knowing about a desk, read in parallel.
 *
 * Shannon has no Multicall3 at the canonical address, so these are eight concurrent `eth_call`s
 * rather than one aggregate. They are not atomic: a desk that settles a window mid-read could
 * report equity from before it and state from after. That is fine for a status view and wrong
 * for accounting, so do not use this snapshot as a ledger.
 */
export async function readDesk(
  publicClient: LucidPublicClient,
  desk: Address,
): Promise<DeskSnapshot> {
  const [owner, policy, state, equity, openNotional, collateralBalance, armedAtRouter, gasCredit] =
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
        address: addresses.router,
        abi: routerAbi,
        functionName: 'deskArmed',
        args: [desk],
      }),
      publicClient.readContract({
        address: addresses.router,
        abi: routerAbi,
        functionName: 'gasCreditOf',
        args: [desk],
      }),
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
  }
}

/** Every desk the router will fan out to right now. */
export async function armedDesks(publicClient: LucidPublicClient): Promise<readonly Address[]> {
  return publicClient.readContract({
    address: addresses.router,
    abi: routerAbi,
    functionName: 'armedDesks',
  })
}

/** Every desk the factory has ever created, armed or not. */
export async function allDesks(publicClient: LucidPublicClient): Promise<readonly Address[]> {
  return publicClient.readContract({
    address: addresses.factory,
    abi: factoryAbi,
    functionName: 'allDesks',
  })
}
