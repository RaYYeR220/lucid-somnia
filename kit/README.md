# lucid-kit

Typed TypeScript client and `lucid` CLI for **Lucid** — a protocol of autonomous trading desks for
DreamDEX Event Contracts on Somnia Shannon (chain `50312`).

A Lucid desk is a contract, not a process. Somnia validators do the three jobs that normally need a
server: an on-chain **reactivity** subscription wakes the router in the same block as every new
market, Somnia's native **on-chain agent committee** returns the directional verdict, and the
protocol's own settlement one-shots close the position. There is no backend to run, and this
package does not add one — it is a library plus a command you type. Nothing here starts a daemon,
holds a key on disk, or keeps working only while your laptop is open.

## Install

```bash
npm install lucid-kit
```

Node >= 20. `viem@^2` is the only runtime dependency.

From this repo:

```bash
cd kit
npm install
npm run build
npm test
```

## Quickstart

Every read works with **no key at all**:

```bash
npx lucid status                    # addresses, router balance vs the 32-SOMI floor, subscriptions
npx lucid markets                   # live windows a desk could still enter
npx lucid markets --settled         # finalized windows, newest first
npx lucid subs 0x4FBB…9f2f          # decode an address's reactivity subscriptions
npx lucid watch 0x4EED…14f5         # stream a desk's decision trail
npx lucid desk status 0x4EED…14f5   # owner, mandate, equity, armed-at-router flag
```

The four commands that sign read `PRIVATE_KEY` from the environment, and only from there:

```bash
export PRIVATE_KEY=0x…

lucid desk create --assets BTC,ETH --cadences 300,900 --max-stake 5 --daily-budget 50
lucid desk fund  <desk> --faucet --amount 500 --gas 0.5
lucid desk arm   <desk> --on
lucid desk policy <desk> --min-edge 500          # edits one field, keeps the rest
```

`lucid --help` prints the full flag list.

As a library:

```ts
import {
  createLucidPublicClient,
  describePolicy,
  encodePolicy,
  liveMarkets,
  readDesk,
  watchDesk,
} from 'lucid-kit'

const client = createLucidPublicClient()

const windows = await liveMarkets({ assets: ['BTC'], cadences: [300] })
const desk = await readDesk(client, '0x4EEDABCC63448b11Bd689EEA4021E7e5B2B314f5')
console.log(describePolicy(desk.policy).join('\n'))

const stop = watchDesk(desk.address, (event) => console.log(event.name, event.args))
// stop() when you are done — the subscription is yours, not the library's.
```

## API surface

| module | what it gives you |
|---|---|
| `addresses` | Shannon chain config, the live Lucid addresses, tUSDC, the DreamDEX module, the 32-SOMI subscription floor, explorer links. |
| `abis` | `routerAbi`, `deskAbi`, `factoryAbi`, `brainAbi`, `collateralAbi` — all `as const`, so viem infers argument and return types. |
| `client` | `createLucidPublicClient`, `createLucidWalletClient`, `accountFromEnv`, `clientsFromEnv`. |
| `policy` | The `Policy` mirror type, `assetsMask`, `cadencesMask`, `encodePolicy`, `decodePolicy`, `describePolicy`. |
| `desk` | `createDesk`, `setPolicy`, `arm`, `deposit`, `withdraw`, `fundFromFaucet`, `topUpGasCredit`, `readDesk`, `armedDesks`, `allDesks`. |
| `markets` | `liveMarkets`, `settledMarkets`, plus the pure `selectLiveMarkets` / `filterLiveMarkets` filter. |
| `events` | `decodeDeskLog`, `decodeRouterLog`, `decodeLucidLog`, `watchDesk`, `formatEvent`, `refusalName`. |
| `subscriptions` | `getSubscriptions`, `getSubscriptionInfo`, `getOwnedSubscriptions`, `describeSubscription`, `hasSafeGasLimit`. |
| `protocol` | `readProtocolStatus` — one call for "is the protocol actually alive right now". |

### Policy

