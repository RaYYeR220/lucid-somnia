'use client'

import Link from 'next/link'
import { useMemo } from 'react'
import { isAddress } from 'viem'
import type { Address } from 'viem'
import { COLLATERAL_SYMBOL, EXPLORER_URL } from '@/lib/chain/config'
import { foldDeskWindows } from '@/lib/chain/logs'
import {
  blocksToDuration,
  cadence,
  contractPrice,
  count,
  shortAddress,
  shortId,
  signedUsdc,
  somiPrecise,
  usdc,
} from '@/lib/format'
import {
  assetFromKey,
  assetsFromMask,
  cadencesFromMask,
  orderKindName,
  policyWarnings,
  STRATEGY_BLURB,
  strategyName,
  type StrategyName,
} from '@/lib/protocol'
import { useBrainEvents, useBrainStatus, useDesk, useDeskEvents } from '@/lib/hooks'
import { Card, PageHead } from '@/components/ui/Card'
import {
  AddressLink,
  Badge,
  BlockLink,
  ButtonLink,
  EmptyState,
  ErrorState,
  Hairline,
  Stat,
} from '@/components/ui/Primitives'
import { IconExternal, IconInbox, IconNo, IconWarn } from '@/components/ui/Icon'
import { PolicyGateMeters } from '@/components/domain/PolicyGate'
import { RefusalRow } from '@/components/domain/Refusal'
import { ArmedState } from './ArmedState'
import { DeskWindowLoop } from './DeskWindowLoop'

/**
 * One desk, in full: what it is allowed to do, what it did with the last window it saw, what the
 * committee told it, which limit stopped it, and everything it refused.
 */
