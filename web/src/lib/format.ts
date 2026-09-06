import { formatEther, formatUnits } from 'viem'
import { BPS, COLLATERAL_DECIMALS } from './chain/config'

/**
 * Every number a person reads in this app is formatted here, through `Intl`, so grouping and
 * decimal separators follow the reader's locale instead of a hardcoded guess.
 */
const nf = (min: number, max: number) =>
  new Intl.NumberFormat(undefined, { minimumFractionDigits: min, maximumFractionDigits: max })

const int = nf(0, 0)
const two = nf(2, 2)
const upToTwo = nf(0, 2)
const upToFour = nf(0, 4)

/** A plain count. `0` is a fact and is printed as one. */
export function count(value: number | bigint): string {
  return int.format(value)
}

/** Raw collateral units → decimal tUSDC, two places. */
export function usdc(raw: bigint): string {
  return two.format(Number(formatUnits(raw, COLLATERAL_DECIMALS)))
}

/** Raw collateral units → decimal tUSDC with a sign, for P&L. */
export function signedUsdc(raw: bigint): string {
  const value = Number(formatUnits(raw, COLLATERAL_DECIMALS))
  return `${value > 0 ? '+' : value < 0 ? '−' : ''}${two.format(Math.abs(value))}`
}

/** Wei → SOMI, trimmed. The router float is read in whole coins, not gwei. */
export function somi(wei: bigint, places = 2): string {
  return nf(places, places).format(Number(formatEther(wei)))
}

/** Wei → SOMI at four places, for the small fees. */
export function somiPrecise(wei: bigint): string {
  return upToFour.format(Number(formatEther(wei)))
}

/** A gas limit in millions, the unit these are always quoted in. */
export function millions(value: bigint | number): string {
  return int.format(Math.round(Number(value) / 1_000_000))
}

/** A validator's `0..100` answer, in the `0.00` form a book quotes a probability in. */
export function score01(score: number): string {
  return nf(2, 2).format(score / 100)
}

/** A plain percentage, through `Intl` like every other number here. */
export function percent(value: number, places = 1): string {
  return `${nf(places, places).format(value)}%`
}

/** Basis points → percent. `100` bps is `1%`. */
export function bpsPercent(bps: number, places = 2): string {
  return `${nf(places, places).format(bps / 100)}%`
}

/** A probability in basis points → a two-decimal probability, the way a book quotes one. */
export function probability(bps: number): string {
  return upToTwo.format((bps / BPS) * 100)
}

/** Venue prices are raw six-decimal collateral, so `550000` is `0.5500`. */
export function contractPrice(raw: bigint): string {
  return nf(4, 4).format(Number(formatUnits(raw, COLLATERAL_DECIMALS)))
}

/** `300` → `5m`. Window lengths only ever come in these shapes. */
export function cadence(seconds: number): string {
  if (seconds <= 0) return '—'
  if (seconds % 3600 === 0) return `${seconds / 3600}h`
  if (seconds % 60 === 0) return `${seconds / 60}m`
  return `${seconds}s`
}

/** `0x7a1B…a4c4`. Long enough to recognise, short enough to sit in a table cell. */
export function shortAddress(address: string): string {
  return address.length > 12 ? `${address.slice(0, 6)}…${address.slice(-4)}` : address
}

/** A market id is a padded uint; the leading zeros carry nothing. */
export function shortId(id: string): string {
  const trimmed = id.replace(/^0x0*/, '')
  return trimmed === '' ? '0x0' : `0x${trimmed}`
}

/**
 * A countdown for a table cell.
 *
 * Below a day it is a clock, because seconds matter on a five-minute window. Above a day a clock
 * is unreadable noise — `1013:06:20` tells nobody anything — so it degrades to whole days.
 */
export function countdownOrDays(seconds: number): string {
  if (seconds <= 0) return 'closed'
  if (seconds >= 86_400) {
    const days = Math.floor(seconds / 86_400)
    return `${int.format(days)} day${days === 1 ? '' : 's'}`
  }
  return countdown(seconds)
}

/** A countdown, `mm:ss` under an hour and `h:mm:ss` above it. Negative clamps to zero. */
export function countdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const hours = Math.floor(s / 3600)
  const minutes = Math.floor((s % 3600) / 60)
  const secs = s % 60
  const pad = (n: number) => n.toString().padStart(2, '0')
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(secs)}` : `${pad(minutes)}:${pad(secs)}`
}

/** `2 minutes ago`, through `Intl.RelativeTimeFormat`. */
export function relativeTime(unixSeconds: number, now = Date.now() / 1000): string {
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' })
  const delta = unixSeconds - now
  const abs = Math.abs(delta)
  if (abs < 60) return rtf.format(Math.round(delta), 'second')
  if (abs < 3600) return rtf.format(Math.round(delta / 60), 'minute')
  if (abs < 86400) return rtf.format(Math.round(delta / 3600), 'hour')
  return rtf.format(Math.round(delta / 86400), 'day')
}

/** An absolute UTC timestamp, for the tooltip behind every relative one. */
export function utcTimestamp(unixSeconds: number): string {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'medium',
    timeZone: 'UTC',
  }).format(new Date(unixSeconds * 1000))
}

/** The oracle's strike scale is two decimals of a dollar, so `8008333` is `80 083.33`. */
export function strikePrice(raw: bigint): string {
  return two.format(Number(raw) / 100)
}

/** Blocks land in roughly 100 ms, so a block span is a readable amount of wall-clock time. */
export const BLOCK_MS = 100

export function blocksToDuration(blocks: number): string {
  const seconds = (blocks * BLOCK_MS) / 1000
  if (seconds < 90) return `${int.format(Math.round(seconds))} s`
  if (seconds < 5400) return `${int.format(Math.round(seconds / 60))} min`
  return `${upToTwo.format(seconds / 3600)} h`
}

/** A duration in seconds, as prose. */
export function duration(seconds: number): string {
  if (seconds < 60) return `${int.format(Math.round(seconds))} s`
  if (seconds < 3600) return `${int.format(Math.round(seconds / 60))} min`
  if (seconds < 86400) return `${upToTwo.format(seconds / 3600)} h`
  return `${upToTwo.format(seconds / 86400)} days`
}

/** A share of a whole, clamped, for meter widths. */
export function pctOf(part: bigint, whole: bigint): number {
  if (whole === 0n) return 0
  const ratio = Number((part * 10_000n) / whole) / 100
  return Math.max(0, Math.min(100, ratio))
}
