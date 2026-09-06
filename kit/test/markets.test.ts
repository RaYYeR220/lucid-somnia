import { describe, expect, it } from 'vitest'
import {
  BINARY_MARKET_TYPE,
  TERMINAL_STATUS,
  filterLiveMarkets,
  parseMarketRow,
  secondsLeft,
  selectLiveMarkets,
  winnerLabel,
} from '../src/markets.js'
import { MIN_WINDOW_SLACK_SECONDS } from '../src/addresses.js'
import { FIXTURE_NOW, INDEXER_LIVE_RESPONSE, INDEXER_SETTLED_RESPONSE } from './fixtures.js'

const ids = (rows: { marketId: string }[]) => rows.map((m) => m.marketId)

describe('indexer vocabulary', () => {
  it('uses the terminal status the indexer actually has', () => {
    // "Resolved" does not exist in this schema; a filter written against it matches nothing.
    expect(TERMINAL_STATUS).toBe('Finalized')
    expect(BINARY_MARKET_TYPE).toBe('BINARY')
  })
})

describe('parseMarketRow', () => {
  it('turns the indexer strings into the types the kit works in', () => {
    const [row] = INDEXER_LIVE_RESPONSE
    if (row === undefined) throw new Error('fixture is empty')
    const market = parseMarketRow(row)
    expect(market.expiry).toBe(FIXTURE_NOW + 300)
    expect(market.intervalSec).toBe(300)
    expect(market.strike).toBe(7_993_610n)
    expect(market.yesTokenId).toBeTypeOf('bigint')
    expect(market.lastPrice).toBe(550_000n)
  })

  it('keeps an untraded book as null rather than collapsing it to zero', () => {
    const settled = INDEXER_SETTLED_RESPONSE.map(parseMarketRow)
    expect(settled.every((m) => m.lastPrice === null)).toBe(true)
    // A 0n last price would read as "the market traded at zero", which is a different claim.
    expect(settled[0]?.payoutDenominator).toBe(10_000_000n)
  })
})

describe('liveMarkets filter', () => {
  const opts = { now: FIXTURE_NOW }

  it('keeps only windows with more than the 90-second slack left', () => {
    expect(ids(selectLiveMarkets(INDEXER_LIVE_RESPONSE, opts))).toEqual(['0x14a44', '0x14a16'])
  })

  it('drops a stale row even though the indexer still calls it Trading', () => {
    const stale = INDEXER_LIVE_RESPONSE.filter((r) => r.marketId === '0x14a3f')
    expect(stale[0]?.clobStatus).toBe('Trading')
    expect(Number(stale[0]?.expiry)).toBeLessThan(FIXTURE_NOW)
    expect(selectLiveMarkets(stale, opts)).toEqual([])
  })

  it('treats the slack as strictly greater, so the boundary row is excluded', () => {
    const boundary = INDEXER_LIVE_RESPONSE.filter((r) => r.marketId === '0x14a45')
    expect(Number(boundary[0]?.expiry)).toBe(FIXTURE_NOW + MIN_WINDOW_SLACK_SECONDS)
    expect(selectLiveMarkets(boundary, opts)).toEqual([])
    expect(selectLiveMarkets(boundary, { now: FIXTURE_NOW - 1 })).toHaveLength(1)
  })

  it('never returns a 60-second window under the default slack, whatever the mask allows', () => {
    const minute = INDEXER_LIVE_RESPONSE.filter((r) => r.intervalSec === '60')
    expect(minute).not.toHaveLength(0)
    expect(selectLiveMarkets(minute, { ...opts, cadences: [60] })).toEqual([])
  })

  it('drops assets and cadences outside the mandate', () => {
    expect(ids(selectLiveMarkets(INDEXER_LIVE_RESPONSE, { ...opts, assets: ['ETH'] }))).toEqual([
      '0x14a16',
    ])
    expect(ids(selectLiveMarkets(INDEXER_LIVE_RESPONSE, { ...opts, cadences: [300] }))).toEqual([
      '0x14a44',
    ])
    // SOL is listed by the venue and unreachable to a desk; it must never surface as tradeable.
    expect(ids(selectLiveMarkets(INDEXER_LIVE_RESPONSE, opts))).not.toContain('0x14b01')
  })

  it('drops finalized and voided rows regardless of their nominal expiry', () => {
    const settled = INDEXER_LIVE_RESPONSE.filter((r) => r.marketId === '0x14a2c')
    const voided = INDEXER_LIVE_RESPONSE.filter((r) => r.marketId === '0x14a2d')
    expect(Number(settled[0]?.expiry)).toBeGreaterThan(FIXTURE_NOW + MIN_WINDOW_SLACK_SECONDS)
    expect(selectLiveMarkets(settled, opts)).toEqual([])
    expect(selectLiveMarkets(voided, opts)).toEqual([])
  })

  it('honours a custom slack in both directions', () => {
    expect(ids(selectLiveMarkets(INDEXER_LIVE_RESPONSE, { ...opts, minSecondsLeft: 30 }))).toEqual([
      '0x14a43',
      '0x14a4e',
      '0x14a45',
      '0x14a44',
      '0x14a16',
    ])
    expect(selectLiveMarkets(INDEXER_LIVE_RESPONSE, { ...opts, minSecondsLeft: 3_000 })).toEqual([])
  })

  it('sorts soonest expiry first, because that is the window about to close', () => {
    const sorted = selectLiveMarkets(INDEXER_LIVE_RESPONSE, { ...opts, minSecondsLeft: 30 })
    const expiries = sorted.map((m) => m.expiry)
    expect([...expiries].sort((a, b) => a - b)).toEqual(expiries)
  })

  it('is a pure function of its inputs — the same rows twice give the same answer', () => {
    const first = selectLiveMarkets(INDEXER_LIVE_RESPONSE, opts)
    const second = filterLiveMarkets(INDEXER_LIVE_RESPONSE.map(parseMarketRow), opts)
    expect(ids(second)).toEqual(ids(first))
  })
})

describe('secondsLeft', () => {
  it('floors at zero rather than going negative on a stale row', () => {
    const [live] = selectLiveMarkets(INDEXER_LIVE_RESPONSE, { now: FIXTURE_NOW })
    if (live === undefined) throw new Error('fixture has no live market')
    expect(secondsLeft(live, FIXTURE_NOW)).toBe(300)
    expect(secondsLeft(live, FIXTURE_NOW + 10_000)).toBe(0)
  })
})

describe('winnerLabel', () => {
  it('names the paying side, and calls a void a void', () => {
    const [yes, no, voided] = INDEXER_SETTLED_RESPONSE.map(parseMarketRow)
    if (yes === undefined || no === undefined || voided === undefined) {
      throw new Error('fixture is short')
    }
    expect(winnerLabel(yes)).toBe('NO')
    expect(winnerLabel(no)).toBe('YES')
    expect(winnerLabel(voided)).toBe('VOID')
  })

  it('does not claim a winner for a market that has not resolved', () => {
    const [live] = INDEXER_LIVE_RESPONSE.map(parseMarketRow)
    if (live === undefined) throw new Error('fixture is empty')
    expect(winnerLabel(live)).toBe('pending')
  })
})
