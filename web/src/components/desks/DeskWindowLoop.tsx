'use client'

import { useMemo } from 'react'
import type { BrainEvent, DeskWindow, Scan } from '@/lib/chain/logs'
import { fetchWindowsById } from '@/lib/indexer'
import {
  blocksToDuration,
  cadence,
  count,
  countdown,
  probability,
  relativeTime,
  shortId,
  strikePrice,
  utcTimestamp,
} from '@/lib/format'
import { assetFromKey } from '@/lib/protocol'
import { useNow } from '@/lib/hooks'
import { useQuery } from '@/lib/query'
import { Card } from '@/components/ui/Card'
import { BlockLink, KeyValue, StatusBadge } from '@/components/ui/Primitives'
import { Skeleton } from '@/components/ui/Value'
import { BookProbability, WindowStepper, buildSteps } from '@/components/domain/WindowStepper'
import { NextWindowWaiting } from '@/components/domain/NextWindow'
import { CommitteeUnavailable, CommitteeVoteChart } from '@/components/domain/Committee'

/**
 * The live window loop for one desk: the seven stages, and the committee vote behind them.
 *
 * The stepper reads the desk's own log; the per-validator receipts read the brain's, which is the
 * only place they exist — the subcommittee membership is never stored, so the validators are
 * numbered by receipt order rather than given names they do not have.
 */
