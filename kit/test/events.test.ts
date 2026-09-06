import { describe, expect, it } from 'vitest'
import {
  ORDER_KINDS,
  REFUSALS,
  REFUSAL_REASONS,
  assetSymbolFromKey,
  decodeDeskLog,
  decodeLucidLog,
  decodeRouterLog,
  formatEvent,
  orderKindName,
  refusalName,
} from '../src/events.js'
import type { LucidEvent } from '../src/events.js'
import { assetKey } from '../src/policy.js'
import {
  DESK,
  LOG_ARMED_SET,
  LOG_CONSIDERED,
  LOG_EXECUTED,
  LOG_MARKET_SEEN,
  LOG_REFUSED,
  LOG_SETTLED,
  LOG_SETTLEMENT_SCHEDULED,
  LOG_SKIPPED,
  LOG_UNMODELLED_ROUTER,
  LOG_VERDICT_RECEIVED,
  MARKET_ID,
} from './fixtures.js'

function deskEvent(log: Parameters<typeof decodeDeskLog>[0]): LucidEvent {
  const decoded = decodeDeskLog(log)
  if (decoded === undefined) throw new Error('expected the desk log to decode')
  return decoded
}

function routerEvent(log: Parameters<typeof decodeRouterLog>[0]): LucidEvent {
  const decoded = decodeRouterLog(log)
  if (decoded === undefined) throw new Error('expected the router log to decode')
  return decoded
}

describe('refusalName', () => {
  it('maps every Refusal enum member to its Solidity name, in declaration order', () => {
    expect(REFUSALS).toEqual([
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
    ])
    REFUSALS.forEach((name, code) => expect(refusalName(code)).toBe(name))
  })

  it('labels a code from a newer contract instead of returning undefined', () => {
    expect(refusalName(REFUSALS.length)).toBe('Unknown(15)')
    expect(refusalName(255)).toBe('Unknown(255)')
  })

  it('has a human sentence for every refusal', () => {
    for (const name of REFUSALS) expect(REFUSAL_REASONS[name].length).toBeGreaterThan(0)
  })
})

describe('orderKindName', () => {
  it('matches the placeBinaryOrder side encoding', () => {
    expect(ORDER_KINDS).toEqual(['BUY_YES', 'SELL_YES', 'BUY_NO', 'SELL_NO'])
    ORDER_KINDS.forEach((name, kind) => expect(orderKindName(kind)).toBe(name))
    expect(orderKindName(9)).toBe('Unknown(9)')
  })
})

describe('assetSymbolFromKey', () => {
  it('reverses the hash for the assets a desk can trade', () => {
    expect(assetSymbolFromKey(assetKey('BTC'))).toBe('BTC')
    expect(assetSymbolFromKey(assetKey('ETH'))).toBe('ETH')
  })

  it('shows the raw prefix rather than guessing at an unknown key', () => {
    expect(assetSymbolFromKey(assetKey('SOL'))).toMatch(/^0x[0-9a-f]{8}…$/)
  })
})

describe('desk log decoding', () => {
  it('decodes Considered', () => {
    const event = deskEvent(LOG_CONSIDERED)
    expect(event.source).toBe('desk')
    expect(event.name).toBe('Considered')
    if (event.name !== 'Considered') throw new Error('narrowing failed')
    expect(event.args.marketId).toBe(MARKET_ID)
    expect(event.args.intervalSec).toBe(300)
    expect(assetSymbolFromKey(event.args.assetKey)).toBe('BTC')
  })

  it('decodes VerdictReceived, keeping bps as integers', () => {
    const event = deskEvent(LOG_VERDICT_RECEIVED)
    if (event.name !== 'VerdictReceived') throw new Error('narrowing failed')
    expect(event.args).toEqual({
      marketId: MARKET_ID,
      probUpBps: 6_400,
      pBookBps: 5_100,
      responded: 3,
    })
  })

  it('decodes Executed, keeping venue amounts as bigints', () => {
    const event = deskEvent(LOG_EXECUTED)
    if (event.name !== 'Executed') throw new Error('narrowing failed')
    expect(event.args.kind).toBe(0)
    expect(event.args.price).toBe(520_000n)
    expect(event.args.quantity).toBe(10_000_000n)
    expect(event.args.orderId).toBe(42n)
  })

  it('decodes Refused and resolves the reason code', () => {
    const event = deskEvent(LOG_REFUSED)
    if (event.name !== 'Refused') throw new Error('narrowing failed')
    expect(event.args.reason).toBe(11)
    expect(refusalName(event.args.reason)).toBe('LowEdge')
    expect(event.args.probUpBps).toBe(5_120)
    expect(event.args.pBookBps).toBe(5_100)
  })

  it('decodes Settled, including a negative int256 pnl', () => {
    const event = deskEvent(LOG_SETTLED)
    if (event.name !== 'Settled') throw new Error('narrowing failed')
    expect(event.args.pnl).toBe(-1_250_000n)
    expect(event.args.equityAfter).toBe(4_998_750_000n)
  })

  it('carries the log metadata through', () => {
    const event = deskEvent(LOG_EXECUTED)
    expect(event.address).toBe(DESK)
    expect(event.blockNumber).toBe(480_847_582n)
    expect(event.logIndex).toBe(2)
  })

  it('returns undefined for a desk event outside the streamed set', () => {
    expect(decodeDeskLog(LOG_ARMED_SET)).toBeUndefined()
  })

  it('returns undefined instead of throwing on a log from another contract', () => {
    expect(decodeDeskLog(LOG_UNMODELLED_ROUTER)).toBeUndefined()
  })
})

