import type { Address, Hex } from 'viem'
import { addresses } from '../src/addresses.js'
import type { MarketRow } from '../src/markets.js'

/**
 * Test fixtures. Nothing here touches the network.
 *
 * The router logs and the subscription payload were captured verbatim from Shannon 50312 on
 * 2026-09-06 — they are what the chain and the node actually emitted, not what we think they
 * emit. The desk logs are assembled here by hand from the ABI layout, because the desk had not
 * yet traded when they were needed; assembling them by hand rather than with viem's encoder
 * keeps the decoder under test from being compared against itself.
 */

/** One 32-byte ABI word. */
function word(value: bigint | number): string {
  const raw = BigInt(value)
  // Two's complement, so a negative int256 encodes the way the EVM writes it.
  const unsigned = raw < 0n ? (1n << 256n) + raw : raw
  return unsigned.toString(16).padStart(64, '0')
}

function data(...words: (bigint | number | string)[]): Hex {
  return `0x${words.map((w) => (typeof w === 'string' ? w : word(w))).join('')}`
}

export const DESK: Address = '0x4eedabcc63448b11bd689eea4021e7e5b2b314f5'

/**
 * Taken from the deployment rather than pinned to the address these logs were captured under.
 *
 * `decodeLucidLog` tells a router log from a desk log by comparing the emitter against the router
 * the kit is configured for, so a fixture carrying a *different* router is not a stale detail —
 * it decodes as a desk log and the test fails. That is exactly what happened when the router was
 * redeployed and this constant stayed behind: a shipped suite with a red test in it, for a decoder
 * that was working correctly. The address the logs were really emitted by was
 * 0x4fbb2dbc34b74e8837e1bd2dc83d8dcdfd859f2f, and nothing in them depends on it.
 */
export const ROUTER: Address = addresses.router

export const MARKET_ID: Hex = '0x0000000000000000000000000000000000000000000000000000000000014a51'

export const ASSET_KEY_BTC = 'e98e2830be1a7e4156d656a7505e65d08c67660dc618072422e9c78053c261e9'
export const ASSET_KEY_ETH = 'aaaebeba3810b1e6b70781f14b2d72c1cb89c0b2b320c43bb67ff79f562f5ff4'

const TOPIC = {
  considered: '0x36432ebb1af643d4f812d4fd6495fdc10ab209e90460c1e6bf5eb2a0815d5597',
  verdictReceived: '0x0580b597dbc7e573c09e9c5190a1399f87ddb2bf4f188c32ad474ea2253f3e85',
  executed: '0x1391207d1b2a59a5c53612408e271b6e3c7eb95462ef2eb7390a0073da13e38d',
  refused: '0x999c9be6bbe198776b27ef6c9444e6e0b23bf048b407e652e00b66e45c56963f',
  settled: '0xa4ebf99370872aed22053201140e3c96c77de3206d7b6644e571c526b806678e',
  armedSet: '0x244aff177546aea9aab73410cdfd140032116ac52a30bf49be237b09aab08668',
} as const

export interface FixtureLog {
  address: Address
  topics: [Hex, ...Hex[]]
  data: Hex
  blockNumber: bigint
  transactionHash: Hex
  logIndex: number
}

// ── captured live from Shannon 50312 ────────────────────────────────────────

/** `MarketSeen(marketId, 300, keccak("ETH"))` — the router waking on a real 5-minute window. */
export const LOG_MARKET_SEEN: FixtureLog = {
  address: ROUTER,
  topics: ['0x0e727b29d5a92ce6b52d5d648180ad787d9ffb30e4dd9c6a77ef224d965c06bf', MARKET_ID],
  data: `0x${word(300)}${ASSET_KEY_ETH}`,
  blockNumber: 480847572n,
  transactionHash: '0xc2bfdcf744e8d4814fdfa2bd7d81e297e06ada48b214c61f44aae1c6158f01cf',
  logIndex: 116,
}

