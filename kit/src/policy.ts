import { formatUnits, keccak256, parseUnits, toHex } from 'viem'
import type { Hex } from 'viem'
import { COLLATERAL_DECIMALS, COLLATERAL_SYMBOL, MIN_WINDOW_SLACK_SECONDS } from './addresses.js'

/**
 * The mandate a desk owner sets once and the contract enforces forever.
 *
 * Field-for-field mirror of `LucidTypes.Policy`, in the shapes viem produces and consumes:
 * uint64 arrives as `bigint`, everything narrower as `number`. Amounts are raw collateral
 * units — tUSDC has six decimals, so 25 tUSDC is `25_000_000n`.
 */
export interface Policy {
  /** Hard ceiling on one window's notional. A veto, not a clamp: an oversized order is refused. */
  maxStakePerWindow: bigint
  /** Ceiling on everything spent in one UTC day. */
  dailyBudget: bigint
  maxOpenMarkets: number
  /** Equity may fall this far below the high-water mark before the desk halts itself. */
  maxDrawdownBps: number
  maxConsecutiveLosses: number
  /** How far the committee must disagree with the book before the trade is worth making. */
  minEdgeBps: number
  /** Bitmask over {@link ASSETS}. */
  allowedAssets: number
  /** Bitmask over {@link CADENCES}. */
  allowedCadences: number
  /** A {@link Strategy} value. Typed as the raw uint8 so a chain read needs no cast. */
  strategy: number
  armed: boolean
}

/** `LucidTypes.Strategy`, in declaration order. */
export const Strategy = {
  /** Take the book when the committee's probability is far enough from the book-implied one. */
  AiEdge: 0,
  /** Mint a complete set, then rest both legs POST_ONLY around the AI fair value. */
  Maker: 1,
} as const
export type Strategy = (typeof Strategy)[keyof typeof Strategy]

export type StrategyName = keyof typeof Strategy

/** Strategy names in declaration order, so a CLI can list them without hardcoding. */
export const STRATEGY_NAMES = Object.keys(Strategy) as StrategyName[]

/**
 * The assets `PolicyLib.assetBit` recognises, in bit order. Anything else the venue lists is
 * unreachable to a desk: the pre-filter maps an unknown asset key to bit 0 and refuses.
 */
export const ASSETS = ['BTC', 'ETH'] as const
export type AssetSymbol = (typeof ASSETS)[number]

/**
 * The window lengths `PolicyLib.cadenceBit` recognises, in bit order:
 * bit 0 = 60 s, bit 1 = 300 s, bit 2 = 900 s, bit 3 = 3600 s.
 */
export const CADENCES = [60, 300, 900, 3600] as const
export type Cadence = (typeof CADENCES)[number]

/**
 * A 60-second window can never clear the protocol's 90-second minimum slack, so a desk that
 * allows bit 0 will consider those markets and refuse every one of them with `WindowTooShort`.
 *
 * The bit is still accepted rather than rejected, for two reasons. The mask is a faithful mirror
 * of on-chain state, and silently dropping a bit here would make `decodePolicy(readPolicy())`
 * disagree with the chain. And the slack is a protocol constant that exists because the public
 * indexer lags — if it is ever lowered, existing policies should start trading 1-minute windows
 * without anyone having to re-sign a mandate.
 */
export const UNTRADEABLE_CADENCES: readonly Cadence[] = CADENCES.filter(
  (c) => c < MIN_WINDOW_SLACK_SECONDS,
)

/** A policy expressed the way a person writes one: symbols, seconds and decimal tUSDC. */
export interface PolicyDraft {
  /** Decimal tUSDC, e.g. `"25"`. */
  maxStakePerWindow: string
  /** Decimal tUSDC, e.g. `"100"`. */
  dailyBudget: string
  maxOpenMarkets: number
  maxDrawdownBps: number
  maxConsecutiveLosses: number
  minEdgeBps: number
  assets: AssetSymbol[]
  cadences: Cadence[]
  strategy: StrategyName
  armed: boolean
}

export class PolicyError extends Error {
  override readonly name = 'PolicyError'
}

/** `keccak256(bytes(symbol))`, the form the venue log carries and `PolicyLib` compares against. */
export function assetKey(symbol: string): Hex {
  return keccak256(toHex(symbol))
}