export function DeskDetail({ address }: { address: string }) {
  const valid = isAddress(address)
  const desk = useDesk(valid ? (address as Address) : undefined)
  const events = useDeskEvents(valid ? (address as Address) : undefined, 45)
  const brain = useBrainEvents(24)
  const brainStatus = useBrainStatus()

  const windows = useMemo(
    () => (events.status === 'ready' ? foldDeskWindows(events.data.events) : []),
    [events],
  )
  const latest = windows[0]

  const refusals = useMemo(
    () =>
      events.status === 'ready'
        ? events.data.events.filter((event) => event.name === 'Refused')
        : [],
    [events],
  )

  if (!valid) {
    return (
      <div className="wrap py-14">
        <h1 className="sr-only">Desk not found</h1>
        <EmptyState icon={<IconWarn size={20} />} title="That is not an address">
          <p>
            <code translate="no">{address}</code> is not a 20-byte hexadecimal address, so there is
            nothing to read. Pick a desk from the list instead.
          </p>
        </EmptyState>
        <div className="mt-6 text-center">
          <ButtonLink href="/desks/" tone="primary">
            Back to Every Desk
          </ButtonLink>
        </div>
      </div>
    )
  }

  return (
    <div className="wrap py-10 sm:py-14">
      <nav aria-label="Breadcrumb" className="mb-5 text-base text-ink4">
        <ol className="flex flex-wrap items-center gap-2">
          <li>
            <Link
              href="/desks/"
              className="rounded-[6px] underline decoration-line2 decoration-dotted underline-offset-[3px] hover:text-indigo"
            >
              Desks
            </Link>
          </li>
          <li aria-hidden="true">/</li>
          <li aria-current="page" translate="no">
            {shortAddress(address)}
          </li>
        </ol>
      </nav>

      {desk.status === 'error' ? (
        <>
          {/* The page keeps its h1 even when the read fails; an outline should not depend on
              whether the chain answered. */}
          <h1 className="sr-only">Desk {shortAddress(address)}</h1>
          <ErrorState
            level="h2"
            title="This desk did not load"
            error={desk.error}
            onRetry={desk.refetch}
          />
        </>
      ) : (
        <>
          <PageHead
            eyebrow="Desk"
            title={
              desk.status === 'ready' && desk.data.publishedName !== ''
                ? desk.data.publishedName.slice(0, 64)
                : shortAddress(address)
            }
            lede={
              <p>
                {desk.status === 'ready' ? (
                  <>
                    Owned by <AddressLink address={desk.data.owner} />, running{' '}
                    <b className="font-semibold text-ink">{strategyName(desk.data.policy.strategy)}</b>{' '}
                    on{' '}
                    {assetsFromMask(desk.data.policy.allowedAssets).join(' and ') || 'no asset'} at{' '}
                    {cadencesFromMask(desk.data.policy.allowedCadences).map(cadence).join(', ') ||
                      'no cadence'}
                    .{' '}
                    {STRATEGY_BLURB[strategyName(desk.data.policy.strategy) as StrategyName] ?? ''}
                  </>
                ) : (
                  <span className="skeleton inline-block h-[1.4em] w-full max-w-[46ch]" aria-hidden="true" />
                )}
              </p>
            }
            aside={
              <div className="flex flex-wrap items-center gap-2">
                {desk.status === 'ready' ? (
                  <ArmedState
                    policyArmed={desk.data.policy.armed}
                    armedAtRouter={desk.data.armedAtRouter}
                  />
                ) : null}
                <ButtonLink href={`${EXPLORER_URL}/address/${address}`} tone="default" size="sm" external>
                  On Explorer
                  <IconExternal size={13} />
                </ButtonLink>
              </div>
            }
          />

          {/* ── Money ─────────────────────────────────────────────────────── */}
          <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Card pad="sm">
              <Stat label={`${COLLATERAL_SYMBOL} of equity`} hint="Free collateral plus open notional, at cost." size="lg">
                {desk.status === 'ready' ? usdc(desk.data.equity) : <Bar w="7ch" />}
              </Stat>
            </Card>
            <Card pad="sm">
              <Stat label={`${COLLATERAL_SYMBOL} free in the desk`} hint="The ERC-20 balance the desk holds right now." size="lg">
                {desk.status === 'ready' ? usdc(desk.data.collateralBalance) : <Bar w="7ch" />}
              </Stat>
            </Card>
            <Card pad="sm">
              <Stat label="committed to open windows" hint="LucidDesk.openNotional()" size="lg">
                {desk.status === 'ready' ? usdc(desk.data.openNotional) : <Bar w="6ch" />}
              </Stat>
            </Card>
            <Card pad="sm">
              <Stat
                label="SOMI of gas credit at the router"
                hint="Pays for handler firings and committee deposits. Zero means the router skips this desk."
                size="lg"
                tone={desk.status === 'ready' && desk.data.gasCredit === 0n ? 'rose' : 'default'}
              >
                {desk.status === 'ready' ? somiPrecise(desk.data.gasCredit) : <Bar w="6ch" />}
              </Stat>
            </Card>
          </div>

          {desk.status === 'ready' && desk.data.gasCredit === 0n ? (
            <p className="mt-3 flex items-start gap-2 rounded-r2 border border-[#fde68a] bg-amber-soft px-4 py-3 text-base text-amber">
              <IconWarn size={16} className="mt-0.5 shrink-0" />
              <span>
                With no gas credit the router skips this desk by name —{' '}
                <code translate="no">Skipped(NO_CREDIT)</code> — rather than dropping it silently.
                It stays armed and stops hearing about windows until somebody tops it up.
              </span>
            </p>
          ) : null}

          {/* ── The live loop ─────────────────────────────────────────────── */}
          <section className="mt-10" aria-labelledby="loop">
            <h2 id="loop" className="text-3xl tracking-tighter">
              The window loop
            </h2>
            <p className="mt-2 max-w-[70ch] text-md text-ink3">
              What happened to the most recent window this desk saw, stage by stage. Every stage is
              a log the chain kept; a stage whose log falls outside the scanned range says so rather
              than reporting a result it does not have.
            </p>
            <div className="mt-5">
              {events.status === 'error' ? (
                <ErrorState title="The log scan did not complete" error={events.error} onRetry={events.refetch} />
              ) : (
                <DeskWindowLoop
                  window={latest}
                  brainScan={brain.status === 'ready' ? brain.data : undefined}
                  scanBlocks={events.status === 'ready' ? events.data.blocks : 0}
                  committeeThreshold={
                    brainStatus.status === 'ready' ? brainStatus.data.committeeThreshold : undefined
                  }
                  mandateCadences={
                    desk.status === 'ready' ? cadencesFromMask(desk.data.policy.allowedCadences) : undefined
                  }
                  mandateAssets={
                    desk.status === 'ready' ? assetsFromMask(desk.data.policy.allowedAssets) : undefined
                  }
                />
              )}
            </div>
          </section>

          {/* ── The gate ──────────────────────────────────────────────────── */}
          <section className="mt-12" aria-labelledby="gate">
            <h2 id="gate" className="text-3xl tracking-tighter">
              The policy gate
            </h2>
            <p className="mt-2 max-w-[70ch] text-md text-ink3">
              The model only ever proposes; these limits dispose. They run in a fixed order and the
              first failure wins, which is why a desk can be right about the market and still refuse.
            </p>
            <Card className="mt-5" pad="lg">
              {desk.status === 'ready' ? (
                <>
                  <PolicyGateMeters
                    policy={desk.data.policy}
                    state={desk.data.state}
                    equity={desk.data.equity}
                  />
                  {policyWarnings(desk.data.policy).length > 0 ? (
                    <>
                      <Hairline className="my-6" />
                      <h3 className="text-lg">What this mandate forbids</h3>
                      <ul className="mt-3 flex flex-col gap-2">
                        {policyWarnings(desk.data.policy).map((warning) => (
                          <li key={warning} className="flex items-start gap-2 text-base text-ink3">
                            <IconWarn size={15} className="mt-0.5 shrink-0 text-amber" />
                            <span>{warning}</span>
                          </li>
                        ))}
                      </ul>
                    </>
                  ) : null}
                </>
              ) : (
                <div className="grid gap-6 sm:grid-cols-2">
                  {Array.from({ length: 6 }).map((_, index) => (
                    <div key={index} className="space-y-2">
                      <div className="skeleton h-4 w-2/3" aria-hidden="true" />
                      <div className="skeleton h-2.5 w-full" aria-hidden="true" />
                      <div className="skeleton h-3 w-1/2" aria-hidden="true" />
                    </div>
                  ))}
                </div>
              )}
            </Card>
          </section>

          {/* ── Refusals ──────────────────────────────────────────────────── */}
          <section className="mt-12" aria-labelledby="refusal-log">
            <div className="flex flex-wrap items-end justify-between gap-3">
              <div>
                <h2 id="refusal-log" className="text-3xl tracking-tighter">
                  The refusal log
                </h2>
                <p className="mt-2 max-w-[70ch] text-md text-ink3">
                  Every decision not to trade, by name, with the two numbers that produced it. This
                  is not an error list — it is the record of the mandate being enforced.
                </p>
              </div>
              {events.status === 'ready' ? (
                <Badge tone="slate">
                  last {blocksToDuration(events.data.blocks)} of blocks
                </Badge>
              ) : null}
            </div>

            <div className="mt-5">
              {events.status === 'loading' ? (
                <Card pad="none">
                  {Array.from({ length: 3 }).map((_, index) => (
                    <div key={index} className="border-b border-line px-4 py-4 last:border-0">
                      <div className="skeleton h-4 w-1/3" aria-hidden="true" />
                      <div className="skeleton mt-2 h-3 w-2/3" aria-hidden="true" />
                    </div>
                  ))}
                </Card>
              ) : events.status === 'error' ? (
                <ErrorState
                  title="The refusal log could not be read"
                  error={events.error}
                  onRetry={events.refetch}
                />
              ) : refusals.length === 0 ? (
                <EmptyState icon={<IconNo size={20} />} title="No refusal in the scanned range">
                  <p>
                    This desk refused nothing across the last {blocksToDuration(events.data.blocks)}{' '}
                    of blocks. Either it traded, or the router never handed it a window in that span.
                  </p>
                </EmptyState>
              ) : (
                <Card pad="none" className="overflow-hidden">
                  <ul className="divide-y divide-line">
                    {refusals.slice(0, 20).map((refusal) =>
                      refusal.name === 'Refused' ? (
                        <li key={`${refusal.transactionHash}-${refusal.logIndex}`}>
                          <RefusalRow
                            code={refusal.reason}
                            probUpBps={refusal.probUpBps}
                            pBookBps={refusal.pBookBps}
                            meta={
                              <span className="whitespace-nowrap">
                                window <span translate="no">{shortId(refusal.marketId)}</span>
                                <br />
                                block <BlockLink block={refusal.blockNumber} />
                              </span>
                            }
                          />
                        </li>
                      ) : null,
                    )}
                  </ul>
                  {refusals.length > 20 ? (
                    <p className="border-t border-line bg-[var(--slate-50)] px-4 py-3 text-base text-ink4">
                      Showing the 20 most recent of {count(refusals.length)} refusals in the scanned
                      range. The rest are on the explorer, under this desk&rsquo;s{' '}
                      <code translate="no">Refused</code> logs.
                    </p>
                  ) : null}
                </Card>
              )}
            </div>
          </section>

          {/* ── Positions ─────────────────────────────────────────────────── */}
          <section className="mt-12" aria-labelledby="positions">
            <h2 id="positions" className="text-3xl tracking-tighter">
              Positions
            </h2>
            <p className="mt-2 max-w-[70ch] text-md text-ink3">
              The desk stores a cost basis per window and a count of open ones, with no key array —
              so a position table is reconstructed from the desk&rsquo;s own{' '}
              <code translate="no">Executed</code> and <code translate="no">Settled</code> logs
              rather than enumerated on chain.
            </p>
            <div className="mt-5">
              <PositionsTable
                windows={windows}
                openMarkets={desk.status === 'ready' ? desk.data.state.openMarkets : undefined}
                scanBlocks={events.status === 'ready' ? events.data.blocks : undefined}
                loading={events.status === 'loading'}
              />
            </div>
          </section>
        </>
      )}
    </div>
  )
}