/** `Skipped(desk, marketId, "NO_CREDIT")` — a real refusal to spend a desk's gas it does not have. */
export const LOG_SKIPPED: FixtureLog = {
  address: ROUTER,
  topics: [
    '0xeaf491dfc4b1f77e12b61c1be0801def7747367434476fbd1bfadb5fe63a6b4e',
    '0x0000000000000000000000004eedabcc63448b11bd689eea4021e7e5b2b314f5',
    MARKET_ID,
  ],
  data: '0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000094e4f5f4352454449540000000000000000000000000000000000000000000000',
  blockNumber: 480847572n,
  transactionHash: '0xc2bfdcf744e8d4814fdfa2bd7d81e297e06ada48b214c61f44aae1c6158f01cf',
  logIndex: 117,
}

/** `SettlementScheduled(marketId, 1788658205000, 16336857)` — the expiry one-shot being armed. */
export const LOG_SETTLEMENT_SCHEDULED: FixtureLog = {
  address: ROUTER,
  topics: ['0xb84ae5069bee26c51d534481a562e19425aefa69c416643dc1e32ee80d8f518c', MARKET_ID],
  data: '0x000000000000000000000000000000000000000000000000000001a0745641480000000000000000000000000000000000000000000000000000000000f947d9',
  blockNumber: 480847572n,
  transactionHash: '0xc2bfdcf744e8d4814fdfa2bd7d81e297e06ada48b214c61f44aae1c6158f01cf',
  logIndex: 119,
}

/** `Debited(desk, marketId, 0.25 STT)` — a router event the kit deliberately does not model. */
export const LOG_UNMODELLED_ROUTER: FixtureLog = {
  address: ROUTER,
  topics: [
    '0x47c8ad82beab27cecb94806b17fa905b8edba8ff5d15b32a3877b677d44f0ebd',
    '0x0000000000000000000000004eedabcc63448b11bd689eea4021e7e5b2b314f5',
    '0x0000000000000000000000000000000000000000000000000000000000014a2c',
  ],
  data: '0x00000000000000000000000000000000000000000000000003782dace9d90000',
  blockNumber: 480838575n,
  transactionHash: '0xbabe164dae34542037a305af750c1ef2a88e694b78b7202970450321ddf818c0',
  logIndex: 114,
}

/** `ArmedSet(true)` on the live desk — a desk event outside the five the kit streams. */
export const LOG_ARMED_SET: FixtureLog = {
  address: DESK,
  topics: [TOPIC.armedSet],
  data: `0x${word(1)}`,
  blockNumber: 480809484n,
  transactionHash: '0x8763fd9b8c7c108377b35a34e5f2c44af0b9eb6ebebbb01cdd0da8c54337486a',
  logIndex: 0,
}

// ── assembled by hand from the ABI layout ───────────────────────────────────

export const LOG_CONSIDERED: FixtureLog = {
  address: DESK,
  topics: [TOPIC.considered, MARKET_ID],
  data: data(300, ASSET_KEY_BTC),
  blockNumber: 480847580n,
  transactionHash: '0x1111111111111111111111111111111111111111111111111111111111111111',
  logIndex: 0,
}

/** Committee 64.00% up, book 51.00%, 3 of 3 validators answered. */
export const LOG_VERDICT_RECEIVED: FixtureLog = {
  address: DESK,
  topics: [TOPIC.verdictReceived, MARKET_ID],
  data: data(6_400, 5_100, 3),
  blockNumber: 480847581n,
  transactionHash: '0x2222222222222222222222222222222222222222222222222222222222222222',
  logIndex: 1,
}

/** BUY_YES, 10 contracts at 0.52, order id 42. */
export const LOG_EXECUTED: FixtureLog = {
  address: DESK,
  topics: [TOPIC.executed, MARKET_ID],
  data: data(0, 520_000, 10_000_000, 42),
  blockNumber: 480847582n,
  transactionHash: '0x3333333333333333333333333333333333333333333333333333333333333333',
  logIndex: 2,
}

/** LowEdge (11): the committee at 51.20% and the book at 51.00% agree, so there is no trade. */
export const LOG_REFUSED: FixtureLog = {
  address: DESK,
  topics: [TOPIC.refused, MARKET_ID],
  data: data(11, 5_120, 5_100),
  blockNumber: 480847583n,
  transactionHash: '0x4444444444444444444444444444444444444444444444444444444444444444',
  logIndex: 3,
}

