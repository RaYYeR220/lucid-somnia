# Real and simulated

Where the line runs. This file is deliberately unflattering: it names what has actually executed
against the live venue, what has only ever executed against a mock, and what has never run against
the real thing at all.

## The rule

**Everything in `contracts/test/mocks/` is test-only and is never deployed.** No mock is imported by
anything under `contracts/src/`, none appears in `contracts/deploy.sh`, and none has an address in
`contracts/deployed.json`. They exist so that unit tests can force failure modes a live chain will
not produce on demand.

**On chain, nothing is simulated.** The router subscribes to DreamDEX's real `BinaryMarketsModule`.
The desk holds real faucet tUSDC. The committee is Somnia's real agent platform, answered by real
validators. The price is Somnia's real on-chain price-oracle agent. There is no shim, no wrapper, no
"demo mode" and no fixture path anywhere in the deployed code.

---

## The mocks, and what each one deliberately does not model

| file | stands in for | what it fakes, and why |
| --- | --- | --- |
| `MockPrecompile.sol` | The reactivity precompile at `0x0100` | `vm.etch`ed at the precompile address so `subscribe` returns an id instead of reverting. It does **not** simulate reactivity — the chain does that, and it was verified there. |
| `MockAgentPlatform.sol` | Somnia's agent platform `0x037B…6776` | Delivers callbacks synchronously. The live platform answers asynchronously from validator transactions, which no unit test can wait for. |
| `MockBinaryPool.sol` | A live `BinaryPool` | A CLOB that actually moves collateral, so the desk suite can measure what a window cost rather than trust what the desk claims it cost. |
| `MockPool.sol` | A live `BinaryPool` | Top of book set directly by the test. Etched onto the pool address carried by a real captured `MarketCreated` log. |
| `MockModule.sol` | `BinaryMarketsModule` | The settlement surface the desk touches, including a `finalizeMarket` that can be made to fail. |
| `MockBinaryModule.sol` | `BinaryMarketsModule` | Records every argument of `redeemFor`, because forwarding one call exactly is the relay's whole job. |
| `MockKeeperModule.sol` | The module's permissionless upkeep calls | Etched over `LucidTypes.MODULE`, which is a compile-time constant the keeper cannot be pointed away from. Records what was reached. |
| `MockKeeperMarket.sol` | One window's `BinaryMarket` | Each of the three reads is separately breakable, because every one is a precondition the keeper must not guess at. |
| `MockMarket.sol` | One window's `BinaryMarket` | Reduced to `payoutNumerators()`, since `winningOutcome()` was removed from the protocol and now reverts. |
| `MockOutcomeToken.sol` | `OutcomeToken6909` | Only the surface a desk touches. Reproduces that approval is per-operator, not per-id. |
| `MockCollateral.sol` | Shannon tUSDC | Six decimals, not eighteen — the trap that would silently mis-size every order. |
| `MockMarketCreator.sol` | A DreamDEX `MarketCreator` | Records the roll, and can be told to revert so the failure that motivated `LucidSeries` is actually covered. |
| `MockBrain.sol` | `LucidBrain` | Records requests and the native value paid, so the router's fee accounting is asserted against a number rather than a vibe. |
| `MockRouter.sol` | `LucidRouter` | Records `onVerdict`, and can be told to revert, to prove the brain survives a broken router. |
| `MockDesk.sol` | `LucidDesk` | Minimal clone implementation for factory tests. |
| `MockDeskForRouter.sol` | `LucidDesk` | A desk that can revert, run away, or refuse — the fan-out rules exist for exactly these. |
| `MockRouterForFactory.sol` | `LucidRouter` | Records `registerDesk`, so a new clone provably announces itself. |

Seventeen files. All of them are failure injection: a live venue will not politely return `false`
from `placeBinaryOrder`, revert a `triggerRoll`, or hand back a malformed committee answer on
request. That is what the mocks are for, and it is all they are for.

---

## What has actually executed on chain

| capability | status |
| --- | --- |
| Reactivity log subscription on DreamDEX's real `MarketCreated` | **live** |
| `Schedule` one-shots firing at a millisecond timestamp | **live** |
| Router decoding a real venue log, `MarketSeen`, `SettlementScheduled` | **live** |
| Desk `preCheck` selecting candidates inside the handler | **live** |
| Brain stage 1 — price fetched by a validator committee | **live** |
| Brain stage 2 — probability returned by a validator committee, per-validator receipts | **live** |
| Desk `onVerdict` → `PolicyLib.gate` → `Refused(reason)` | **live** |
| Factory `createDesk` producing a registered, armed ERC-1167 clone | **live** |
| tUSDC `faucet` called by a contract | **live** |
| `mintSet` called by a contract (no counterparty) | **live, but not by `LucidDesk`** — see below |
| `placeBinaryOrder(POST_ONLY)` resting in the live book, called by a contract | **live, but not by `LucidDesk`** |
| `cancelOrder` called by a contract | **live, but not by `LucidDesk`** |
| Registering our own operator, venue, `MarketCreator` and series, and having the venue's oracle resolve it | **live** |

