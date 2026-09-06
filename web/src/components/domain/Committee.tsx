'use client'

import { clsx } from '@/lib/clsx'
import { count, probability, score01 } from '@/lib/format'
import { IconCommittee } from '@/components/ui/Icon'
import { Badge } from '@/components/ui/Primitives'

/** The three swatch colours the committee visualisation uses, in subcommittee order. */
const VALIDATOR_COLOURS = ['#4F46E5', '#7C3AED', '#0891B2', '#059669', '#B45309']

export interface CommitteeVote {
  /** Every raw validator answer that decoded, in subcommittee order, `0..100`. */
  scores: readonly bigint[]
  /** The stored median, in basis points. `probUpBps / 100` recovers the raw median. */
  probUpBps: number
  /** Usable, in-range answers — the median's sample size. */
  responded: number
  /** How many usable answers fell on the same side of 50 as the median. */
  agreed: number
  ok: boolean
  threshold?: number
}

/**
 * The committee's answer, one bar per validator, with the median called out beneath.
 *
 * Validators are not named on chain — the subcommittee membership is never stored — so they are
 * numbered in the order the receipts arrived rather than given invented names. A score outside
 * `0..100` is shown and marked as discarded, because the log kept it and hiding it would make
 * the median look better sampled than it was.
 */
export function CommitteeVoteChart({ vote, className }: { vote: CommitteeVote; className?: string }) {
  const median = vote.probUpBps / 100

  return (
    <div className={className}>
      <ul className="flex flex-col gap-2.5">
        {vote.scores.map((raw, index) => {
          const score = Number(raw)
          const discarded = score < 0 || score > 100
          const width = Math.max(0, Math.min(100, score))
          return (
            <li
              key={index}
              className="grid grid-cols-[minmax(72px,auto)_1fr_auto] items-center gap-3 text-base"
            >
              <span className="font-semibold text-ink2">Validator&nbsp;{index + 1}</span>
              <span className="h-[7px] overflow-hidden rounded-[4px] bg-slate1">
                <span
                  className="block h-full w-full origin-left rounded-[4px] transition-transform duration-500 ease-out"
                  style={{
                    transform: `scaleX(${width / 100})`,
                    background: discarded ? 'var(--line-2)' : VALIDATOR_COLOURS[index % VALIDATOR_COLOURS.length],
                  }}
                />
              </span>
              <span className="flex items-center gap-2 text-right font-bold tabular-nums tracking-tight text-ink">
                {discarded ? (
                  <Badge tone="slate" title="Outside the 0–100 range, so it was excluded from the median.">
                    discarded
                  </Badge>
                ) : null}
                {score01(score)}
              </span>
            </li>
          )
        })}
      </ul>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-dashed border-line2 pt-3 text-base text-ink4">
        <span>
          Median of {count(vote.responded)} usable answer{vote.responded === 1 ? '' : 's'}
          {vote.threshold !== undefined ? ` · quorum ${count(vote.threshold)}` : ''}
        </span>
        <b className={clsx('font-bold', vote.ok ? 'text-indigo' : 'text-ink4')}>
          {score01(median)} · {probability(vote.probUpBps)}% UP
        </b>
      </div>

      <p className="mt-2 text-sm text-ink5">
        {count(vote.agreed)} of {count(vote.responded)} usable answers fell on the same side of the coin
        flip as the median. Policy reads the median, never an average.
      </p>
    </div>
  )
}

/** The designed state for a window whose committee reply is not in the scanned block range. */
export function CommitteeUnavailable({ reason }: { reason: string }) {
  return (
    <div className="flex flex-col items-start gap-2 rounded-r2 border border-dashed border-line2 bg-[var(--slate-50)] px-4 py-5">
      <span className="grid h-9 w-9 place-items-center rounded-r2 bg-surface text-ink5 ring-1 ring-line">
        <IconCommittee size={17} />
      </span>
      <p className="text-md font-semibold text-ink">No per-validator receipts to show</p>
      <p className="max-w-[52ch] text-base text-ink3">{reason}</p>
    </div>
  )
}