/** A losing window: -1.25 tUSDC, leaving 4 998.75 tUSDC of equity. */
export const LOG_SETTLED: FixtureLog = {
  address: DESK,
  topics: [TOPIC.settled, MARKET_ID],
  data: data(-1_250_000, 4_998_750_000),
  blockNumber: 480847900n,
  transactionHash: '0x5555555555555555555555555555555555555555555555555555555555555555',
  logIndex: 4,
}

// ── reactivity RPC ──────────────────────────────────────────────────────────

/**
 * Verbatim `somnia_reactivityGetSubscriptionInfo` result for the router's venue listener,
 * captured live. Note the snake_case keys and hex quantities — this is the shape the parser
 * has to survive.
 */
export const RAW_SUBSCRIPTION_MARKET_LISTENER = {
  id: '0xf90faf',
  topics: [
    '0xb5ec75cdb7dbcd28a5f50d152d8833334525a902ef5332ebc19bcf5c0011f8cd',
    '0x0000000000000000000000000000000000000000000000000000000000000000',
    '0x0000000000000000000000000000000000000000000000000000000000000000',
    '0x0000000000000000000000000000000000000000000000000000000000000000',
  ],
  origin: '0x0000000000000000000000000000000000000000',
  caller: '0x0000000000000000000000000000000000000000',
  emitter: '0x3ecc694cef705358864a646142ac17a90e29e388',
  owner: ROUTER,
  handler_contract_address: ROUTER,
  handler_function_selector: '0x53edf33d',
  gas_limit: '0x7a1200',
  priority_fee_per_gas: '0x3b9aca00',
  max_fee_per_gas: '0x4a817c800',
} as const

/** A `Schedule` one-shot, with the firing time carried in the indexed second topic. */
export const RAW_SUBSCRIPTION_ONE_SHOT = {
  id: '0xf93f38',
  topics: [
    '0x67aa3d752967d87d8944b9c7adf73172518777fa4703f336edee81f0736d8987',
    // 1788658205000 ms = 2026-09-06T01:30:05.000Z, the same instant the router scheduled above
    '0x000000000000000000000000000000000000000000000000000001a074564148',
    '0x0000000000000000000000000000000000000000000000000000000000000000',
    '0x0000000000000000000000000000000000000000000000000000000000000000',
  ],
  origin: '0x0000000000000000000000000000000000000000',
  caller: '0x0000000000000000000000000000000000000000',
  emitter: '0x0000000000000000000000000000000000000100',
  owner: ROUTER,
  handler_contract_address: ROUTER,
  handler_function_selector: '0x53edf33d',
  gas_limit: '0x7a1200',
  priority_fee_per_gas: '0x3b9aca00',
  max_fee_per_gas: '0x4a817c800',
} as const

/** The same listener, provisioned at the 2 M limit that is billed and never runs. */
export const RAW_SUBSCRIPTION_UNDERGASSED = {
  ...RAW_SUBSCRIPTION_MARKET_LISTENER,
  id: '0xf90fb0',
  gas_limit: '0x1e8480',
} as const

// ── indexer ─────────────────────────────────────────────────────────────────

/** `now` the market fixtures are written against: 2026-09-06T01:00:00Z. */
export const FIXTURE_NOW = 1_788_656_400

function marketRow(overrides: Partial<MarketRow> & Pick<MarketRow, 'marketId'>): MarketRow {
  return {
    asset: 'BTC',
    question: 'BTC closes at or above its opening price',
    strike: '7993610',
    tradingStart: String(FIXTURE_NOW - 300),
    expiry: String(FIXTURE_NOW + 300),
    intervalSec: '300',
    clobStatus: 'Trading',
    marketAddress: '0xa5e5a3b25440afb3076cc68eb53cb937ed724d68',
    poolAddress: '0xf278e5aa1ac7f4159f7598d862fad58e818d3a63',
    yesTokenId: '6537039046934163345356679846399820715145975992558718473756133724001280',
    noTokenId: '6537039046934163345356679846399820715145975992558718473756133724001281',
    nonce: '20',
    venueId: '0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f',
    lastPrice: '550000',
    finalized: false,
    voided: false,
    winningOutcome: null,
    payoutNumerators: null,
    payoutDenominator: null,
    resolvedAtTimestamp: null,
    ...overrides,
  }
}

