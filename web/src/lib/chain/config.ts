import { defineChain } from 'viem'
import { deployed } from './synced'

export { deployed }

/** Somnia Shannon. Everything this app reads lives here. */
export const CHAIN_ID = 50312
export const RPC_URL = 'https://api.infra.testnet.somnia.network'
export const EXPLORER_URL = 'https://shannon-explorer.somnia.network'

/**
 * DreamDEX's public Hasura indexer. No auth and no REST alternative, so every off-chain market
 * read in this app goes through here — from the reader's browser, not from a server of ours.
 */
export const INDEXER_URL = 'https://dev.smk.somnia.host/v1/graphql'

/** Shannon's test collateral. Six decimals. */
export const COLLATERAL = '0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E' as const
export const COLLATERAL_SYMBOL = 'tUSDC'
export const COLLATERAL_DECIMALS = 6

/** `BinaryMarketsModule` — the contract whose `MarketCreated` log wakes the router. */
export const DREAMDEX_MODULE = '0x3ecC694Cef705358864a646142ac17A90E29e388' as const

/** DreamDEX's ERC-6909 outcome-token contract; a desk's real leg sizes live here. */
export const OUTCOME_TOKEN = '0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9' as const

/** Somnia's reactivity precompile, at a fixed address on every Somnia chain. */
export const REACTIVITY_PRECOMPILE = '0x0000000000000000000000000000000000000100' as const

/**
 * `subscribe` reverts unless the *calling contract* holds this much, and it is re-checked on
 * every renewal. A router that slips below it does not fail loudly — its subscriptions are
 * removed and the protocol goes quiet. This is the single most important number on /system.
 */
export const SUBSCRIPTION_FLOOR_WEI = 32n * 10n ** 18n

/** `LucidTypes.MIN_WINDOW_SLACK`. A window with less than this left is not worth touching. */
export const MIN_WINDOW_SLACK_SECONDS = 90

/**
 * `LucidTypes.BOOK_UNOBSERVED = type(uint16).max`. It is an `internal` constant with no getter,
 * so the value is written here once and compared everywhere, never re-derived.
 *
 * A probability is a number in 0..10000. This sentinel sits outside that range on purpose: an
 * empty book is the absence of a market price, not a market price of 50 %, and rendering it as
 * one would put a number nobody quoted next to numbers somebody did.
 */
export const BOOK_UNOBSERVED = 65535

/** `LucidTypes.BPS`. */
export const BPS = 10_000

/**
 * `eth_getLogs` is capped at 1 000 blocks per query on Shannon and blocks land in ~100 ms, so
 * history is read by paging backwards in windows this wide. Never issue an unbounded range.
 */
export const LOG_PAGE_SIZE = 950n

export const shannon = defineChain({
  id: CHAIN_ID,
  name: 'Somnia Shannon',
  nativeCurrency: { name: 'Somnia', symbol: 'STT', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: 'Shannon Explorer', url: EXPLORER_URL } },
  testnet: true,
})

export function explorerAddress(address: string): string {
  return `${EXPLORER_URL}/address/${address}`
}

export function explorerTx(hash: string): string {
  return `${EXPLORER_URL}/tx/${hash}`
}

export function explorerBlock(block: bigint | number): string {
  return `${EXPLORER_URL}/block/${block.toString()}`
}
