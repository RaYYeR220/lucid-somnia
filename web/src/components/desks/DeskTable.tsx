'use client'

import Link from 'next/link'
import { useMemo } from 'react'
import { clsx } from '@/lib/clsx'
import type { DeskSnapshot } from '@/lib/chain/reads'
import { count, pctOf, shortAddress, somiPrecise, usdc } from '@/lib/format'
import {
  assetsFromMask,
  cadencesFromMask,
  strategyName,
} from '@/lib/protocol'
import { useUrlState } from '@/lib/urlState'
import { AddressLink, Badge, StatusBadge } from '@/components/ui/Primitives'
import { IconSort, IconSortDown, IconSortUp } from '@/components/ui/Icon'
import { ArmedState } from './ArmedState'

type SortKey = 'equity' | 'spend' | 'open' | 'streak' | 'armed' | 'credit'
type SortDir = 'asc' | 'desc'

const SORT_KEYS: readonly SortKey[] = ['equity', 'spend', 'open', 'streak', 'armed', 'credit']
const SORT_DIRS: readonly SortDir[] = ['asc', 'desc']

const COLUMNS: { key: SortKey | null; label: string; hint?: string; align?: 'right' }[] = [
  { key: null, label: 'Desk' },
  { key: null, label: 'Strategy' },
  { key: 'equity', label: 'Equity', hint: 'Free collateral plus everything committed to open windows, at cost.', align: 'right' },
  { key: 'spend', label: 'Today’s spend', hint: 'Spent today against the daily budget the mandate sets.', align: 'right' },
  { key: 'open', label: 'Open', hint: 'Windows the desk is currently positioned in, against its slot limit.', align: 'right' },
  { key: 'streak', label: 'Streak', hint: 'Consecutive settled losses against the mandate’s tolerance.', align: 'right' },
  { key: 'credit', label: 'Gas credit', hint: 'SOMI the router holds for this desk, to pay for firings and committee deposits.', align: 'right' },
  { key: 'armed', label: 'State' },
]

function compare(a: DeskSnapshot, b: DeskSnapshot, key: SortKey): number {
  switch (key) {
    case 'equity':
      return a.equity === b.equity ? 0 : a.equity > b.equity ? 1 : -1
    case 'spend':
      return pctOf(a.state.spentToday, a.policy.dailyBudget) - pctOf(b.state.spentToday, b.policy.dailyBudget)
    case 'open':
      return a.state.openMarkets - b.state.openMarkets
    case 'streak':
      return a.state.consecutiveLosses - b.state.consecutiveLosses
    case 'credit':
      return a.gasCredit === b.gasCredit ? 0 : a.gasCredit > b.gasCredit ? 1 : -1
    case 'armed':
      return Number(a.armedAtRouter && a.policy.armed) - Number(b.armedAtRouter && b.policy.armed)
  }
}

/**
 * Every desk the factory has ever created.
 *
 * A real table: a caption, proper header cells with sort state announced through `aria-sort`, and
 * one row per desk that is a link to that desk rather than a row with a click handler on it. The
 * sort lives in the query string, so a sorted view is a URL somebody can send.
 */
