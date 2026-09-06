import { keccak256, toHex } from 'viem'
import type { Hex } from 'viem'
import { BOOK_UNOBSERVED, MIN_WINDOW_SLACK_SECONDS } from './chain/config'

/* ============================================================================
   Refusals — `LucidTypes.Refusal`, in declaration order.
   The order is the wire format. New reasons are appended on chain, never inserted, because a
   renumbering would silently retitle every refusal in every log line ever emitted.
   ========================================================================== */

export const REFUSALS = [
  'None',
  'NotArmed',
  'AssetNotAllowed',
  'CadenceNotAllowed',
  'WindowTooShort',
  'CapExceeded',
  'DailyBudgetExceeded',
  'MaxOpenReached',
  'RiskHalt',
  'AiUnavailable',
  'AiMalformed',
  'LowEdge',
  'VenueRejected',
  'NoCredit',
  'InsufficientFunds',
  'NoBook',
] as const

export type RefusalName = (typeof REFUSALS)[number]

/** Label for a refusal code, or `Unknown(n)` for a code minted by a newer contract than this build. */
export function refusalName(code: number): string {
  return REFUSALS[code] ?? `Unknown(${code})`
}

/** One line per refusal, so a reader never has to guess what a reason code means. */
export const REFUSAL_REASONS: Readonly<Record<RefusalName, string>> = {
  None: 'The mandate allowed the trade.',
  NotArmed: 'The desk is switched off.',
  AssetNotAllowed: 'The mandate does not cover this asset.',
  CadenceNotAllowed: 'The mandate does not cover this window length.',
  WindowTooShort: 'Too little time left to place an order and still settle it safely.',
  CapExceeded: 'The order would breach the per-window notional cap.',
  DailyBudgetExceeded: 'Today’s budget is spent.',
  MaxOpenReached: 'Every open-market slot is already taken.',
  RiskHalt: 'Drawdown or a loss streak halted the desk.',
  AiUnavailable: 'The validator committee did not answer in time.',
  AiMalformed: 'The committee answered outside the valid range.',
  LowEdge: 'The committee and the book agree, so there is nothing worth trading.',
  VenueRejected: 'The venue would not accept the order.',
  NoCredit: 'The desk has no gas credit left at the router.',
  InsufficientFunds: 'Not enough free collateral to fund the position.',
  NoBook: 'No side of the book quoted, so there is no market price to trade against.',
}

/** Which family a refusal belongs to, for colour and for grouping. */
export type RefusalFamily = 'mandate' | 'risk' | 'committee' | 'market' | 'funding' | 'none'

export const REFUSAL_FAMILY: Readonly<Record<RefusalName, RefusalFamily>> = {
  None: 'none',
  NotArmed: 'mandate',
  AssetNotAllowed: 'mandate',
  CadenceNotAllowed: 'mandate',
  WindowTooShort: 'market',
  CapExceeded: 'risk',
  DailyBudgetExceeded: 'risk',
  MaxOpenReached: 'risk',
  RiskHalt: 'risk',
  AiUnavailable: 'committee',
  AiMalformed: 'committee',
  LowEdge: 'committee',
  VenueRejected: 'market',
  NoCredit: 'funding',
  InsufficientFunds: 'funding',
  NoBook: 'market',
}

/**
 * `PolicyLib.gate` runs in this order and the first failure wins. It is not the declaration
 * order: `NoBook` was appended to the enum but is checked just before `LowEdge`.
 */
export const GATE_ORDER: readonly RefusalName[] = [
  'NotArmed',
  'AssetNotAllowed',
  'CadenceNotAllowed',
  'WindowTooShort',
  'MaxOpenReached',
  'RiskHalt',
  'AiUnavailable',
  'AiMalformed',
  'NoBook',
  'LowEdge',
  'CapExceeded',
  'DailyBudgetExceeded',
]

/* ============================================================================
   The book sentinel.
   ========================================================================== */