describe('router log decoding (captured live from Shannon)', () => {
  it('decodes MarketSeen', () => {
    const event = routerEvent(LOG_MARKET_SEEN)
    expect(event.source).toBe('router')
    if (event.name !== 'MarketSeen') throw new Error('narrowing failed')
    expect(event.args.intervalSec).toBe(300)
    expect(assetSymbolFromKey(event.args.assetKey)).toBe('ETH')
  })

  it('decodes Skipped, including the dynamic reason string', () => {
    const event = routerEvent(LOG_SKIPPED)
    if (event.name !== 'Skipped') throw new Error('narrowing failed')
    expect(event.args.desk.toLowerCase()).toBe(DESK)
    expect(event.args.reason).toBe('NO_CREDIT')
  })

  it('decodes SettlementScheduled with the firing time in millis', () => {
    const event = routerEvent(LOG_SETTLEMENT_SCHEDULED)
    if (event.name !== 'SettlementScheduled') throw new Error('narrowing failed')
    expect(event.args.tsMillis).toBe(1_788_658_205_000n)
    expect(event.args.subscriptionId).toBe(16_336_857n)
  })

  it('ignores router events the kit does not model', () => {
    expect(decodeRouterLog(LOG_UNMODELLED_ROUTER)).toBeUndefined()
  })
})

describe('decodeLucidLog', () => {
  it('picks the ABI by emitter, since both contracts emit an identically shaped market event', () => {
    const fromRouter = decodeLucidLog(LOG_MARKET_SEEN)
    expect(fromRouter?.name).toBe('MarketSeen')
    expect(fromRouter?.source).toBe('router')

    const fromDesk = decodeLucidLog(LOG_CONSIDERED)
    expect(fromDesk?.name).toBe('Considered')
    expect(fromDesk?.source).toBe('desk')
  })
})

describe('formatEvent', () => {
  it('renders a whole window as a person would read it', () => {
    expect(formatEvent(deskEvent(LOG_CONSIDERED))).toBe('Considered  0x000000…4a51 BTC 300s')
    expect(formatEvent(deskEvent(LOG_VERDICT_RECEIVED))).toBe(
      'Verdict     0x000000…4a51 committee 64.0% vs book 51.0% (3 validators)',
    )
    expect(formatEvent(deskEvent(LOG_EXECUTED))).toBe(
      'Executed    0x000000…4a51 BUY_YES 10000000 @ 0.5200 order #42',
    )
    expect(formatEvent(deskEvent(LOG_SETTLED))).toBe(
      'Settled     0x000000…4a51 pnl -1.25 equity 4998.75',
    )
  })

  it('spells out why a refusal happened, not just its code', () => {
    expect(formatEvent(deskEvent(LOG_REFUSED))).toBe(
      'Refused     0x000000…4a51 LowEdge — the committee and the book agree, so there is nothing to trade',
    )
  })

  it('renders the router side too', () => {
    expect(formatEvent(routerEvent(LOG_MARKET_SEEN))).toBe('MarketSeen  0x000000…4a51 ETH 300s')
    expect(formatEvent(routerEvent(LOG_SKIPPED))).toBe(
      'Skipped     0x000000…4a51 desk 0x4EEDAB…14f5 — NO_CREDIT',
    )
    expect(formatEvent(routerEvent(LOG_SETTLEMENT_SCHEDULED))).toBe(
      'Scheduled   0x000000…4a51 at 2026-09-06T01:30:05.000Z (sub 16336857)',
    )
  })

  it('never throws on any event it can produce', () => {
    for (const log of [
      LOG_CONSIDERED,
      LOG_VERDICT_RECEIVED,
      LOG_EXECUTED,
      LOG_REFUSED,
      LOG_SETTLED,
    ]) {
      expect(() => formatEvent(deskEvent(log))).not.toThrow()
    }
    for (const log of [LOG_MARKET_SEEN, LOG_SKIPPED, LOG_SETTLEMENT_SCHEDULED]) {
      expect(() => formatEvent(routerEvent(log))).not.toThrow()
    }
  })
})