A mandate is a bitmask over the assets and window lengths `PolicyLib` recognises, plus the caps
the contract enforces on every trade.

```ts
import { assetsMask, cadencesMask, encodePolicy, describePolicy } from 'lucid-kit'

assetsMask(['BTC', 'ETH'])   // 0b11   — bit 0 BTC, bit 1 ETH
cadencesMask([300, 900])     // 0b110  — bit 0 60s, 1 300s, 2 900s, 3 3600s

const policy = encodePolicy({
  maxStakePerWindow: '5',
  dailyBudget: '50',
  maxOpenMarkets: 2,
  maxDrawdownBps: 2000,
  maxConsecutiveLosses: 3,
  minEdgeBps: 300,
  assets: ['BTC', 'ETH'],
  cadences: [300, 900],
  strategy: 'AiEdge',
  armed: false,
})

describePolicy(policy).forEach((line) => console.log(line))
```

> **The 60-second bit is accepted but will never trade.** The protocol refuses any window with
> less than 90 seconds left (`LucidTypes.MIN_WINDOW_SLACK`), because the public indexer lags and
> `placeBinaryOrder` on a stale row reverts `OrderAlreadyExpired`. A 60-second window can never
> clear that bar, so a desk that allows bit 0 will *consider* those markets and refuse every one
> with `WindowTooShort`. The bit is kept rather than silently dropped so the mask stays a faithful
> mirror of on-chain state; `describePolicy` says so out loud.

### Markets

`liveMarkets` filters on `expiry > now + minSecondsLeft` (default 90) rather than trusting
`clobStatus`, and `settledMarkets` filters on `"Finalized"` — the venue's only terminal status.
Both traps are confirmed live and both have tests.

### Events

`watchDesk` streams the five desk events (`Considered`, `VerdictReceived`, `Executed`, `Refused`,
`Settled`) and the three router events that explain them (`MarketSeen`, `SettlementScheduled`,
`Skipped`), and returns an unsubscribe function you own. `refusalName(code)` maps the `Refusal`
enum to its label, and `REFUSAL_REASONS` gives each one a sentence — the refusal is a first-class
product surface here, not an error path.

### Subscriptions

`getSubscriptions` / `getSubscriptionInfo` wrap Somnia's `somnia_reactivityGetSubscriptions` and
`somnia_reactivityGetSubscriptionInfo` RPC methods, typed through viem's `rpcSchema`.
`describeSubscription(info)` turns four opaque topics into one sentence:

```
market listener — calls 0x4fbb2d…9f2f.onEvent in the same block as every new DreamDEX market (8.0M gas)
one-shot timer — calls 0x4fbb2d…9f2f.onEvent at 2026-09-06T01:30:05.000Z (8.0M gas)
```

These helpers are read-only by design. Creating a subscription requires the *calling contract* to
hold 32 SOMI, so it is a contract's job — which is exactly why Lucid has one shared router rather
than a subscription per desk.

## Regenerating the ABIs

`src/abis.ts` and `src/deployed.ts` are written by a script, never by hand:

```bash
cd contracts && forge build
cd ../kit && npm run sync-abis
```

The script reads `contracts/out/<Name>.sol/<Name>.json` (the `abi` field) and
`contracts/deployed.json`, strips Foundry's `internalType` noise, and emits one ABI entry per line
so the diff is reviewable. Point it elsewhere with `node scripts/sync-abis.mjs --contracts <dir>`.

## Tests

```bash
npm test
```

74 tests, no network. Covered: policy mask round-trips over every subset, `encodePolicy` /
`decodePolicy` round-trips and its range validation, `describePolicy` output including the
untradeable-cadence warning, event decoding against **logs captured verbatim from Shannon**
(`MarketSeen`, `Skipped(NO_CREDIT)`, `SettlementScheduled`) plus hand-assembled desk logs, the
full `Refusal` enum mapping, subscription decoding against a captured RPC payload, and the
`liveMarkets` filter against a fixture indexer response carrying the real traps — a stale
`Trading` row past its expiry, a row inside the 90-second slack, and the exact boundary.

## License

MIT.
