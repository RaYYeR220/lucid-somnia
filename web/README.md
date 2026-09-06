# Lucid — web

The front end for Lucid: autonomous trading desks for DreamDEX Event Contracts on Somnia.

It is a static export with **no backend of any kind** — no API routes, no server actions, no
database, no cache. Every number on every page is fetched by the reader's own browser, from the
Somnia Shannon RPC and the public DreamDEX indexer. That is not a limitation to work around; it is
the product's central claim, and `/system` is the page that demonstrates it rather than asserting
it. If this app ever grew a server, the claim would stop being true.

```bash
npm install
npm run dev      # syncs the chain data, then next dev on :3000
npm run build    # syncs, type-checks and writes a static site to out/
npm run verify   # calls every read this app makes against the live deployment
npm start        # serves out/ locally
```

## Routes

| route | what it is |
| --- | --- |
| `/` | The product surface: hero, the live window loop, the bento grid, how a window runs, the refusal band. |
| `/desks` | Every desk the factory has created — equity, today's spend against the daily budget, open windows, loss streak, gas credit, armed state. Sortable, and the sort lives in the URL. |
| `/desks/[address]` | One desk in full: the window loop as a stepper, the committee vote with per-validator receipts, the policy gate as meters, the refusal log, and positions. |
| `/windows` | Live and recently settled Event Contract windows, joined to what a Lucid desk did about each. |
| `/system` | The machine room: reactivity subscriptions in plain English, the router's float against the 32 SOMI floor, committee sizes and quote, and the keeper, relay and failover watcher. |

`/desks/[address]` is pre-rendered for every desk the factory knows about at build time. A desk
created after the build is picked up client-side by the not-found route, which reads the address
out of the path and renders the same view against the live chain.

## Where the data comes from

| source | what it answers |
| --- | --- |
| `https://api.infra.testnet.somnia.network` | Every contract read, every log page, and the reactivity precompile's `somnia_reactivityGetSubscriptions` / `…GetSubscriptionInfo`. |
| `https://dev.smk.somnia.host/v1/graphql` | The venue's market rows: strike, cadence, expiry, last price, settlement. |

Two constraints shape the whole data layer:

- **`eth_getLogs` is capped at 1 000 blocks per query** and Shannon lands a block roughly every
  100 ms. History is therefore read by paging backwards in 950-block windows, in concurrent
  batches, and every result carries the span it covered — the interface says *"in the last 47 min
  of blocks"* rather than implying it looked at everything. There is no unbounded range anywhere.
- **`clobStatus` lags the chain.** Live windows are filtered on wall-clock `expiry` instead, with
  the protocol's own 90-second slack. The venue's terminal status is `Finalized` and never
  `Resolved`; a filter written against the wrong one returns an empty set forever.

## The honesty rules this app is built to

1. **Never render a number the chain did not give you.** Every value goes through one component
   with exactly three outcomes: a skeleton while loading, an em dash that can say why when the read
   failed, and the value itself — including when the value is zero, which is a fact and says so.
2. **An empty book is not a price of 50 %.** The protocol carries `type(uint16).max` for
   "no side of the book quoted". It renders as *no quotes*, visibly different from a real 0.50.
3. **Refusals are the product, not an error state.** Every `Refused` is shown by its on-chain enum
   name with a one-line explanation, coloured by family, and a desk with a full refusal log and no
   fills is the interface working.
4. **Say what was not looked at.** A stage whose log falls outside the scanned block range reports
   *unknown* — a dashed step with a sentence — never a failure and never a guess.

## Contract data is synced, never typed by hand

`src/lib/chain/synced.ts` is written by `scripts/sync-chain.mjs` from the Foundry artifacts in
`../contracts/out` (falling back to the already-synced `../kit/src/abis.ts` when there is no
build) and from `../contracts/deployed.json`. `npm run build` runs the sync first, so a redeploy or
a contract change is picked up by rebuilding and nothing else. Do not edit the synced file.

`npm run verify` calls every read the app makes against the live deployment and reports which
answered. Run it after a sync: a function name the deployment does not have shows up there rather
than as an em dash on somebody's screen.

## Design

The visual system — the type scale, the Plus Jakarta Sans pairing, the indigo → violet accent on a
slate ground, the coloured card shadows, the four radii, the bento rhythm — comes from the chosen
direction and is not reinterpreted here. Two deliberate departures, both for contrast: the two
quietest greys are one step darker than the comp (`#94a3b8` measured 2.45:1 on this ground and
carries text people are meant to read), and the emerald and cyan badge colours are deepened so
their text clears 4.5:1 on their own tints. Both are documented in `globals.css` where they live.

The design commits to a single light look. There is no dark mode, so every colour is painted
explicitly rather than inherited from the host.
