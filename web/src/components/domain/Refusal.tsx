'use client'

import type { ReactNode } from 'react'
import { count, probability } from '@/lib/format'
import {
  REFUSAL_FAMILY,
  REFUSAL_REASONS,
  refusalName,
  type RefusalFamily,
  type RefusalName,
} from '@/lib/protocol'
import { Badge, type BadgeTone } from '@/components/ui/Primitives'
import { BookProbability } from './WindowStepper'
import { IconNo } from '@/components/ui/Icon'

/**
 * Refusals are not errors, so they are not styled as errors by default.
 *
 * A refusal is the desk doing its job out loud: the model proposed, the policy contract disposed,
 * and the reason went on chain with the arithmetic that produced it. The family decides the
 * colour, so a reader can tell a mandate refusal from a committee one at a glance — and the name
 * is always spelled out, because colour alone never carries meaning here.
 */
const FAMILY_TONE: Readonly<Record<RefusalFamily, BadgeTone>> = {
  none: 'emerald',
  mandate: 'slate',
  risk: 'amber',
  committee: 'indigo',
  market: 'cyan',
  funding: 'rose',
}

const FAMILY_LABEL: Readonly<Record<RefusalFamily, string>> = {
  none: 'Traded',
  mandate: 'Mandate',
  risk: 'Risk',
  committee: 'Committee',
  market: 'Market',
  funding: 'Funding',
}

export function refusalTone(code: number): BadgeTone {
  const name = refusalName(code) as RefusalName
  return FAMILY_TONE[REFUSAL_FAMILY[name] ?? 'mandate'] ?? 'slate'
}

export function refusalFamilyLabel(code: number): string {
  const name = refusalName(code) as RefusalName
  return FAMILY_LABEL[REFUSAL_FAMILY[name] ?? 'mandate'] ?? 'Refusal'
}

export function refusalExplanation(code: number): string {
  const name = refusalName(code) as RefusalName
  return REFUSAL_REASONS[name] ?? 'A reason code this build does not recognise. Check the deployed enum.'
}

/** The reason name, by name, with its one-line explanation attached. */
export function RefusalBadge({ code, className }: { code: number; className?: string }) {
  return (
    <Badge tone={refusalTone(code)} title={refusalExplanation(code)} className={className}>
      <span translate="no">{refusalName(code)}</span>
    </Badge>
  )
}

/** One entry in a desk's refusal log. */
export function RefusalRow({
  code,
  probUpBps,
  pBookBps,
  meta,
}: {
  code: number
  probUpBps: number
  pBookBps: number
  meta?: ReactNode
}) {
  return (
    <div className="flex flex-col gap-2 px-4 py-3.5 sm:flex-row sm:items-center sm:gap-4">
      <div className="flex min-w-0 flex-1 flex-col gap-1.5">
        <div className="flex flex-wrap items-center gap-2">
          <RefusalBadge code={code} />
          <span className="text-sm font-semibold uppercase tracking-wide text-ink5">
            {refusalFamilyLabel(code)}
          </span>
        </div>
        <p className="text-base text-ink3">{refusalExplanation(code)}</p>
      </div>
      <dl className="flex shrink-0 gap-5 sm:gap-6">
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wide text-ink5">Committee</dt>
          <dd className="mt-0.5 text-lg font-bold tabular-nums text-ink">{probability(probUpBps)}%</dd>
        </div>
        <div>
          <dt className="text-xs font-semibold uppercase tracking-wide text-ink5">Book</dt>
          <dd className="mt-0.5 text-lg font-bold text-ink">
            <BookProbability pBookBps={pBookBps} />
          </dd>
        </div>
      </dl>
      {meta ? <div className="shrink-0 text-sm text-ink5">{meta}</div> : null}
    </div>
  )
}

/**
 * A tally of refusals by reason, in the dark treatment the source page uses for this section.
 * An empty tally is a designed state, not a blank box.
 */
export function RefusalTally({
  tally,
  total,
  footnote,
}: {
  tally: readonly { code: number; count: number }[]
  total: number
  footnote: ReactNode
}) {
  if (tally.length === 0) {
    return (
      <div className="rounded-r2 border border-[#1e293b] bg-[#111c2f] px-5 py-8 text-center">
        <span className="mx-auto mb-3 grid h-10 w-10 place-items-center rounded-r2 bg-[#1e293b] text-[#94a3b8]">
          <IconNo size={18} />
        </span>
        <p className="text-md font-semibold text-[#e2e8f0]">No refusals in the scanned range</p>
        <p className="mt-1.5 text-base text-ink-on-dark">{footnote}</p>
      </div>
    )
  }

  const max = Math.max(...tally.map((entry) => entry.count), 1)

  return (
    <div className="overflow-hidden rounded-r2 border border-[#1e293b]">
      <ul className="flex flex-col gap-px bg-[#1e293b]">
        {tally.map((entry) => (
          <li key={entry.code} className="flex items-center gap-3 bg-[#111c2f] px-4 py-2.5">
            <span
              aria-hidden="true"
              className="h-[7px] w-[7px] shrink-0 rounded-full"
              style={{ background: DARK_DOT[refusalTone(entry.code)] }}
            />
            <span className="min-w-0 flex-1 truncate text-base font-semibold text-[#cbd5e1]" translate="no">
              {refusalName(entry.code)}
            </span>
            <span aria-hidden="true" className="hidden h-1 w-16 overflow-hidden rounded-full bg-[#1e293b] sm:block">
              <span
                className="block h-full rounded-full"
                style={{
                  width: `${(entry.count / max) * 100}%`,
                  background: DARK_DOT[refusalTone(entry.code)],
                }}
              />
            </span>
            <span className="shrink-0 text-sm tabular-nums text-[#94a3b8]">{count(entry.count)}</span>
          </li>
        ))}
        <li className="bg-[#0b1524] px-4 py-2.5 text-sm font-medium text-ink-on-dark">
          {count(total)} refusal{total === 1 ? '' : 's'} · {footnote}
        </li>
      </ul>
    </div>
  )
}

/** The dot colours the dark band uses, matched to the light-ground badge tones. */
const DARK_DOT: Readonly<Record<BadgeTone, string>> = {
  indigo: '#818cf8',
  emerald: '#34d399',
  rose: '#fb7185',
  amber: '#fbbf24',
  slate: '#94a3b8',
  cyan: '#22d3ee',
}