/** True when the probability field carries `BOOK_UNOBSERVED` rather than a quote. */
export function isBookUnobserved(pBookBps: number): boolean {
  return pBookBps === BOOK_UNOBSERVED || pBookBps > 10_000
}

/* ============================================================================
   Policy — `LucidTypes.Policy`, and the bitmasks it carries.
   ========================================================================== */

export interface Policy {
  maxStakePerWindow: bigint
  dailyBudget: bigint
  maxOpenMarkets: number
  maxDrawdownBps: number
  maxConsecutiveLosses: number
  minEdgeBps: number
  allowedAssets: number
  allowedCadences: number
  strategy: number
  armed: boolean
}

export interface DeskState {
  dayKey: bigint
  spentToday: bigint
  highWaterMark: bigint
  openMarkets: number
  consecutiveLosses: number
}

export const STRATEGIES = ['AiEdge', 'Maker'] as const
export type StrategyName = (typeof STRATEGIES)[number]

export function strategyName(id: number): string {
  return STRATEGIES[id] ?? `Unknown(${id})`
}

/** What each strategy actually does, in one line. */
export const STRATEGY_BLURB: Readonly<Record<StrategyName, string>> = {
  AiEdge:
    'Takes liquidity. Trades the gap between the committee’s probability and the book’s, sized in proportion to it.',
  Maker:
    'Provides liquidity. Mints a complete set, which needs no counterparty, then rests both legs around the committee’s fair value.',
}

/** `PolicyLib.assetBit` order: bit 0 = BTC, bit 1 = ETH. */
export const ASSETS = ['BTC', 'ETH'] as const
export type AssetSymbol = (typeof ASSETS)[number]

/** `PolicyLib.cadenceBit` order: bit 0 = 60 s, 1 = 300 s, 2 = 900 s, 3 = 3600 s. */
export const CADENCES = [60, 300, 900, 3600] as const
export type Cadence = (typeof CADENCES)[number]

export function assetsFromMask(mask: number): AssetSymbol[] {
  return ASSETS.filter((_, index) => (mask & (1 << index)) !== 0)
}

export function cadencesFromMask(mask: number): Cadence[] {
  return CADENCES.filter((_, index) => (mask & (1 << index)) !== 0)
}

/** `keccak256(bytes(symbol))` — the form the venue log carries. */
export function assetKey(symbol: string): Hex {
  return keccak256(toHex(symbol))
}

const ASSET_KEYS = new Map<string, AssetSymbol>(
  ASSETS.map((symbol) => [assetKey(symbol).toLowerCase(), symbol]),
)

/**
 * Reverses the hash for the two symbols a desk can trade. A two-entry lookup, not a guess:
 * anything else is shown as the truncated hash rather than labelled wrongly.
 */
export function assetFromKey(key: Hex): string {
  return ASSET_KEYS.get(key.toLowerCase()) ?? `${key.slice(0, 10)}…`
}

/**
 * A 60-second window can never clear the 90-second minimum slack, so a mandate that allows it
 * will consider those markets and refuse every one with `WindowTooShort`. The bit stays legal
 * on chain, so the interface says so rather than hiding it.
 */
export const UNTRADEABLE_CADENCES: readonly Cadence[] = CADENCES.filter(
  (c) => c < MIN_WINDOW_SLACK_SECONDS,
)

