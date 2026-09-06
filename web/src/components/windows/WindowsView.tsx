'use client'

import Link from 'next/link'
import { useMemo } from 'react'
import { clsx } from '@/lib/clsx'
import { MIN_WINDOW_SLACK_SECONDS, deployed, EXPLORER_URL } from '@/lib/chain/config'
import { foldDeskWindows, type DeskWindow } from '@/lib/chain/logs'
import { winnerLabel, type Market } from '@/lib/indexer'
import {
  cadence,
  contractPrice,
  count,
  countdownOrDays,
  probability,
  relativeTime,
  shortAddress,
  shortId,
  signedUsdc,
  strikePrice,
  utcTimestamp,
} from '@/lib/format'
import { assetsFromMask, cadencesFromMask, orderKindName } from '@/lib/protocol'
import { useDeskTable, useLiveWindows, useNow, useProtocolActivity, useSettledWindows } from '@/lib/hooks'
import { useUrlState } from '@/lib/urlState'
import { Card, PageHead } from '@/components/ui/Card'
import {
  Badge,
  ButtonLink,
  EmptyState,
  ErrorState,
  Stat,
  StatusBadge,
} from '@/components/ui/Primitives'
import { BookProbability } from '@/components/domain/WindowStepper'
import { RefusalBadge, refusalExplanation } from '@/components/domain/Refusal'
import { IconClock, IconExternal } from '@/components/ui/Icon'

type Tab = 'live' | 'settled'
const TABS: readonly Tab[] = ['live', 'settled']

/**
 * Event Contract windows, and what Lucid did about each.
 *
 * The venue's rows come from the public DreamDEX indexer; the verdict comes from the desks' own
 * logs. The two are joined on the market id, so a window with no Lucid row simply has none — the
 * table says "not seen in the scanned range" rather than inventing a decision.
 */
