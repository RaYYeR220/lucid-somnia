import { describe, expect, it } from 'vitest'
import {
  SAFE_HANDLER_GAS_FLOOR,
  SELECTOR_ON_EVENT,
  TOPIC_BLOCK_TICK,
  TOPIC_MARKET_CREATED,
  TOPIC_SCHEDULE,
  describeSubscription,
  hasSafeGasLimit,
  parseSubscriptionInfo,
} from '../src/subscriptions.js'
import type { RawSubscriptionInfo } from '../src/subscriptions.js'
import {
  RAW_SUBSCRIPTION_MARKET_LISTENER,
  RAW_SUBSCRIPTION_ONE_SHOT,
  RAW_SUBSCRIPTION_UNDERGASSED,
  ROUTER,
} from './fixtures.js'

/** The fixtures are `as const`, which the parser's mutable-ish input type does not require. */
const raw = (value: unknown): RawSubscriptionInfo => value as RawSubscriptionInfo

describe('selectors', () => {
  it('matches the topics Shannon actually emits', () => {
    // Both confirmed against live subscriptions on 50312.
    expect(TOPIC_MARKET_CREATED).toBe(
      '0xb5ec75cdb7dbcd28a5f50d152d8833334525a902ef5332ebc19bcf5c0011f8cd',
    )
    expect(TOPIC_SCHEDULE).toBe(
      '0x67aa3d752967d87d8944b9c7adf73172518777fa4703f336edee81f0736d8987',
    )
    expect(SELECTOR_ON_EVENT).toBe('0x53edf33d')
  })
})

describe('parseSubscriptionInfo', () => {
  it('normalises the node payload out of snake_case hex', () => {
    const info = parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_MARKET_LISTENER))
    expect(info.id).toBe(16_322_479n)
    expect(info.gasLimit).toBe(8_000_000n)
    expect(info.priorityFeePerGas).toBe(1_000_000_000n)
    expect(info.maxFeePerGas).toBe(20_000_000_000n)
    expect(info.handlerContract).toBe(ROUTER)
    expect(info.handlerSelector).toBe('0x53edf33d')
    expect(info.owner).toBe(ROUTER)
    expect(info.emitter).toBe('0x3ecc694cef705358864a646142ac17a90e29e388')
    expect(info.topics).toHaveLength(4)
  })

  it('keeps the wildcard topics as zeros instead of dropping them', () => {
    const info = parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_MARKET_LISTENER))
    expect(info.topics.slice(1).every((t) => /^0x0{64}$/.test(t))).toBe(true)
  })

  it('reads the one-shot timer id and its indexed firing time', () => {
    const info = parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_ONE_SHOT))
    expect(info.id).toBe(16_334_648n)
    expect(info.topics[0]).toBe(TOPIC_SCHEDULE)
    expect(info.emitter).toBe('0x0000000000000000000000000000000000000100')
  })
})

describe('describeSubscription', () => {
  it('recognises the venue listener that wakes the router', () => {
    const line = describeSubscription(parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_MARKET_LISTENER)))
    expect(line).toBe(
      'market listener — calls 0x4fbb2d…9f2f.onEvent in the same block as every new DreamDEX market (8.0M gas)',
    )
  })

  it('reads a Schedule one-shot back as the wall-clock time it will fire', () => {
    const line = describeSubscription(parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_ONE_SHOT)))
    expect(line).toBe(
      'one-shot timer — calls 0x4fbb2d…9f2f.onEvent at 2026-09-06T01:30:05.000Z (8.0M gas)',
    )
  })

  it('describes a system tick without inventing a market for it', () => {
    const info = parseSubscriptionInfo(
      raw({ ...RAW_SUBSCRIPTION_ONE_SHOT, topics: [TOPIC_BLOCK_TICK, ...Array(3).fill(`0x${'0'.repeat(64)}`)] }),
    )
    expect(describeSubscription(info)).toContain('at the end of every block')
  })

  it('describes an unknown topic structurally rather than guessing', () => {
    const unknown = `0x${'ab'.repeat(32)}`
    const info = parseSubscriptionInfo(
      raw({
        ...RAW_SUBSCRIPTION_MARKET_LISTENER,
        topics: [unknown, ...Array(3).fill(`0x${'0'.repeat(64)}`)],
      }),
    )
    const line = describeSubscription(info)
    expect(line).toContain('log listener')
    expect(line).toContain('topic 0xabababab…')
    expect(line).not.toContain('DreamDEX')
  })

  it('calls a topic-less subscription a wildcard', () => {
    const info = parseSubscriptionInfo(
      raw({
        ...RAW_SUBSCRIPTION_MARKET_LISTENER,
        topics: Array(4).fill(`0x${'0'.repeat(64)}`),
        emitter: '0x0000000000000000000000000000000000000000',
      }),
    )
    expect(describeSubscription(info)).toContain('wildcard — calls')
    expect(describeSubscription(info)).toContain('every log on the chain')
  })

  it('names a non-default handler selector rather than pretending it is onEvent', () => {
    const info = parseSubscriptionInfo(
      raw({ ...RAW_SUBSCRIPTION_MARKET_LISTENER, handler_function_selector: '0xdeadbeef' }),
    )
    expect(describeSubscription(info)).toContain('[0xdeadbeef]')
    expect(describeSubscription(info)).not.toContain('.onEvent')
  })
})

describe('hasSafeGasLimit', () => {
  it('accepts the 8M the router provisions', () => {
    expect(SAFE_HANDLER_GAS_FLOOR).toBe(5_000_000n)
    expect(hasSafeGasLimit(parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_MARKET_LISTENER)))).toBe(true)
  })

  it('rejects the 2M limit that is billed and never runs', () => {
    const info = parseSubscriptionInfo(raw(RAW_SUBSCRIPTION_UNDERGASSED))
    expect(info.gasLimit).toBe(2_000_000n)
    expect(hasSafeGasLimit(info)).toBe(false)
  })
})