/** Bit value for one asset, or 0 when no desk can trade it. Mirrors `PolicyLib.assetBit`. */
export function assetBit(symbol: string): number {
  const index = (ASSETS as readonly string[]).indexOf(symbol)
  return index === -1 ? 0 : 1 << index
}

/** Bit value for one window length, or 0. Mirrors `PolicyLib.cadenceBit`. */
export function cadenceBit(intervalSec: number): number {
  const index = (CADENCES as readonly number[]).indexOf(intervalSec)
  return index === -1 ? 0 : 1 << index
}

/** `assetsMask(['BTC','ETH']) === 0b11`. Throws on an asset no desk could ever trade. */
export function assetsMask(symbols: readonly string[]): number {
  let mask = 0
  for (const symbol of symbols) {
    const bit = assetBit(symbol)
    if (bit === 0) {
      throw new PolicyError(`unknown asset ${JSON.stringify(symbol)}; expected one of ${ASSETS.join(', ')}`)
    }
    mask |= bit
  }
  return mask
}

/** `cadencesMask([300, 900]) === 0b110`. Throws on a window length the venue does not list. */
export function cadencesMask(intervals: readonly number[]): number {
  let mask = 0
  for (const interval of intervals) {
    const bit = cadenceBit(interval)
    if (bit === 0) {
      throw new PolicyError(
        `unknown cadence ${interval}s; expected one of ${CADENCES.join(', ')}`,
      )
    }
    mask |= bit
  }
  return mask
}

/** Every asset the mask allows, in bit order. Unknown high bits are ignored, never guessed at. */
export function assetsFromMask(mask: number): AssetSymbol[] {
  return ASSETS.filter((_, index) => (mask & (1 << index)) !== 0)
}

/** Every cadence the mask allows, in bit order. */
export function cadencesFromMask(mask: number): Cadence[] {
  return CADENCES.filter((_, index) => (mask & (1 << index)) !== 0)
}

/** Raw collateral units for a decimal tUSDC amount. */
export function toCollateral(amount: string): bigint {
  return parseUnits(amount, COLLATERAL_DECIMALS)
}

/** Decimal tUSDC for raw collateral units. */
export function fromCollateral(amount: bigint): string {
  return formatUnits(amount, COLLATERAL_DECIMALS)
}

function requireRange(label: string, value: number, max: number): number {
  if (!Number.isInteger(value) || value < 0 || value > max) {
    throw new PolicyError(`${label} must be an integer in 0..${max}, got ${value}`)
  }
  return value
}

function requireUint64(label: string, value: bigint): bigint {
  if (value < 0n || value > 0xffff_ffff_ffff_ffffn) {
    throw new PolicyError(`${label} does not fit in uint64, got ${value}`)
  }
  return value
}

/**
 * Turns a human draft into the exact struct `setPolicy` expects, validating every field the
 * contract would otherwise silently truncate. Round-trips with {@link decodePolicy}.
 */
export function encodePolicy(draft: PolicyDraft): Policy {
  if (!STRATEGY_NAMES.includes(draft.strategy)) {
    throw new PolicyError(
      `unknown strategy ${JSON.stringify(draft.strategy)}; expected one of ${STRATEGY_NAMES.join(', ')}`,
    )
  }
  return {
    maxStakePerWindow: requireUint64('maxStakePerWindow', toCollateral(draft.maxStakePerWindow)),
    dailyBudget: requireUint64('dailyBudget', toCollateral(draft.dailyBudget)),
    maxOpenMarkets: requireRange('maxOpenMarkets', draft.maxOpenMarkets, 0xffff),
    maxDrawdownBps: requireRange('maxDrawdownBps', draft.maxDrawdownBps, 0xffff),
    maxConsecutiveLosses: requireRange('maxConsecutiveLosses', draft.maxConsecutiveLosses, 0xff),
    minEdgeBps: requireRange('minEdgeBps', draft.minEdgeBps, 0xffff),
    allowedAssets: assetsMask(draft.assets),
    allowedCadences: cadencesMask(draft.cadences),
    strategy: Strategy[draft.strategy],
    armed: draft.armed,
  }
}