The three rows marked "not by `LucidDesk`" were proven during day-0 reconnaissance by a throwaway
probe contract that is not part of this repository. They establish that the venue permits a
third-party contract to mint, rest and cancel — the architectural question that decides whether any
of this is possible. They do **not** establish that `LucidDesk`'s own order path works on chain.

---

## What has only ever run against a mock

Stated plainly, one line each.

- **No Lucid desk has ever placed an order on chain.** Every live decision so far has been a
  refusal — `Refused(LowEdge)` for all six desk decisions in the recorded 15-minute run. The
  `AiEdge` taker path and the `Maker` complete-set path are covered by the desk suite against
  `MockBinaryPool`, which moves real balances, and by nothing on chain.
- **No Lucid desk has ever settled or redeemed a position on chain,** because it has never held one.
  `onSettlement`, `finalizeMarket` and `redeem` from a desk are tested only against mocks.
- **`_ensureApprovals` has never run against the real venue.** It grants the pool an ERC-20
  allowance and the module and pool ERC-6909 operator rights, and it runs on a desk's first trade —
  which has not happened.
- **`LucidKeeper` has never performed venue upkeep on chain.** Its five success counters read zero
  and its failure counter does not: `counts()` returned `0 0 0 0 0 1362` at 2026-09-07 05:58 UTC —
  zero finalized, released, synced, poked and voided, against 1 362 attempts that reverted, across
  roughly 260 markets. That last number is failures, not work. The wiring is right and the calls are
  right — simulated from the keeper's own address against an expired, resolved market the indexer
  still lists as unfinalized, `finalizeMarket`, `syncSettlement` and `pokeOracle` all succeed — and
  the keeper has still never landed one. **Why is not established**, and no cause is offered here.
  Every upkeep path is therefore exercised only against `MockKeeperModule` and `MockKeeperMarket`.
  Read `counts()` yourself rather than taking a number from us.
- **`LucidRelay` has never relayed a redemption on chain.** `relayedCount()` and `failedCount()`
  both read zero, and no authorization has ever been submitted to it.
- **`LucidSeries` has never rolled a window on chain.** `status()` reports zero rolls today and no
  roll ever. The underlying capability — our own `MarketCreator` rolling a 300-second series that
  the venue's oracle then resolves — was proven live by calling `triggerRoll` from an ordinary
  account, not from `LucidSeries`. What is unproven is this contract's staleness detection and
  spend guards firing for real.
- **Copy-trading has never run on chain.** One desk exists on the live deployment, so
  `follow`, `followersOf` and `onLeaderTrade` are covered only by the factory and router suites.
- **The brain's latency measurement is not yet live.** `feedLatencyEma` and `verdictLatencyEma`
  read zero on the live brain, so `requiredSlack()` is currently sitting at its 90-second floor
  rather than at a measured value. The self-calibration is exercised in `LucidBrainStage.t.sol`.

---

## What has never run against the real thing at all

- **`redeemFor` with an EIP-1271 contract signature.** Untested on Shannon. `LucidRelay` recovers
  ECDSA signatures itself, so it serves externally owned accounts; whether the module accepts a
  contract-signed authorization is unknown and we have not tried it.
- **`placeBinaryOrderFor`.** Exists on the module, unwired in the SDK, no known caller. No code here
  depends on it.
- **`burnSet` and `mergeCompleteSet`.** The desk never merges a set back; it holds both legs to
  settlement.
- **Builder codes.** Every order this protocol places passes `builder = address(0)` and a zero
  builder fee. We have not registered a builder code and make no revenue claim.
- **`Continuous` series mode.** Implemented and unit-tested, never switched on — at roughly 34 SOMI
  an hour it is not a mode a testnet float survives.
- **Mainnet.** Nothing in this repository has ever run on Somnia mainnet. Chain 50312 only.

---

## The deployment can trail the source

`main` moves faster than the chain does. Between deploys, `contracts/deployed.json` describes the
build that is actually live, which may be behind the source you are reading. `contracts/deploy.sh`
writes a fresh `deployed.json` and `node scripts/sync-addresses.mjs` refreshes the address tables in
`README.md` and `JUDGES.md`.

The arbiter is `contracts/verify-onchain.sh`. It reads the live contracts, not the source, and a
feature that landed after the current deployment shows up there as a `FAIL` or `SKIP` on the check
that reads it — never as a silent pass.
