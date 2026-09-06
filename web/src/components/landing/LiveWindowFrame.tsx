'use client'

import Link from 'next/link'
import { useMemo } from 'react'
import { foldDeskWindows } from '@/lib/chain/logs'
import { fetchWindowsById } from '@/lib/indexer'
import {
  blocksToDuration,
  cadence,
  contractPrice,
  count,
  countdown,
  probability,
  relativeTime,
  shortAddress,
  shortId,
  strikePrice,
  utcTimestamp,
} from '@/lib/format'
import { assetFromKey, orderKindName } from '@/lib/protocol'
import { useBrainEvents, useNow, useProtocolActivity } from '@/lib/hooks'
import { useQuery } from '@/lib/query'
import { BlockLink, KeyValue, StatusBadge } from '@/components/ui/Primitives'
import { Dash, Skeleton } from '@/components/ui/Value'
import { BookProbability, WindowStepper, buildSteps } from '@/components/domain/WindowStepper'
import { NextWindowWaiting } from '@/components/domain/NextWindow'
import { RefusalBadge, refusalExplanation } from '@/components/domain/Refusal'
import { IconCheck, IconNo } from '@/components/ui/Icon'

/**
 * The product frame: the most recent window a desk actually decided on, drawn as the app draws it.
 *
 * This is not a screenshot and not a mock. It is the newest `Considered → … → Refused` trail in
 * the scanned block range, joined to the venue's own row for that window. When the range holds no
 * decision at all — which is the truthful state on a quiet testnet — the frame says so instead of
 * showing a plausible one.
 */
export function LiveWindowFrame() {
  const activity = useProtocolActivity()
  const brain = useBrainEvents(16)
  const now = useNow()

  const latest = useMemo(() => {
    if (activity.status !== 'ready') return undefined
    for (const desk of activity.data.desks) {
      const windows = foldDeskWindows(desk.scan.events)
      const window = windows[0]
      if (window !== undefined) return { desk: desk.address, window }
    }
    return undefined
  }, [activity])

  const marketId = latest?.window.marketId
  const market = useQuery(
    marketId === undefined ? null : `window:${marketId}`,
    async () => (await fetchWindowsById([marketId as string]))[0] ?? null,
    { refreshMs: 30_000 },
  )

  const steps = useMemo(
    () => (latest === undefined ? [] : buildSteps(latest.window, brain.status === 'ready' ? brain.data.events : [])),
    [latest, brain],
  )

  return (
    <div className="mt-12 overflow-hidden rounded-r4 border border-line bg-surface shadow-frame">
      <div className="flex h-[46px] items-center gap-3 border-b border-line bg-[var(--slate-50)] px-4">
        <span aria-hidden="true" className="flex gap-1.5">
          <i className="block h-2.5 w-2.5 rounded-full bg-line2" />
          <i className="block h-2.5 w-2.5 rounded-full bg-line2" />
          <i className="block h-2.5 w-2.5 rounded-full bg-line2" />
        </span>
        <span className="flex flex-1 justify-center overflow-hidden">
          <span className="truncate rounded-full border border-line bg-surface px-3.5 py-0.5 text-sm text-ink4" translate="no">
            {latest === undefined
              ? 'lucid / desks'
              : `lucid / desks / ${shortAddress(latest.desk)} / window ${shortId(latest.window.marketId)}`}
          </span>
        </span>
        <StatusBadge tone="emerald" pulse title="Read from the chain by your browser, refreshed every 30 seconds.">
          LIVE
        </StatusBadge>
      </div>

      <div className="p-5 sm:p-7" aria-busy={activity.status === 'loading'} aria-live="polite">
        {activity.status === 'loading' ? (
          <FrameSkeleton />
        ) : activity.status === 'error' ? (
          <p className="py-8 text-center text-md text-ink3">
            The Shannon RPC did not answer, so there is nothing honest to draw here yet. The read
            runs in your browser — retry, or check the endpoint.
          </p>
        ) : latest === undefined ? (
          <NextWindowWaiting
            level="h2"
            intro={`No desk emitted a decision in the last ${blocksToDuration(activity.data.blocks)} of blocks, so there is nothing to replay. This is the window the venue has open right now.`}
          />
        ) : (
          <>
            <div className="mb-5 flex flex-wrap items-end gap-x-6 gap-y-4">
              <div className="min-w-0">
                <h2 className="text-2xl">
                  Window <span translate="no">{shortId(latest.window.marketId)}</span>
                  {latest.window.assetKey !== '0x' ? (
                    <> · {assetFromKey(latest.window.assetKey)}, {cadence(latest.window.intervalSec)}</>
                  ) : null}
                </h2>
                <p className="mt-1 text-base text-ink4">
                  Desk{' '}
                  <Link
                    href={`/desks/${latest.desk}/`}
                    className="rounded-[6px] underline decoration-line2 decoration-dotted underline-offset-[3px] hover:text-indigo"
                  >
                    {shortAddress(latest.desk)}
                  </Link>{' '}
                  · decided in block <BlockLink block={latest.window.lastBlock} />
                  {market.status === 'ready' && market.data !== null ? (
                    <>
                      {' '}
                      · closes{' '}
                      <span title={utcTimestamp(market.data.expiry)}>
                        {now === null ? '…' : relativeTime(market.data.expiry, now)}
                      </span>
                    </>
                  ) : null}
                </p>
              </div>

              <dl className="ml-auto flex flex-wrap gap-x-7 gap-y-3">
                <KeyValue label="Strike">
                  {market.status === 'loading' ? (
                    <Skeleton w="7ch" />
                  ) : market.status === 'error' || market.data === null ? (
                    <Dash why="the DreamDEX indexer has no row for this window" />
                  ) : market.data.strike === 0n ? (
                    <span
                      className="text-ink4"
                      title="The venue records the strike as zero until trading starts: these windows settle against the price they opened at."
                    >
                      at open
                    </span>
                  ) : (
                    strikePrice(market.data.strike)
                  )}
                </KeyValue>
                <KeyValue label="Committee">
                  {latest.window.verdict === undefined ? (
                    <Dash why="no verdict reached this desk in the scanned range" />
                  ) : (
                    `${probability(latest.window.verdict.probUpBps)}%`
                  )}
                </KeyValue>
                <KeyValue label="Book">
                  {latest.window.verdict === undefined ? (
                    <Dash why="no verdict reached this desk in the scanned range" />
                  ) : (
                    <BookProbability pBookBps={latest.window.verdict.pBookBps} />
                  )}
                </KeyValue>
                <KeyValue label="Closes in">
                  {market.status === 'ready' && market.data !== null && now !== null ? (
                    <span className="tabular-nums">{countdown(market.data.expiry - now)}</span>
                  ) : (
                    <Skeleton w="5ch" />
                  )}
                </KeyValue>
              </dl>
            </div>

            <WindowStepper steps={steps} />

            {latest.window.refusal !== undefined ? (
              <RefusalResult
                code={latest.window.refusal.reason}
                probUpBps={latest.window.refusal.probUpBps}
                pBookBps={latest.window.refusal.pBookBps}
              />
            ) : latest.window.executions.length > 0 ? (
              <ExecutedResult executions={latest.window.executions} />
            ) : null}
          </>
        )}
      </div>
    </div>
  )
}

