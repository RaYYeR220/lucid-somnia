'use client'

import type { ReactNode } from 'react'
import { COLLATERAL_SYMBOL } from '@/lib/chain/config'
import { bpsPercent, count, pctOf, usdc } from '@/lib/format'
import type { DeskState, Policy } from '@/lib/protocol'
import { Meter } from '@/components/ui/Primitives'

/**
 * The limits a desk enforces against itself.
 *
 * Two shapes, and the difference matters. A **meter** is something being consumed, so its bar
 * says how close the desk is to the edge. A **ceiling** is a fixed veto with nothing accumulating
 * against it — drawing that as a full bar would read as "at the limit" when it means the opposite,
 * so those are stated as facts instead.
 *
 * Every number is what `PolicyLib.gate` actually compares, in the units it compares them in.
 */
export function PolicyGateMeters({
  policy,
  state,
  equity,
}: {
  policy: Policy
  state: DeskState
  equity: bigint
}) {
  const budgetLeft = policy.dailyBudget > state.spentToday ? policy.dailyBudget - state.spentToday : 0n
  const budgetPct = pctOf(state.spentToday, policy.dailyBudget)

  // `RiskHalt` fires when equity falls this far below the stored high-water mark.
  const floor =
    policy.maxDrawdownBps >= 10_000
      ? 0n
      : (state.highWaterMark * BigInt(10_000 - policy.maxDrawdownBps)) / 10_000n
  const drawdownBps =
    state.highWaterMark === 0n
      ? 0
      : Math.max(0, Number(((state.highWaterMark - equity) * 10_000n) / state.highWaterMark))
  const drawdownUsed = policy.maxDrawdownBps === 0 ? 0 : (drawdownBps / policy.maxDrawdownBps) * 100

  return (
    <div className="flex flex-col gap-8">
      <div className="grid gap-x-8 gap-y-7 sm:grid-cols-2">
        <Meter
          label="Daily budget"
          valueText={`${usdc(state.spentToday)} / ${usdc(policy.dailyBudget)}`}
          percent={budgetPct}
          tone={budgetPct > 90 ? 'rose' : 'indigo'}
          footLeft={`${usdc(budgetLeft)} ${COLLATERAL_SYMBOL} of room left today`}
          footRight={
            state.spentToday === 0n ? 'Nothing spent today' : 'Resets at the next UTC day'
          }
        />
        <Meter
          label="Drawdown floor"
          valueText={
            policy.maxDrawdownBps >= 10_000
              ? 'never halts'
              : `${bpsPercent(drawdownBps)} of ${bpsPercent(policy.maxDrawdownBps)}`
          }
          percent={Math.min(100, drawdownUsed)}
          tone={drawdownUsed > 80 ? 'rose' : 'emerald'}
          footLeft={`High-water mark ${usdc(state.highWaterMark)} ${COLLATERAL_SYMBOL}`}
          footRight={
            policy.maxDrawdownBps >= 10_000
              ? 'No drawdown halt is configured'
              : `Halts below ${usdc(floor)} ${COLLATERAL_SYMBOL}`
          }
        />
        <Meter
          label="Loss streak"
          valueText={`${count(state.consecutiveLosses)} / ${count(policy.maxConsecutiveLosses)}`}
          percent={
            policy.maxConsecutiveLosses === 0
              ? 100
              : (state.consecutiveLosses / policy.maxConsecutiveLosses) * 100
          }
          tone={state.consecutiveLosses > 0 ? 'amber' : 'emerald'}
          footLeft={
            state.consecutiveLosses === 0
              ? 'No consecutive losses on record'
              : `${count(state.consecutiveLosses)} settled losses in a row`
          }
          footRight="A settled win resets the counter"
        />
        <Meter
          label="Open windows"
          valueText={`${count(state.openMarkets)} / ${count(policy.maxOpenMarkets)}`}
          percent={policy.maxOpenMarkets === 0 ? 100 : (state.openMarkets / policy.maxOpenMarkets) * 100}
          tone="indigo"
          footLeft={state.openMarkets === 0 ? 'No open positions' : 'Slots in use'}
          footRight="A full book refuses with MaxOpenReached"
        />
      </div>

      <div className="grid gap-4 border-t border-line pt-6 sm:grid-cols-2">
        <Ceiling
          label="Per-window cap"
          value={`${usdc(policy.maxStakePerWindow)} ${COLLATERAL_SYMBOL}`}
          refusal="CapExceeded"
        >
          A hard veto rather than a clamp: an order larger than this is refused outright, not
          trimmed down to fit.
        </Ceiling>
        <Ceiling
          label="Minimum edge"
          value={bpsPercent(policy.minEdgeBps)}
          refusal="LowEdge"
        >
          {policy.minEdgeBps === 0
            ? 'Set to zero, so any disagreement at all is enough — the setting a Maker desk runs, because it does not need the book to be wrong.'
            : 'How far the committee’s probability must sit from the book’s before the trade is worth making.'}
        </Ceiling>
      </div>
    </div>
  )
}

/** A fixed limit with nothing accumulating against it. Stated, never drawn as a full bar. */
function Ceiling({
  label,
  value,
  refusal,
  children,
}: {
  label: string
  value: string
  refusal: string
  children: ReactNode
}) {
  return (
    <div className="rounded-r2 border border-line bg-[var(--slate-50)] px-4 py-3.5">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-base text-ink4">{label}</span>
        <b className="text-xl font-bold tracking-tight tabular-nums text-ink">{value}</b>
      </div>
      <p className="mt-1.5 text-base text-ink3">{children}</p>
      <p className="mt-2 text-sm text-ink5">
        Breaching it emits{' '}
        <code className="font-semibold text-ink4" translate="no">
          Refused({refusal})
        </code>
        .
      </p>
    </div>
  )
}