function PositionsTable({
  windows,
  openMarkets,
  scanBlocks,
  loading,
}: {
  windows: readonly ReturnType<typeof foldDeskWindows>[number][]
  openMarkets: number | undefined
  scanBlocks: number | undefined
  loading: boolean
}) {
  const traded = windows.filter((window) => window.executions.length > 0 || window.settlement !== undefined)

  if (loading) {
    return (
      <Card pad="none">
        {Array.from({ length: 3 }).map((_, index) => (
          <div key={index} className="border-b border-line px-4 py-4 last:border-0">
            <div className="skeleton h-4 w-1/2" aria-hidden="true" />
          </div>
        ))}
      </Card>
    )
  }

  if (traded.length === 0) {
    return (
      <EmptyState icon={<IconInbox size={20} />} title="No fills yet">
          <p>
            The desk currently reports{' '}
            <b className="font-semibold text-ink">
              {openMarkets === undefined ? 'an unknown number of' : count(openMarkets)}
            </b>{' '}
            open window{openMarkets === 1 ? '' : 's'}, and no{' '}
            <code translate="no">Executed</code> log appears in the last{' '}
            {scanBlocks === undefined ? 'scanned range' : blocksToDuration(scanBlocks)} of blocks.
            On this venue that is the expected state, not a broken one: most windows have no book at
            all, and a desk running <b className="font-semibold text-ink">AiEdge</b> refuses rather
            than trading against a price nobody quoted.
        </p>
      </EmptyState>
    )
  }

  return (
    <div
      tabIndex={0}
      role="region"
      aria-label="Positions, scrollable horizontally"
      className="overflow-x-auto rounded-r4 border border-line bg-surface shadow-card"
    >
      <table className="w-full min-w-[720px] border-collapse text-md">
        <caption className="sr-only">
          Every window this desk traded in the scanned block range, with its fills and its settled
          profit or loss.
        </caption>
        <thead>
          <tr className="border-b border-line">
            {['Window', 'Asset', 'Fills', 'Settled', 'Block'].map((label, index) => (
              <th
                key={label}
                scope="col"
                className={`whitespace-nowrap px-4 py-3 text-xs font-bold uppercase tracking-wide text-ink5 ${index > 1 ? 'text-right' : 'text-left'}`}
              >
                {label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {traded.map((window) => (
            <tr key={window.marketId} className="border-b border-line last:border-0">
              <th scope="row" className="px-4 py-3.5 text-left font-semibold text-ink" translate="no">
                {shortId(window.marketId)}
              </th>
              <td className="px-4 py-3.5">
                {window.assetKey === '0x' ? (
                  <span className="text-ink5">—</span>
                ) : (
                  <>
                    {assetFromKey(window.assetKey)} · {cadence(window.intervalSec)}
                  </>
                )}
              </td>
              <td className="px-4 py-3.5 text-right">
                {window.executions.length === 0 ? (
                  <span className="text-ink5">—</span>
                ) : (
                  <ul className="flex flex-col items-end gap-1">
                    {window.executions.map((execution) => (
                      <li key={execution.orderId.toString()} className="tabular-nums">
                        <Badge tone="indigo">{orderKindName(execution.kind)}</Badge>{' '}
                        {count(Number(execution.quantity))} @ {contractPrice(execution.price)}
                      </li>
                    ))}
                  </ul>
                )}
              </td>
              <td className="px-4 py-3.5 text-right tabular-nums font-semibold">
                {window.settlement === undefined ? (
                  <Badge tone="amber">open</Badge>
                ) : (
                  <span className={window.settlement.pnl >= 0n ? 'text-emerald' : 'text-rose'}>
                    {signedUsdc(window.settlement.pnl)}
                  </span>
                )}
              </td>
              <td className="px-4 py-3.5 text-right">
                <BlockLink block={window.lastBlock} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Bar({ w }: { w: string }) {
  return <span className="skeleton inline-block h-[1em] align-middle" style={{ width: w }} aria-hidden="true" />
}
