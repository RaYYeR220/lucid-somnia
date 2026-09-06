import { createPublicClient, createWalletClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import type { Account, Hex, HttpTransport, PublicClient, WalletClient } from 'viem'
import { RPC_URL, shannon } from './addresses.js'

export interface ClientOptions {
  /** Override the default Shannon endpoint, e.g. to point at a local fork. */
  rpcUrl?: string
}

/**
 * A read-only client. Everything the kit can answer without a key goes through this: desk state,
 * router balance, subscriptions, event streams. Keeping reads and writes on separate clients is
 * what lets `lucid status` work with no `PRIVATE_KEY` in the environment at all.
 */
export function createLucidPublicClient(options: ClientOptions = {}): LucidPublicClient {
  return createPublicClient({
    chain: shannon,
    transport: http(options.rpcUrl ?? RPC_URL),
  })
}

// Annotated rather than inferred: viem's client types are too large for TypeScript to serialise
// into a .d.ts, and an inferred one leaks paths inside node_modules into the published types.
export type LucidPublicClient = PublicClient<HttpTransport, typeof shannon>

/** Signing client for the handful of calls that change state. */
export function createLucidWalletClient(
  account: Account,
  options: ClientOptions = {},
): LucidWalletClient {
  return createWalletClient({
    account,
    chain: shannon,
    transport: http(options.rpcUrl ?? RPC_URL),
  })
}

export type LucidWalletClient = WalletClient<HttpTransport, typeof shannon, Account>

/** The pair every write in this kit needs: one to simulate and confirm, one to sign. */
export interface LucidClients {
  publicClient: LucidPublicClient
  walletClient: LucidWalletClient
}

export class MissingKeyError extends Error {
  override readonly name = 'MissingKeyError'
  constructor(variable: string) {
    super(`${variable} is not set — this command signs a transaction and needs a key`)
  }
}

function normalizePrivateKey(key: string): Hex {
  const trimmed = key.trim()
  const hex = trimmed.startsWith('0x') ? trimmed : `0x${trimmed}`
  if (!/^0x[0-9a-fA-F]{64}$/.test(hex)) {
    throw new Error('private key must be 32 hex bytes, with or without a 0x prefix')
  }
  return hex as Hex
}

export function accountFromPrivateKey(key: string): Account {
  return privateKeyToAccount(normalizePrivateKey(key))
}

/**
 * Reads the signing key from the environment and nowhere else. The kit never takes a key on the
 * command line, where it would land in shell history and in every `ps` listing on the box.
 */
export function accountFromEnv(variable = 'PRIVATE_KEY'): Account {
  const raw = process.env[variable]
  if (raw === undefined || raw.trim() === '') throw new MissingKeyError(variable)
  return accountFromPrivateKey(raw)
}

/** Convenience for the write paths: build both clients from `PRIVATE_KEY`. */
export function clientsFromEnv(options: ClientOptions = {}): LucidClients {
  const account = accountFromEnv()
  return {
    publicClient: createLucidPublicClient(options),
    walletClient: createLucidWalletClient(account, options),
  }
}
