import { describe, expect, it } from 'vitest'
import {
  ASSETS,
  CADENCES,
  PolicyError,
  Strategy,
  assetBit,
  assetKey,
  assetsFromMask,
  assetsMask,
  cadenceBit,
  cadencesFromMask,
  cadencesMask,
  decodePolicy,
  describePolicy,
  encodePolicy,
  fromCollateral,
  strategyName,
  toCollateral,
} from '../src/policy.js'
import type { Policy, PolicyDraft } from '../src/policy.js'

const BASE: PolicyDraft = {
  maxStakePerWindow: '25',
  dailyBudget: '250',
  maxOpenMarkets: 3,
  maxDrawdownBps: 2_000,
  maxConsecutiveLosses: 4,
  minEdgeBps: 300,
  assets: ['BTC', 'ETH'],
  cadences: [300, 900],
  strategy: 'AiEdge',
  armed: true,
}

describe('asset and cadence bits', () => {
  it('matches the bit order PolicyLib assigns', () => {
    expect(assetBit('BTC')).toBe(1)
    expect(assetBit('ETH')).toBe(2)
    expect(cadenceBit(60)).toBe(1)
    expect(cadenceBit(300)).toBe(2)
    expect(cadenceBit(900)).toBe(4)
    expect(cadenceBit(3600)).toBe(8)
  })

  it('returns 0 for anything a desk cannot trade, the way the contract does', () => {
    expect(assetBit('SOL')).toBe(0)
    expect(assetBit('btc')).toBe(0)
    expect(cadenceBit(120)).toBe(0)
    expect(cadenceBit(86_400)).toBe(0)
  })

  it('hashes asset symbols the way the venue log carries them', () => {
    // keccak256("BTC") / keccak256("ETH") — the values LucidTypes.ASSET_BTC/ETH hold.
    expect(assetKey('BTC')).toBe(
      '0xe98e2830be1a7e4156d656a7505e65d08c67660dc618072422e9c78053c261e9',
    )
    expect(assetKey('ETH')).toBe(
      '0xaaaebeba3810b1e6b70781f14b2d72c1cb89c0b2b320c43bb67ff79f562f5ff4',
    )
  })
})

describe('masks', () => {
  it('builds the documented examples', () => {
    expect(assetsMask(['BTC', 'ETH'])).toBe(0b11)
    expect(cadencesMask([300, 900])).toBe(0b110)
  })

  it('is order- and duplicate-insensitive', () => {
    expect(assetsMask(['ETH', 'BTC'])).toBe(assetsMask(['BTC', 'ETH']))
    expect(cadencesMask([900, 300, 900])).toBe(cadencesMask([300, 900]))
  })

  it('round-trips every subset of assets', () => {
    for (let mask = 0; mask < 1 << ASSETS.length; mask++) {
      expect(assetsMask(assetsFromMask(mask))).toBe(mask)
    }
  })

  it('round-trips every subset of cadences', () => {
    for (let mask = 0; mask < 1 << CADENCES.length; mask++) {
      expect(cadencesMask(cadencesFromMask(mask))).toBe(mask)
    }
  })

  it('ignores bits above the ones PolicyLib defines rather than inventing entries', () => {
    expect(assetsFromMask(0xff)).toEqual(['BTC', 'ETH'])
    expect(cadencesFromMask(0xffff)).toEqual([60, 300, 900, 3600])
  })

  it('refuses an asset or cadence no desk could ever trade', () => {
    expect(() => assetsMask(['DOGE'])).toThrow(PolicyError)
    expect(() => cadencesMask([120])).toThrow(/expected one of 60, 300, 900, 3600/)
  })
})

describe('collateral scaling', () => {
  it('uses the six decimals tUSDC actually has', () => {
    expect(toCollateral('25')).toBe(25_000_000n)
    expect(toCollateral('0.000001')).toBe(1n)
    expect(fromCollateral(25_000_000n)).toBe('25')
    expect(fromCollateral(1n)).toBe('0.000001')
  })
})