export function WindowsView() {
  const [tab, setTab] = useUrlState<Tab>('tab', 'live', TABS)
  const live = useLiveWindows(40)
  const settled = useSettledWindows(24)
  const activity = useProtocolActivity()
  const desks = useDeskTable()
  const now = useNow()

  // Every window any desk touched in the scanned range, keyed by market id.
  const deskWindows = useMemo(() => {
    const map = new Map<string, { desk: string; window: DeskWindow }>()
    if (activity.status !== 'ready') return map
    for (const desk of activity.data.desks) {
      for (const window of foldDeskWindows(desk.scan.events)) {
        map.set(window.marketId.toLowerCase(), { desk: desk.address, window })
      }
    }
    return map
  }, [activity])

  // What every mandate on the chain, taken together, is even allowed to consider. A window
  // outside it was never going to be traded, and saying so is more useful than "not seen".
  const mandate = useMemo(() => {
    if (desks.status !== 'ready') return undefined
    const cadences = new Set<number>()
    const assets = new Set<string>()
    for (const desk of desks.data) {
      for (const c of cadencesFromMask(desk.policy.allowedCadences)) cadences.add(c)
      for (const a of assetsFromMask(desk.policy.allowedAssets)) assets.add(a)
    }
    return { cadences, assets }
  }, [desks])

  const source = tab === 'live' ? live : settled
  const rows = source.status === 'ready' ? source.data : []

  return (
    <div className="wrap py-10 sm:py-14">
      <PageHead
        eyebrow="Windows"
        title="Event Contract windows, and what Lucid did"
        lede={
          <p>
            Short-dated binary markets: will the asset close at or above the price its window opened
            at. The venue rolls them continuously; Lucid sees each one in the block it is created
            and decides once, part-way through.
          </p>
        }
        aside={
          <ButtonLink href={`${EXPLORER_URL}/address/${deployed.router}`} tone="default" external>
            Router on Explorer
            <IconExternal size={13} />
          </ButtonLink>
        }
      />

      <div className="mt-8 grid gap-4 sm:grid-cols-3">
        <Card pad="sm">
          <Stat label="windows open now, across every cadence" hint="From the DreamDEX indexer, filtered on wall-clock expiry." size="lg">
            {live.status === 'ready' ? count(live.data.length) : <Bar w="3ch" />}
          </Stat>
        </Card>
        <Card pad="sm">
          <Stat label="of those a Lucid desk decided on" hint="Joined to the desks’ own logs over the scanned block range." size="lg">
            {live.status === 'ready' && activity.status === 'ready' ? (
              count(live.data.filter((m) => deskWindows.has(m.marketId.toLowerCase())).length)
            ) : (
              <Bar w="3ch" />
            )}
          </Stat>
        </Card>
        <Card pad="sm">
          <Stat label="seconds a window must have left before a desk will touch it" hint="LucidTypes.MIN_WINDOW_SLACK — the indexer lags, and a stale row reverts OrderAlreadyExpired." size="lg">
            {MIN_WINDOW_SLACK_SECONDS}
          </Stat>
        </Card>
      </div>

      {/*
        These are links, not tabs. The choice is deep-linked in the query string, so it should
        survive a middle-click and a Cmd-click like any other address in the product — which the
        ARIA tab pattern, with its roving focus and arrow keys, would take away for no gain here.
      */}
      <nav aria-label="Which windows to show" className="mt-8">
        <ul className="flex flex-wrap items-center gap-2">
          <li>
            <TabLink current={tab} value="live" onSelect={setTab}>
              Live
              {live.status === 'ready' ? <Badge tone="slate">{count(live.data.length)}</Badge> : null}
            </TabLink>
          </li>
          <li>
            <TabLink current={tab} value="settled" onSelect={setTab}>
              Recently Settled
              {settled.status === 'ready' ? <Badge tone="slate">{count(settled.data.length)}</Badge> : null}
            </TabLink>
          </li>
        </ul>
      </nav>

      <section
        aria-label={tab === 'live' ? 'Live windows' : 'Recently settled windows'}
        aria-busy={source.status === 'loading'}
        aria-live="polite"
        className="mt-4"
      >
        {source.status === 'loading' ? (
          <TableSkeleton />
        ) : source.status === 'error' ? (
          <ErrorState
            level="h2"
            title="The DreamDEX indexer did not answer"
            error={source.error}
            onRetry={source.refetch}
          />
        ) : rows.length === 0 ? (
          <EmptyState
            level="h2"
            icon={<IconClock size={20} />}
            title={tab === 'live' ? 'No window is open right now' : 'No settled window came back'}
          >
              <p>
                {tab === 'live' ? (
                  <>
                    Every binary market the indexer knows about has either expired or has less than{' '}
                    {MIN_WINDOW_SLACK_SECONDS} seconds left — which is the point at which a desk
                    stops touching one, because the indexer lags the chain and a stale row makes the
                    venue revert.
                  </>
                ) : (
                  <>
                    Nothing matched the venue&rsquo;s terminal status. That status is{' '}
                    <code translate="no">Finalized</code> and never{' '}
                    <code translate="no">Resolved</code>; a filter written against the wrong one
                    returns an empty set forever.
                  </>
                )}
            </p>
          </EmptyState>
        ) : (
          <WindowsTable rows={rows} deskWindows={deskWindows} mandate={mandate} now={now} tab={tab} />
        )}
      </section>

      <p className="mt-4 max-w-[80ch] text-base text-ink4">
        Live windows are filtered on wall-clock expiry rather than on{' '}
        <code translate="no">clobStatus</code>: the indexer lags the chain by seconds to minutes, so
        a row that still says <code translate="no">Trading</code> is routinely already past its
        expiry. Wall-clock time is the only signal here that does not lie.
      </p>
    </div>
  )
}

function TabLink({
  current,
  value,
  onSelect,
  children,
}: {
  current: Tab
  value: Tab
  onSelect: (next: Tab) => void
  children: React.ReactNode
}) {
  const active = current === value
  return (
    <a
      href={value === 'live' ? '/windows/' : `/windows/?tab=${value}`}
      aria-current={active ? 'page' : undefined}
      onClick={(event) => {
        // Let the browser handle a modified click, so Cmd/Ctrl and middle-click still open a tab.
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
        event.preventDefault()
        onSelect(value)
      }}
      className={clsx(
        'inline-flex h-10 items-center gap-2 rounded-[10px] border px-4 text-md font-semibold transition-colors [touch-action:manipulation]',
        active
          ? 'border-transparent bg-ink text-white'
          : 'border-line bg-surface text-ink3 shadow-btn hover:border-line2 hover:text-ink',
      )}
    >
      {children}
    </a>
  )
}

interface MandateCoverage {
  cadences: Set<number>
  assets: Set<string>
}

