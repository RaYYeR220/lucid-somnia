import { defineChain } from 'viem'
import { deployed } from './deployed.js'

export { deployed }

/** Somnia Shannon testnet. */
export const CHAIN_ID = 50312

export const RPC_URL = 'https://api.infra.testnet.somnia.network'
export const WS_URL = 'wss://api.infra.testnet.somnia.network/ws'
export const EXPLORER_URL = 'https://shannon-explorer.somnia.network'

/**
 * DreamDEX's public Hasura indexer. No auth, no rate limit, and no REST alternative:
 * `api.dreamdex.io` covers spot only, so every off-chain market read goes through here.
 */
export const INDEXER_URL = 'https://dev.smk.somnia.host/v1/graphql'

/** Shannon's test collateral. Six decimals, and its `faucet(uint256)` is callable by anyone. */
export const COLLATERAL = '0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E' as const
export const COLLATERAL_SYMBOL = 'tUSDC'
export const COLLATERAL_DECIMALS = 6

/** BinaryMarketsModule — the contract whose `MarketCreated` log wakes the router. */
export const DREAMDEX_MODULE = '0x3ecC694Cef705358864a646142ac17A90E29e388' as const

/** Somnia's reactivity precompile, at a fixed address on every Somnia chain. */
export const REACTIVITY_PRECOMPILE = '0x0000000000000000000000000000000000000100' as const

/**
 * `subscribe` reverts unless the *calling contract* holds this much. That single rule is why
 * Lucid has one router owning every subscription instead of a subscription per desk, and why
 * the router's balance dropping below it silently disarms the whole protocol.
 */
export const SUBSCRIPTION_OWNER_MINIMUM_BALANCE = 32n * 10n ** 18n

/**
 * A market with less than this left is not worth touching: the indexer lags behind the chain,
 * and `placeBinaryOrder` on a stale row reverts `OrderAlreadyExpired`. Mirrors
 * `LucidTypes.MIN_WINDOW_SLACK`.
 */
export const MIN_WINDOW_SLACK_SECONDS = 90

export const shannon = defineChain({
  id: CHAIN_ID,
  name: 'Somnia Shannon',
  nativeCurrency: { name: 'Somnia', symbol: 'STT', decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URL], webSocket: [WS_URL] },
  },
  blockExplorers: {
    default: { name: 'Shannon Explorer', url: EXPLORER_URL },
  },
  testnet: true,
})

/** Every Lucid address on Shannon, plus the venue pieces they talk to. */
export const addresses = {
  router: deployed.router,
  factory: deployed.factory,
  brain: deployed.brain,
  keeper: deployed.keeper,
  relay: deployed.relay,
  deskImplementation: deployed.deskImplementation,
  collateral: COLLATERAL,
  dreamdexModule: DREAMDEX_MODULE,
  reactivityPrecompile: REACTIVITY_PRECOMPILE,
} as const

export type LucidContractName = keyof typeof addresses

/** Explorer link for an address, so CLI output is clickable rather than merely correct. */
export function explorerAddress(address: string): string {
  return `${EXPLORER_URL}/address/${address}`
}

/** Explorer link for a transaction hash. */
export function explorerTx(hash: string): string {
  return `${EXPLORER_URL}/tx/${hash}`
}