/**
 * A response shaped like the ones the live indexer returns, with the traps built in.
 *
 * Rows 3 and 4 are the important ones: both still say `clobStatus: "Trading"` while their
 * expiry has already passed or is inside the 90-second slack. That is not a contrived case —
 * it is exactly what the lagging indexer serves, and trading on it reverts `OrderAlreadyExpired`.
 */
export const INDEXER_LIVE_RESPONSE: MarketRow[] = [
  // 5-minute BTC window with 5 minutes left — tradeable.
  marketRow({ marketId: '0x14a44', expiry: String(FIXTURE_NOW + 300) }),
  // 1-hour ETH window with 37 minutes left — tradeable.
  marketRow({
    marketId: '0x14a16',
    asset: 'ETH',
    intervalSec: '3600',
    expiry: String(FIXTURE_NOW + 2235),
  }),
  // Stale row: the indexer still says Trading, but the window closed two minutes ago.
  marketRow({ marketId: '0x14a3f', expiry: String(FIXTURE_NOW - 120) }),
  // Inside the 90-second slack: 45 seconds left is not enough to place an order safely.
  marketRow({ marketId: '0x14a43', expiry: String(FIXTURE_NOW + 45) }),
  // Exactly at the slack boundary — the cut is strict, so this one is out.
  marketRow({ marketId: '0x14a45', expiry: String(FIXTURE_NOW + 90) }),
  // A 60-second window: allowed by the cadence mask, but no desk can ever clear the slack on it.
  marketRow({ marketId: '0x14a4e', intervalSec: '60', expiry: String(FIXTURE_NOW + 55) }),
  // An asset no desk has a mandate for.
  marketRow({ marketId: '0x14b01', asset: 'SOL', expiry: String(FIXTURE_NOW + 600) }),
  // Already finalized, despite plenty of nominal time left.
  marketRow({
    marketId: '0x14a2c',
    expiry: String(FIXTURE_NOW + 400),
    finalized: true,
    clobStatus: 'Finalized',
    winningOutcome: 0,
  }),
  // Voided by the oracle.
  marketRow({ marketId: '0x14a2d', expiry: String(FIXTURE_NOW + 500), voided: true }),
]

/** A finalized-market response, terminal status included exactly as the indexer spells it. */
export const INDEXER_SETTLED_RESPONSE: MarketRow[] = [
  marketRow({
    marketId: '0x14a49',
    asset: 'ETH',
    intervalSec: '60',
    clobStatus: 'Finalized',
    finalized: true,
    expiry: String(FIXTURE_NOW - 240),
    winningOutcome: 1,
    payoutNumerators: ['0', '10000000'],
    payoutDenominator: '10000000',
    resolvedAtTimestamp: String(FIXTURE_NOW - 240),
    lastPrice: null,
  }),
  marketRow({
    marketId: '0x14a47',
    intervalSec: '60',
    clobStatus: 'Finalized',
    finalized: true,
    expiry: String(FIXTURE_NOW - 300),
    winningOutcome: 0,
    payoutNumerators: ['10000000', '0'],
    payoutDenominator: '10000000',
    resolvedAtTimestamp: String(FIXTURE_NOW - 300),
    lastPrice: null,
  }),
  marketRow({
    marketId: '0x14a3a',
    clobStatus: 'Finalized',
    finalized: true,
    voided: true,
    expiry: String(FIXTURE_NOW - 900),
    winningOutcome: null,
    payoutNumerators: ['5000000', '5000000'],
    payoutDenominator: '10000000',
    resolvedAtTimestamp: String(FIXTURE_NOW - 900),
    lastPrice: null,
  }),
]