function WindowsTable({
  rows,
  deskWindows,
  mandate,
  now,
  tab,
}: {
  rows: readonly Market[]
  deskWindows: Map<string, { desk: string; window: DeskWindow }>
  mandate: MandateCoverage | undefined
  now: number | null
  tab: Tab
}) {
  return (
    <div
      tabIndex={0}
      role="region"
      aria-label="Windows, scrollable horizontally"
      className="overflow-x-auto rounded-r4 border border-line bg-surface shadow-card"
    >
      <table className="w-full min-w-[900px] border-collapse text-md">
        <caption className="sr-only">
          {tab === 'live'
            ? 'Every open Event Contract window, with its strike, cadence, expiry countdown and what Lucid did about it.'
            : 'Recently settled Event Contract windows, with the side that paid out and what Lucid did about each.'}
        </caption>
        <thead>
          <tr className="border-b border-line">
            <th scope="col" className="px-4 py-3 text-left text-xs font-bold uppercase tracking-wide text-ink5">
              Window
            </th>
            <th scope="col" className="px-4 py-3 text-left text-xs font-bold uppercase tracking-wide text-ink5">
              Cadence
            </th>
            <th scope="col" className="px-4 py-3 text-right text-xs font-bold uppercase tracking-wide text-ink5">
              <span title="The oracle price the window settles against. Zero until trading starts on windows that settle at their opening price.">
                Strike
              </span>
            </th>
            <th scope="col" className="px-4 py-3 text-right text-xs font-bold uppercase tracking-wide text-ink5">
              <span title="The last traded price on the book, in probability terms. Most of these books never trade.">
                Book
              </span>
            </th>
            <th scope="col" className="px-4 py-3 text-right text-xs font-bold uppercase tracking-wide text-ink5">
              {tab === 'live' ? 'Closes in' : 'Outcome'}
            </th>
            <th scope="col" className="px-4 py-3 text-left text-xs font-bold uppercase tracking-wide text-ink5">
              What Lucid did
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((market) => {
            const seen = deskWindows.get(market.marketId.toLowerCase())
            return (
              <tr key={market.marketId} className="border-b border-line last:border-0 transition-colors hover:bg-[var(--slate-50)]">
                <th scope="row" className="px-4 py-3.5 text-left font-normal">
                  <span className="block font-semibold text-ink" translate="no">
                    {market.asset || '—'} · {shortId(market.marketId)}
                  </span>
                  <span
                    className="block max-w-[42ch] truncate text-sm text-ink5"
                    title={market.question !== '' ? market.question : undefined}
                  >
                    {market.question !== '' ? market.question : 'No question recorded'}
                  </span>
                </th>
                <td className="px-4 py-3.5">
                  <Badge tone={market.intervalSec < MIN_WINDOW_SLACK_SECONDS ? 'amber' : 'slate'}>
                    {cadence(market.intervalSec)}
                  </Badge>
                  {market.intervalSec > 0 && market.intervalSec < MIN_WINDOW_SLACK_SECONDS ? (
                    <span className="ml-2 text-sm text-amber" title="Shorter than the 90-second minimum slack, so no desk can ever trade it.">
                      untradeable
                    </span>
                  ) : null}
                </td>
                <td className="px-4 py-3.5 text-right tabular-nums">
                  {market.strike === 0n ? (
                    <span
                      className="text-ink4"
                      title="The venue records the strike as zero until trading starts: this window settles against the price it opened at."
                    >
                      at open
                    </span>
                  ) : (
                    strikePrice(market.strike)
                  )}
                </td>
                <td className="px-4 py-3.5 text-right tabular-nums">
                  {market.lastPrice === null ? (
                    <span
                      className="inline-flex items-center gap-1.5 font-semibold text-ink4"
                      title="No trade has ever printed on this book. That is the absence of a market price, not a market price of 50 %."
                    >
                      <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-ink5" />
                      No quotes
                    </span>
                  ) : (
                    contractPrice(market.lastPrice)
                  )}
                </td>
                <td className="px-4 py-3.5 text-right">
                  {tab === 'live' ? (
                    now === null ? (
                      <span className="skeleton inline-block h-[1em] w-[6ch] align-middle" aria-hidden="true" />
                    ) : (
                      <span className="tabular-nums font-semibold" title={utcTimestamp(market.expiry)}>
                        {countdownOrDays(market.expiry - now)}
                      </span>
                    )
                  ) : (
                    <OutcomeBadge market={market} now={now} />
                  )}
                </td>
                <td className="px-4 py-3.5">
                  <LucidVerdict
                    seen={seen}
                    covered={
                      mandate === undefined
                        ? undefined
                        : mandate.cadences.has(market.intervalSec) && mandate.assets.has(market.asset)
                    }
                  />
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function OutcomeBadge({ market, now }: { market: Market; now: number | null }) {
  const label = winnerLabel(market)
  return (
    <span className="inline-flex flex-col items-end gap-1">
      <Badge tone={label === 'UP' ? 'emerald' : label === 'DOWN' ? 'rose' : label === 'VOID' ? 'amber' : 'slate'}>
        {label}
      </Badge>
      {market.resolvedAtTimestamp !== null && now !== null ? (
        <span className="text-sm text-ink5" title={utcTimestamp(market.resolvedAtTimestamp)}>
          {relativeTime(market.resolvedAtTimestamp, now)}
        </span>
      ) : null}
    </span>
  )
}

/** What a Lucid desk did about one window, or an honest statement that it did not see it. */
function LucidVerdict({
  seen,
  covered,
}: {
  seen: { desk: string; window: DeskWindow } | undefined
  /** Whether any mandate on the chain even allows this asset and cadence. */
  covered: boolean | undefined
}) {
  if (seen === undefined) {
    if (covered === false) {
      return (
        <span
          className="inline-flex items-center gap-2 text-base text-ink5"
          title="No desk’s mandate allows this asset and window length, so the router’s pre-filter declines it before any committee is paid."
        >
          <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-line2" />
          Outside every mandate
        </span>
      )
    }
    return (
      <span
        className="inline-flex items-center gap-2 text-base text-ink5"
        title="No Lucid desk emitted anything for this window inside the scanned block range. eth_getLogs is capped at 1 000 blocks per query, so history here is bounded."
      >
        <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-line2" />
        Not seen in the scanned range
      </span>
    )
  }

  const { desk, window } = seen

  return (
    <div className="flex flex-col gap-1.5">
      {window.refusal !== undefined ? (
        <span className="flex flex-wrap items-center gap-2">
          <RefusalBadge code={window.refusal.reason} />
          <span className="text-sm text-ink4" title={refusalExplanation(window.refusal.reason)}>
            committee {probability(window.refusal.probUpBps)}% · book{' '}
            <BookProbability pBookBps={window.refusal.pBookBps} className="text-sm" />
          </span>
        </span>
      ) : window.executions.length > 0 ? (
        <span className="flex flex-wrap items-center gap-2">
          <StatusBadge tone="emerald">Traded</StatusBadge>
          <span className="text-sm text-ink4 tabular-nums">
            {window.executions
              .map((e) => `${orderKindName(e.kind)} ${count(Number(e.quantity))} @ ${contractPrice(e.price)}`)
              .join(' · ')}
          </span>
        </span>
      ) : window.considered ? (
        <StatusBadge tone="indigo">Considered</StatusBadge>
      ) : (
        <StatusBadge tone="slate">Seen</StatusBadge>
      )}

      <span className="text-sm text-ink5">
        desk{' '}
        <Link
          href={`/desks/${desk}/`}
          className="rounded-[6px] underline decoration-line2 decoration-dotted underline-offset-[3px] hover:text-indigo"
        >
          {shortAddress(desk)}
        </Link>
        {window.settlement !== undefined ? (
          <>
            {' '}
            · settled{' '}
            <span className={window.settlement.pnl >= 0n ? 'text-emerald' : 'text-rose'}>
              {signedUsdc(window.settlement.pnl)}
            </span>
          </>
        ) : null}
      </span>
    </div>
  )
}

function Bar({ w }: { w: string }) {
  return <span className="skeleton inline-block h-[1em] align-middle" style={{ width: w }} aria-hidden="true" />
}

function TableSkeleton() {
  return (
    <div className="overflow-hidden rounded-r4 border border-line bg-surface shadow-card">
      {Array.from({ length: 6 }).map((_, index) => (
        <div key={index} className="flex items-center gap-6 border-b border-line px-4 py-4 last:border-0">
          <div className="skeleton h-4 w-1/4" aria-hidden="true" />
          <div className="skeleton h-4 w-1/12" aria-hidden="true" />
          <div className="skeleton h-4 w-1/12" aria-hidden="true" />
          <div className="skeleton h-4 w-1/12" aria-hidden="true" />
          <div className="skeleton h-4 w-1/6" aria-hidden="true" />
        </div>
      ))}
    </div>
  )
}