export function DeskWindowLoop({
  window,
  brainScan,
  scanBlocks,
  committeeThreshold,
  mandateCadences,
  mandateAssets,
}: {
  window: DeskWindow | undefined
  brainScan: Scan<BrainEvent> | undefined
  scanBlocks: number
  committeeThreshold: number | undefined
  /** The window lengths this desk's mandate allows, so the waiting view matches what it can take. */
  mandateCadences?: readonly number[]
  mandateAssets?: readonly string[]
}) {
  const now = useNow()
  const marketId = window?.marketId

  const market = useQuery(
    marketId === undefined ? null : `window:${marketId}`,
    async () => (await fetchWindowsById([marketId as string]))[0] ?? null,
    { refreshMs: 30_000 },
  )

  const steps = useMemo(
    () => (window === undefined ? [] : buildSteps(window, brainScan?.events ?? [])),
    [window, brainScan],
  )

  const vote = useMemo(() => {
    if (window === undefined || brainScan === undefined) return undefined
    const found = brainScan.events.find(
      (event) =>
        event.name === 'VerdictReceived' &&
        event.marketId.toLowerCase() === window.marketId.toLowerCase(),
    )
    return found !== undefined && found.name === 'VerdictReceived' ? found : undefined
  }, [window, brainScan])

  // The waiting state keeps the same two-column shape as the live one. A page whose structure
  // changes depending on whether anything happened is harder to read, not simpler.
  if (window === undefined) {
    return (
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <Card pad="md">
          <NextWindowWaiting
            cadences={mandateCadences}
            assets={mandateAssets}
            intro={`This desk emitted nothing across the last ${blocksToDuration(scanBlocks)} of blocks — the router only wakes a desk when the venue opens a window its mandate covers, and eth_getLogs is capped at 1 000 blocks per query, so the scan is bounded.`}
          />
        </Card>

        <Card pad="md">
          <h3 className="text-xl tracking-tighter">The committee vote</h3>
          <p className="mt-1.5 text-base text-ink4">
            One receipt per validator, filed on chain. Policy reads the median.
          </p>
          <div className="mt-5">
            <CommitteeUnavailable reason="No window has reached this desk in the scanned range, so no committee has been asked about one — and there are no receipts to show." />
          </div>
          {committeeThreshold !== undefined ? (
            <p className="mt-4 text-sm text-ink5">
              When one is asked, {count(committeeThreshold)} of the committee&rsquo;s answers have to
              land before the verdict counts at all.
            </p>
          ) : null}
        </Card>
      </div>
    )
  }

  return (
    <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
      <Card pad="md">
        <div className="mb-5 flex flex-wrap items-end gap-x-6 gap-y-4">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="text-2xl tracking-tighter">
                Window <span translate="no">{shortId(window.marketId)}</span>
              </h3>
              {window.assetKey !== '0x' ? (
                <StatusBadge tone="indigo">
                  {assetFromKey(window.assetKey)} · {cadence(window.intervalSec)}
                </StatusBadge>
              ) : null}
            </div>
            <p className="mt-1 text-base text-ink4">
              Decided in block <BlockLink block={window.lastBlock} />
              {market.status === 'ready' && market.data !== null ? (
                <>
                  {' '}
                  · opened{' '}
                  <span title={utcTimestamp(market.data.tradingStart)}>
                    {now === null ? '…' : relativeTime(market.data.tradingStart, now)}
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
                <span className="text-ink5" title="The DreamDEX indexer has no row for this window.">
                  —
                </span>
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
              {window.verdict === undefined ? (
                <span className="text-ink5" title="No verdict reached this desk.">
                  —
                </span>
              ) : (
                `${probability(window.verdict.probUpBps)}%`
              )}
            </KeyValue>
            <KeyValue label="Book">
              {window.verdict === undefined ? (
                <span className="text-ink5">—</span>
              ) : (
                <BookProbability pBookBps={window.verdict.pBookBps} />
              )}
            </KeyValue>
            <KeyValue label="Closes in">
              {market.status === 'ready' && market.data !== null && now !== null ? (
                <span className="tabular-nums">
                  {market.data.expiry <= now ? 'closed' : countdown(market.data.expiry - now)}
                </span>
              ) : market.status === 'error' || (market.status === 'ready' && market.data === null) ? (
                <span className="text-ink5">—</span>
              ) : (
                <Skeleton w="5ch" />
              )}
            </KeyValue>
          </dl>
        </div>

        <WindowStepper steps={steps} />
      </Card>

      <Card pad="md">
        <h3 className="text-xl tracking-tighter">The committee vote</h3>
        <p className="mt-1.5 text-base text-ink4">
          One receipt per validator, filed on chain. Policy reads the median.
        </p>

        <div className="mt-5">
          {brainScan === undefined ? (
            <div className="space-y-3">
              <div className="skeleton h-3 w-full" aria-hidden="true" />
              <div className="skeleton h-3 w-5/6" aria-hidden="true" />
              <div className="skeleton h-3 w-2/3" aria-hidden="true" />
            </div>
          ) : vote !== undefined && vote.name === 'VerdictReceived' ? (
            <CommitteeVoteChart
              vote={{
                scores: vote.scores,
                probUpBps: vote.probUpBps,
                responded: vote.responded,
                agreed: vote.agreed,
                ok: vote.ok,
                ...(committeeThreshold !== undefined ? { threshold: committeeThreshold } : {}),
              }}
            />
          ) : window.verdict !== undefined ? (
            <>
              <CommitteeUnavailable
                reason={`The desk recorded a median of ${probability(window.verdict.probUpBps)}% from ${count(window.verdict.responded)} validators, but the brain’s own receipt log for this window falls outside the ${blocksToDuration(brainScan.blocks)} of blocks scanned.`}
              />
              <dl className="mt-4 flex flex-col gap-2 text-base">
                <div className="flex items-baseline justify-between gap-3">
                  <dt className="text-ink4">Median reaching the desk</dt>
                  <dd className="font-bold text-indigo">{probability(window.verdict.probUpBps)}% UP</dd>
                </div>
                <div className="flex items-baseline justify-between gap-3">
                  <dt className="text-ink4">Validators answering</dt>
                  <dd className="font-bold text-ink">{count(window.verdict.responded)}</dd>
                </div>
              </dl>
            </>
          ) : (
            <CommitteeUnavailable reason="No verdict reached this desk for this window, so there are no receipts to show." />
          )}
        </div>
      </Card>
    </div>
  )
}