/** Everything about a mandate that will stop it trading, in plain sentences. */
export function policyWarnings(policy: Policy): string[] {
  const warnings: string[] = []
  const assets = assetsFromMask(policy.allowedAssets)
  const cadences = cadencesFromMask(policy.allowedCadences)

  if (!policy.armed) warnings.push('Disarmed — every window is refused with NotArmed.')
  if (assets.length === 0) warnings.push('No asset allowed — every window is refused with AssetNotAllowed.')
  if (cadences.length === 0)
    warnings.push('No cadence allowed — every window is refused with CadenceNotAllowed.')
  if (policy.maxStakePerWindow === 0n)
    warnings.push('Zero per-window cap — the pre-filter refuses with CapExceeded.')
  if (policy.maxOpenMarkets === 0) warnings.push('Zero open slots — every window is refused with MaxOpenReached.')
  if (policy.maxConsecutiveLosses === 0)
    warnings.push('Zero loss tolerance — the desk is halted from its first window.')
  if (policy.dailyBudget < policy.maxStakePerWindow)
    warnings.push('The daily budget is below the per-window cap, so it binds first.')

  const dead = cadences.filter((c) => UNTRADEABLE_CADENCES.includes(c))
  if (dead.length > 0) {
    warnings.push(
      `${dead.map((c) => `${c} s`).join(', ')} can never clear the ${MIN_WINDOW_SLACK_SECONDS}-second minimum slack — considered, then refused WindowTooShort.`,
    )
    if (dead.length === cadences.length)
      warnings.push('Every allowed cadence is untradeable; this desk will never trade.')
  }
  return warnings
}

/* ============================================================================
   Order kinds — `placeBinaryOrder` side encoding, as emitted in `Executed.kind`.
   ========================================================================== */

export const ORDER_KINDS = ['Buy UP', 'Sell UP', 'Buy DOWN', 'Sell DOWN'] as const

export function orderKindName(kind: number): string {
  return ORDER_KINDS[kind] ?? `Unknown(${kind})`
}

/** True for the two buying sides, which is what decides the badge colour. */
export function isBuySide(kind: number): boolean {
  return kind === 0 || kind === 2
}

/* ============================================================================
   Router `Skipped` reasons. A free-form string on chain, a closed set in practice.
   ========================================================================== */

export const SKIP_REASONS: Readonly<Record<string, string>> = {
  BAD_SCALE: 'A follower’s copy scale was outside the legal range.',
  COPY_FAILED: 'A follower desk reverted while mirroring the leader.',
  DECISION_PAST: 'The decision point had already passed when the window was seen.',
  DECISION_SCHEDULE_FAILED: 'The precompile refused the decision timer.',
  DESK_REVERTED: 'The desk reverted while being handed the window.',
  EXPIRED: 'The window had already expired.',
  KEEPER_FAILED: 'The venue-wide upkeep call reverted.',
  NO_BRAIN: 'No brain is configured on the router.',
  NO_CODE: 'The address registered as a desk has no code.',
  NO_CREDIT: 'The desk has no gas credit left at the router to pay for a verdict.',
  NO_GAS: 'The firing ran out of its gas allowance before reaching this step.',
  NO_VERDICT: 'No verdict had been stored when the desk was asked to act.',
  RELAY_FAILED: 'The auto-redeem relay reverted.',
  ROUTER_FLOAT: 'Spending would have taken the router below the 32 SOMI subscription floor.',
  SCHEDULE_FAILED: 'The precompile refused the settlement timer.',
  SERIES_FAILED: 'The failover roller reverted.',
  SETTLEMENT_REVERTED: 'The desk reverted while settling the window.',
  TOO_LATE: 'The firing arrived after the window closed.',
  UNDECODABLE: 'The venue log did not decode as a market this router understands.',
  VERDICT_REQUEST_FAILED: 'The committee request could not be placed.',
}

export function skipReasonText(reason: string): string {
  return SKIP_REASONS[reason] ?? 'A step was skipped for a reason this build does not recognise.'
}

/* ============================================================================
   LucidSeries failover modes.
   ========================================================================== */

export const SERIES_MODES = ['Off', 'Failover', 'Continuous'] as const

export function seriesModeName(mode: number): string {
  return SERIES_MODES[mode] ?? `Unknown(${mode})`
}

export const SERIES_MODE_BLURB: Readonly<Record<string, string>> = {
  Off: 'The roller is switched off. If the venue stops rolling windows, nothing replaces them.',
  Failover:
    'The roller spends nothing while the venue’s own scheduler is healthy, and starts only when no window of the watched cadence has appeared for the staleness window.',
  Continuous: 'The roller creates every window itself, regardless of the venue’s scheduler.',
}