export function DeskTable({ desks }: { desks: readonly DeskSnapshot[] }) {
  const [sort, setSort] = useUrlState<SortKey>('sort', 'equity', SORT_KEYS)
  const [dir, setDir] = useUrlState<SortDir>('dir', 'desc', SORT_DIRS)

  const rows = useMemo(() => {
    const sorted = [...desks].sort((a, b) => compare(a, b, sort))
    return dir === 'desc' ? sorted.reverse() : sorted
  }, [desks, sort, dir])

  function toggle(key: SortKey) {
    if (key === sort) setDir(dir === 'desc' ? 'asc' : 'desc')
    else {
      setSort(key)
      setDir('desc')
    }
  }

  return (
    <div
      // A container that scrolls must be reachable without a pointer, so it is a focusable region.
      tabIndex={0}
      role="region"
      aria-label="Every desk, scrollable horizontally"
      className="overflow-x-auto rounded-r4 border border-line bg-surface shadow-card"
    >
      <table className="w-full min-w-[880px] border-collapse text-md">
        <caption className="sr-only">
          Every Lucid desk, with its equity, today&rsquo;s spend against its daily budget, open
          windows, loss streak, gas credit and armed state. Sortable by column.
        </caption>
        <thead>
          <tr className="border-b border-line">
            {COLUMNS.map((column) => {
              const active = column.key !== null && column.key === sort
              return (
                <th
                  key={column.label}
                  scope="col"
                  aria-sort={active ? (dir === 'asc' ? 'ascending' : 'descending') : undefined}
                  className={clsx(
                    'whitespace-nowrap px-4 py-3 text-xs font-bold uppercase tracking-wide text-ink5',
                    column.align === 'right' ? 'text-right' : 'text-left',
                  )}
                >
                  {column.key === null ? (
                    <span title={column.hint}>{column.label}</span>
                  ) : (
                    <button
                      type="button"
                      onClick={() => toggle(column.key as SortKey)}
                      title={column.hint}
                      className={clsx(
                        'inline-flex min-h-[36px] items-center gap-1.5 rounded-[6px] px-2 py-2 -mx-2 uppercase transition-colors hover:bg-slate1 hover:text-ink [touch-action:manipulation]',
                        active && 'text-indigo',
                      )}
                    >
                      {column.label}
                      {active ? (
                        dir === 'asc' ? (
                          <IconSortUp size={11} />
                        ) : (
                          <IconSortDown size={11} />
                        )
                      ) : (
                        <IconSort size={11} className="opacity-40" />
                      )}
                    </button>
                  )}
                </th>
              )
            })}
          </tr>
        </thead>
        <tbody>
          {rows.map((desk) => {
            const spendPct = pctOf(desk.state.spentToday, desk.policy.dailyBudget)
            const assets = assetsFromMask(desk.policy.allowedAssets)
            const cadences = cadencesFromMask(desk.policy.allowedCadences)
            return (
              <tr key={desk.address} className="border-b border-line last:border-0 transition-colors hover:bg-[var(--slate-50)]">
                <th scope="row" className="px-4 py-3.5 text-left font-normal">
                  {/* Two separate links, never nested: one to the desk, one to its owner on the
                      explorer. A link inside a link is invalid and unreachable by keyboard. */}
                  <Link
                    href={`/desks/${desk.address}/`}
                    className="block max-w-[24ch] truncate rounded-[6px] font-semibold text-ink transition-colors hover:text-indigo"
                    translate="no"
                    title={desk.publishedName !== '' ? desk.publishedName : desk.address}
                  >
                    {desk.publishedName !== '' ? desk.publishedName : shortAddress(desk.address)}
                  </Link>
                  <span className="mt-0.5 block text-sm font-normal text-ink5">
                    owner <AddressLink address={desk.owner} className="no-underline" />
                  </span>
                </th>
                <td className="px-4 py-3.5">
                  <div className="flex flex-wrap items-center gap-1.5">
                    <Badge tone="indigo">{strategyName(desk.policy.strategy)}</Badge>
                    <span className="text-sm text-ink5">
                      {assets.length > 0 ? assets.join(' · ') : 'no asset'}
                      {cadences.length > 0
                        ? ` · ${cadences.map((c) => (c >= 3600 ? `${c / 3600}h` : `${c / 60}m`)).join(', ')}`
                        : ' · no cadence'}
                    </span>
                  </div>
                </td>
                <td className="px-4 py-3.5 text-right tabular-nums">
                  <span className="font-semibold text-ink">{usdc(desk.equity)}</span>
                  <span className="ml-1 text-sm text-ink5">tUSDC</span>
                </td>
                <td className="px-4 py-3.5 text-right">
                  <span className="tabular-nums font-semibold text-ink">{usdc(desk.state.spentToday)}</span>
                  <span className="text-sm text-ink5"> / {usdc(desk.policy.dailyBudget)}</span>
                  <span
                    aria-hidden="true"
                    className="mt-1 block h-1 w-full overflow-hidden rounded-full bg-slate1"
                  >
                    <span
                      className={clsx('block h-full rounded-full', spendPct > 90 ? 'bg-rose' : 'bg-indigo')}
                      style={{ width: `${Math.max(spendPct, desk.state.spentToday > 0n ? 3 : 0)}%` }}
                    />
                  </span>
                </td>
                <td className="px-4 py-3.5 text-right tabular-nums">
                  <span className="font-semibold text-ink">{count(desk.state.openMarkets)}</span>
                  <span className="text-sm text-ink5"> / {count(desk.policy.maxOpenMarkets)}</span>
                </td>
                <td className="px-4 py-3.5 text-right tabular-nums">
                  <span
                    className={clsx(
                      'font-semibold',
                      desk.state.consecutiveLosses > 0 ? 'text-amber' : 'text-ink',
                    )}
                  >
                    {count(desk.state.consecutiveLosses)}
                  </span>
                  <span className="text-sm text-ink5"> / {count(desk.policy.maxConsecutiveLosses)}</span>
                </td>
                <td className="px-4 py-3.5 text-right tabular-nums">
                  {desk.gasCredit === 0n ? (
                    <StatusBadge tone="rose" title="With no credit the router skips this desk with Skipped(NO_CREDIT) rather than dropping it silently.">
                      none
                    </StatusBadge>
                  ) : (
                    <>
                      <span className="font-semibold text-ink">{somiPrecise(desk.gasCredit)}</span>
                      <span className="ml-1 text-sm text-ink5">SOMI</span>
                    </>
                  )}
                </td>
                <td className="px-4 py-3.5">
                  <ArmedState policyArmed={desk.policy.armed} armedAtRouter={desk.armedAtRouter} />
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