describe('encodePolicy / decodePolicy', () => {
  it('produces the exact struct the contract expects', () => {
    expect(encodePolicy(BASE)).toEqual({
      maxStakePerWindow: 25_000_000n,
      dailyBudget: 250_000_000n,
      maxOpenMarkets: 3,
      maxDrawdownBps: 2_000,
      maxConsecutiveLosses: 4,
      minEdgeBps: 300,
      allowedAssets: 0b11,
      allowedCadences: 0b110,
      strategy: Strategy.AiEdge,
      armed: true,
    } satisfies Policy)
  })

  it('round-trips a draft through the struct and back', () => {
    expect(decodePolicy(encodePolicy(BASE))).toEqual(BASE)
  })

  it('round-trips every cadence and asset combination', () => {
    for (let assets = 1; assets < 1 << ASSETS.length; assets++) {
      for (let cadences = 1; cadences < 1 << CADENCES.length; cadences++) {
        const draft: PolicyDraft = {
          ...BASE,
          assets: assetsFromMask(assets),
          cadences: cadencesFromMask(cadences),
        }
        expect(decodePolicy(encodePolicy(draft))).toEqual(draft)
      }
    }
  })

  it('round-trips both strategies', () => {
    for (const strategy of ['AiEdge', 'Maker'] as const) {
      const draft: PolicyDraft = { ...BASE, strategy }
      expect(decodePolicy(encodePolicy(draft)).strategy).toBe(strategy)
    }
  })

  it('rejects fields that would silently truncate on chain', () => {
    expect(() => encodePolicy({ ...BASE, maxConsecutiveLosses: 256 })).toThrow(/0\.\.255/)
    expect(() => encodePolicy({ ...BASE, maxOpenMarkets: 70_000 })).toThrow(/0\.\.65535/)
    expect(() => encodePolicy({ ...BASE, minEdgeBps: 2.5 })).toThrow(PolicyError)
    expect(() => encodePolicy({ ...BASE, maxDrawdownBps: -1 })).toThrow(PolicyError)
    expect(() => encodePolicy({ ...BASE, maxStakePerWindow: '20000000000000' })).toThrow(/uint64/)
  })

  it('rejects a strategy the contract has no enum value for', () => {
    const bad = { ...BASE, strategy: 'Martingale' } as unknown as PolicyDraft
    expect(() => encodePolicy(bad)).toThrow(/unknown strategy/)
    expect(() => decodePolicy({ ...encodePolicy(BASE), strategy: 7 })).toThrow(/unknown strategy id/)
  })

  it('names strategies without throwing, for log rendering', () => {
    expect(strategyName(0)).toBe('AiEdge')
    expect(strategyName(1)).toBe('Maker')
    expect(strategyName(9)).toBe('Unknown(9)')
  })
})

describe('describePolicy', () => {
  const lines = (policy: Policy) => describePolicy(policy).join('\n')

  it('states the mandate in the terms the owner set it', () => {
    const text = lines(encodePolicy(BASE))
    expect(text).toContain('Strategy        AiEdge')
    expect(text).toContain('Armed           yes')
    expect(text).toContain('Assets          BTC, ETH (mask 0b11)')
    expect(text).toContain('Cadences        5m, 15m (mask 0b110)')
    expect(text).toContain('Max per window  25 tUSDC')
    expect(text).toContain('Daily budget    250 tUSDC')
    expect(text).toContain('Min edge        3.00% vs the book')
    expect(text).toContain('Max drawdown    20.00% below the high-water mark')
    expect(text).toContain('Loss streak     halts after 4 consecutive losses')
  })

  it('adds no notes to a mandate that can actually trade', () => {
    expect(describePolicy(encodePolicy(BASE)).some((l) => l.startsWith('Note'))).toBe(false)
  })

  it('warns that a 60-second window can never clear the 90-second slack', () => {
    const text = lines(encodePolicy({ ...BASE, cadences: [60, 300] }))
    expect(text).toContain('1m can never clear the 90s minimum slack')
    expect(text).toContain('WindowTooShort')
    expect(text).not.toContain('this desk will never trade')
  })

  it('says so outright when every allowed cadence is untradeable', () => {
    const text = lines(encodePolicy({ ...BASE, cadences: [60] }))
    expect(text).toContain('every allowed cadence is untradeable; this desk will never trade')
  })

  it('names each way a mandate can silently forbid everything', () => {
    expect(lines(encodePolicy({ ...BASE, armed: false }))).toContain('refused with NotArmed')
    expect(lines(encodePolicy({ ...BASE, assets: [] }))).toContain('refused with AssetNotAllowed')
    expect(lines(encodePolicy({ ...BASE, cadences: [] }))).toContain(
      'refused with CadenceNotAllowed',
    )
    expect(lines(encodePolicy({ ...BASE, maxStakePerWindow: '0' }))).toContain(
      'refuses with CapExceeded',
    )
    expect(lines(encodePolicy({ ...BASE, maxOpenMarkets: 0 }))).toContain(
      'refused with MaxOpenReached',
    )
    expect(lines(encodePolicy({ ...BASE, maxConsecutiveLosses: 0 }))).toContain(
      'halted from its first window',
    )
  })

  it('flags a daily budget that binds before the per-window cap', () => {
    expect(lines(encodePolicy({ ...BASE, dailyBudget: '10' }))).toContain(
      'daily budget is below the per-window cap',
    )
  })

  it('reads a 100% drawdown tolerance as never halting rather than as a huge number', () => {
    expect(lines(encodePolicy({ ...BASE, maxDrawdownBps: 10_000 }))).toContain(
      'Max drawdown    never halts',
    )
  })
})