/** Inverse of {@link encodePolicy}: the on-chain struct, back in the terms a person wrote it in. */
export function decodePolicy(policy: Policy): PolicyDraft {
  const strategy = STRATEGY_NAMES.find((name) => Strategy[name] === policy.strategy)
  if (strategy === undefined) {
    throw new PolicyError(`unknown strategy id ${policy.strategy}`)
  }
  return {
    maxStakePerWindow: fromCollateral(policy.maxStakePerWindow),
    dailyBudget: fromCollateral(policy.dailyBudget),
    maxOpenMarkets: policy.maxOpenMarkets,
    maxDrawdownBps: policy.maxDrawdownBps,
    maxConsecutiveLosses: policy.maxConsecutiveLosses,
    minEdgeBps: policy.minEdgeBps,
    assets: assetsFromMask(policy.allowedAssets),
    cadences: cadencesFromMask(policy.allowedCadences),
    strategy,
    armed: policy.armed,
  }
}

/** Human name for a strategy id, for logs and CLI output. */
export function strategyName(strategy: number): string {
  const found = STRATEGY_NAMES.find((name) => Strategy[name] === strategy)
  return found ?? `Unknown(${strategy})`
}

function bpsPercent(bps: number): string {
  return `${(bps / 100).toFixed(2)}%`
}

function formatCadence(seconds: number): string {
  if (seconds % 3600 === 0) return `${seconds / 3600}h`
  if (seconds % 60 === 0) return `${seconds / 60}m`
  return `${seconds}s`
}

/**
 * The mandate in plain sentences, one per line — what the desk is allowed to do, and where it
 * has quietly forbidden itself from doing anything at all. The trailing notes matter more than
 * the numbers: a policy that can never trade should say so before it costs anyone a window.
 */
export function describePolicy(policy: Policy): string[] {
  const assets = assetsFromMask(policy.allowedAssets)
  const cadences = cadencesFromMask(policy.allowedCadences)

  const lines = [
    `Strategy        ${strategyName(policy.strategy)}`,
    `Armed           ${policy.armed ? 'yes' : 'no'}`,
    `Assets          ${assets.length > 0 ? assets.join(', ') : 'none'} (mask 0b${policy.allowedAssets.toString(2)})`,
    `Cadences        ${
      cadences.length > 0 ? cadences.map(formatCadence).join(', ') : 'none'
    } (mask 0b${policy.allowedCadences.toString(2)})`,
    `Max per window  ${fromCollateral(policy.maxStakePerWindow)} ${COLLATERAL_SYMBOL}`,
    `Daily budget    ${fromCollateral(policy.dailyBudget)} ${COLLATERAL_SYMBOL}`,
    `Max open        ${policy.maxOpenMarkets} market${policy.maxOpenMarkets === 1 ? '' : 's'}`,
    `Min edge        ${bpsPercent(policy.minEdgeBps)} vs the book`,
    `Max drawdown    ${
      policy.maxDrawdownBps >= 10_000
        ? 'never halts'
        : `${bpsPercent(policy.maxDrawdownBps)} below the high-water mark`
    }`,
    `Loss streak     halts after ${policy.maxConsecutiveLosses} consecutive loss${
      policy.maxConsecutiveLosses === 1 ? '' : 'es'
    }`,
  ]

  if (!policy.armed) {
    lines.push('Note            disarmed — every market is refused with NotArmed.')
  }
  if (assets.length === 0) {
    lines.push('Note            no asset allowed — every market is refused with AssetNotAllowed.')
  }
  if (cadences.length === 0) {
    lines.push('Note            no cadence allowed — every market is refused with CadenceNotAllowed.')
  }
  if (policy.maxStakePerWindow === 0n) {
    lines.push('Note            zero per-window cap — the pre-filter refuses with CapExceeded.')
  }
  if (policy.maxOpenMarkets === 0) {
    lines.push('Note            zero open slots — every market is refused with MaxOpenReached.')
  }
  if (policy.maxConsecutiveLosses === 0) {
    lines.push('Note            zero loss tolerance — the desk is halted from its first window.')
  }
  if (policy.dailyBudget < policy.maxStakePerWindow) {
    lines.push('Note            daily budget is below the per-window cap, so it binds first.')
  }

  const dead = cadences.filter((c) => UNTRADEABLE_CADENCES.includes(c))
  if (dead.length > 0) {
    lines.push(
      `Note            ${dead
        .map(formatCadence)
        .join(', ')} can never clear the ${MIN_WINDOW_SLACK_SECONDS}s minimum slack — considered, then refused WindowTooShort.`,
    )
    if (dead.length === cadences.length) {
      lines.push('Note            every allowed cadence is untradeable; this desk will never trade.')
    }
  }

  return lines
}
