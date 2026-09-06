'use client'

import { cadence, contractPrice, count, countdown, strikePrice, utcTimestamp } from '@/lib/format'
import type { Market } from '@/lib/indexer'
import { useLiveWindows, useNow } from '@/lib/hooks'
import { KeyValue, StatusBadge } from '@/components/ui/Primitives'
import { Skeleton } from '@/components/ui/Value'
import { WindowStepper, type Step } from './WindowStepper'
import { IconClock } from '@/components/ui/Icon'

/**
 * What a desk that has not been handed a window yet is actually waiting for.
 *
 * A blank panel would be honest but useless. This shows the window the venue has open right now,
 * with the loop drawn in the state it is genuinely in — nothing has happened yet — so a reader
 * can see the shape of the thing before it fills. Every stage is marked as not-yet-run rather
 * than pre-emptively ticked.
 */
const WAITING_STEPS: Step[] = [
  {
    key: 'considered',
    title: 'Considered',
    detail: 'The router wakes the desk in the same block as the venue’s log.',
    state: 'unknown',
  },
  {
    key: 'price',
    title: 'Price Fetched',
    detail: 'A price-oracle committee returns a cross-exchange median.',
    state: 'unknown',
  },
  {
    key: 'ask',
    title: 'Committee Asked',
    detail: 'Part-way into the window, the inference committee is paid to answer.',
    state: 'unknown',
  },
  {
    key: 'verdict',
    title: 'Verdict Returned',
    detail: 'Per-validator receipts are filed, and the desk takes the median.',
    state: 'unknown',
  },
  {
    key: 'gate',
    title: 'Policy Gate',
    detail: 'The standing orders run in a fixed order; the first failure wins.',
    state: 'unknown',
  },
  {
    key: 'act',
    title: 'Executed or Refused',
    detail: 'Either an order, or a reason code and no trade.',
    state: 'unknown',
  },
  {
    key: 'settle',
    title: 'Settled',
    detail: 'A second timer books the profit or loss after expiry.',
    state: 'unknown',
  },
]

export function NextWindowWaiting({
  /** Only consider windows of these lengths — a desk's own mandate, when there is one. */
  cadences,
  assets,
  intro,
  level = 'h3',
}: {
  cadences?: readonly number[]
  assets?: readonly string[]
  intro: string
  /** The depth this panel sits at. See the note on `EmptyState`. */
  level?: 'h2' | 'h3'
}) {
  const Heading = level
  const live = useLiveWindows(40)
  const now = useNow()

  const next: Market | undefined =
    live.status === 'ready'
      ? live.data.find(
          (market) =>
            (cadences === undefined || cadences.includes(market.intervalSec)) &&
            (assets === undefined || assets.includes(market.asset)),
        )
      : undefined

  if (live.status === 'loading') {
    return (
      <div className="space-y-4">
        <div className="skeleton h-6 w-[28ch]" aria-hidden="true" />
        <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-7">
          {Array.from({ length: 7 }).map((_, index) => (
            <div key={index} className="rounded-r2 border border-line bg-[var(--slate-50)] p-3.5">
              <div className="skeleton h-3 w-[6ch]" aria-hidden="true" />
              <div className="skeleton mt-2 h-4 w-[10ch]" aria-hidden="true" />
            </div>
          ))}
        </div>
      </div>
    )
  }

  if (next === undefined) {
    // What the venue does have open right now. Saying "nothing matches" without saying what the
    // venue is actually running would leave a reader unable to tell a quiet venue from a bug.
    const openCadences =
      live.status === 'ready'
        ? [...new Set(live.data.map((market) => market.intervalSec))].sort((a, b) => a - b)
        : []

    return (
      <div className="rounded-r3 border border-dashed border-line2 bg-[var(--slate-50)] px-6 py-10 text-center">
        <span className="mx-auto mb-3 grid h-11 w-11 place-items-center rounded-r2 bg-surface text-ink5 ring-1 ring-line">
          <IconClock size={20} />
        </span>
        <Heading className="text-xl">
          {live.status === 'error'
            ? 'The window list could not be read'
            : cadences === undefined
              ? 'The venue has no window open'
              : 'Nothing open matches this mandate'}
        </Heading>
        <p className="mx-auto mt-2 max-w-[58ch] text-md text-ink3">
          {live.status === 'error' ? (
            <>
              The DreamDEX indexer could not be reached from your browser, so there is no window
              list to match against. The read runs on your machine — retry, or check the endpoint.
            </>
          ) : openCadences.length === 0 ? (
            <>
              Every binary market the venue lists has expired or has less than 90&nbsp;seconds left,
              which is the point at which a desk stops touching one.
            </>
          ) : cadences === undefined ? (
            <>The venue has {count(openCadences.length)} window lengths open, but none with more than
              90&nbsp;seconds left.</>
          ) : (
            <>
              The venue is running{' '}
              <b className="font-semibold text-ink">
                {openCadences.map((seconds) => cadence(seconds)).join(', ')}
              </b>{' '}
              windows right now. This mandate covers{' '}
              <b className="font-semibold text-ink">
                {cadences.map((seconds) => cadence(seconds)).join(', ')}
              </b>
              , so there is nothing for it to consider until one of those rolls.
            </>
          )}
        </p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-5 flex flex-wrap items-end gap-x-6 gap-y-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <Heading className="text-2xl tracking-tighter">Waiting for the next window</Heading>
            <StatusBadge tone="indigo" pulse>
              {next.asset || 'Unknown'} · {cadence(next.intervalSec)}
            </StatusBadge>
          </div>
          <p className="mt-1 max-w-[78ch] text-base text-ink4">{intro}</p>
        </div>

        <dl className="ml-auto flex flex-wrap gap-x-7 gap-y-3">
          <KeyValue label="Strike">
            {next.strike === 0n ? (
              <span
                className="text-ink4"
                title="The venue records the strike as zero until trading starts: this window settles against the price it opened at."
              >
                at open
              </span>
            ) : (
              strikePrice(next.strike)
            )}
          </KeyValue>
          <KeyValue label="Book">
            {next.lastPrice === null ? (
              <span
                className="inline-flex items-center gap-1.5 text-lg font-semibold text-ink4"
                title="No trade has ever printed on this book. That is the absence of a market price, not a market price of 50 %."
              >
                <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-ink5" />
                No quotes
              </span>
            ) : (
              contractPrice(next.lastPrice)
            )}
          </KeyValue>
          <KeyValue label="Closes in">
            {now === null ? (
              <Skeleton w="5ch" />
            ) : (
              <span className="tabular-nums" title={utcTimestamp(next.expiry)}>
                {countdown(next.expiry - now)}
              </span>
            )}
          </KeyValue>
        </dl>
      </div>

      <WindowStepper steps={WAITING_STEPS} />

      <p className="mt-3 text-sm text-ink5">
        Every stage above is drawn as not-yet-run, because it is. The loop fills in from the
        chain&rsquo;s own logs as the window progresses — nothing here is pre-empted.
      </p>
    </div>
  )
}