function RefusalResult({
  code,
  probUpBps,
  pBookBps,
}: {
  code: number
  probUpBps: number
  pBookBps: number
}) {
  return (
    <div className="mt-4 flex flex-col gap-4 rounded-r2 border border-rose-line bg-rose-soft p-4 sm:flex-row sm:items-start sm:p-5">
      <span className="grid h-9 w-9 shrink-0 place-items-center rounded-r2 border border-rose-line bg-white text-rose">
        <IconNo size={18} />
      </span>
      <div className="min-w-0 flex-1">
        <h4 className="text-lg text-rose">The desk declined this window — and said exactly why.</h4>
        <p className="mt-1 max-w-[76ch] text-base text-[#7a1d33]">{refusalExplanation(code)}</p>
        <div className="mt-2.5">
          <RefusalBadge code={code} />
        </div>
      </div>
      <dl className="flex shrink-0 gap-6">
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wide text-[#9f5568]">Committee</dt>
          <dd className="text-xl font-extrabold tracking-tight tabular-nums text-rose">
            {probability(probUpBps)}%
          </dd>
        </div>
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wide text-[#9f5568]">Book</dt>
          <dd className="text-xl font-extrabold tracking-tight text-rose">
            <BookProbability pBookBps={pBookBps} />
          </dd>
        </div>
      </dl>
    </div>
  )
}

function ExecutedResult({
  executions,
}: {
  executions: readonly { kind: number; price: bigint; quantity: bigint; orderId: bigint }[]
}) {
  return (
    <div className="mt-4 flex flex-col gap-4 rounded-r2 border border-[#a7f3d0] bg-emerald-soft p-4 sm:flex-row sm:items-start sm:p-5">
      <span className="grid h-9 w-9 shrink-0 place-items-center rounded-r2 border border-[#a7f3d0] bg-white text-emerald">
        <IconCheck size={16} />
      </span>
      <div className="min-w-0 flex-1">
        <h4 className="text-lg text-emerald">The gate passed and the desk traded.</h4>
        <ul className="mt-2 flex flex-wrap gap-2">
          {executions.map((execution) => (
            <li
              key={execution.orderId.toString()}
              className="rounded-r1 border border-[#a7f3d0] bg-white px-2.5 py-1 text-base font-semibold text-emerald tabular-nums"
            >
              {orderKindName(execution.kind)} {count(Number(execution.quantity))} @{' '}
              {contractPrice(execution.price)}
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}

function FrameSkeleton() {
  return (
    <div>
      <div className="mb-5 flex flex-wrap items-end gap-6">
        <div className="min-w-0 flex-1">
          <div className="skeleton h-6 w-[22ch]" aria-hidden="true" />
          <div className="skeleton mt-2 h-4 w-[34ch]" aria-hidden="true" />
        </div>
        <div className="flex gap-7">
          {['Strike', 'Committee', 'Book', 'Closes in'].map((key) => (
            <div key={key}>
              <div className="text-xs font-semibold uppercase tracking-wide text-ink5">{key}</div>
              <div className="skeleton mt-1 h-5 w-[6ch]" aria-hidden="true" />
            </div>
          ))}
        </div>
      </div>
      <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-7">
        {Array.from({ length: 7 }).map((_, index) => (
          <div key={index} className="rounded-r2 border border-line bg-[var(--slate-50)] p-3.5">
            <div className="skeleton h-3 w-[6ch]" aria-hidden="true" />
            <div className="skeleton mt-2 h-4 w-[10ch]" aria-hidden="true" />
            <div className="skeleton mt-2 h-3 w-full" aria-hidden="true" />
          </div>
        ))}
      </div>
    </div>
  )
}
