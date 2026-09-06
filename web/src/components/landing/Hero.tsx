'use client'

import { blocksToDuration, count, percent, somi } from '@/lib/format'
import { useDeskTable, useProtocolActivity, useRouterStatus } from '@/lib/hooks'
import { SUBSCRIPTION_FLOOR_WEI } from '@/lib/chain/config'
import { ButtonLink } from '@/components/ui/Primitives'
import { Dash, Skeleton, Value } from '@/components/ui/Value'
import { IconArrowRight, IconWave } from '@/components/ui/Icon'
import { LiveWindowFrame } from './LiveWindowFrame'

/**
 * The hero.
 *
 * Every number in the trust row is read from the chain by the reader's browser. Where a number
 * is a count over a bounded block scan, the label says so — "in the last 47 min" is a fact;
 * an unqualified "4 117 windows considered" would not be one.
 */
export function Hero() {
  const router = useRouterStatus()
  const desks = useDeskTable()
  const activity = useProtocolActivity()

  const refusedShare =
    activity.status === 'ready' && activity.data.considered > 0
      ? (activity.data.refused / activity.data.considered) * 100
      : null

  return (
    <section className="relative overflow-hidden pt-14 sm:pt-[76px]">
      <div
        aria-hidden="true"
        className="pointer-events-none absolute left-1/2 top-[-260px] h-[620px] w-[1100px] max-w-none -translate-x-1/2"
        style={{ background: 'radial-gradient(closest-side,rgba(124,58,237,.16),transparent 72%)' }}
      />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute right-[-160px] top-[120px] h-[520px] w-[620px]"
        style={{ background: 'radial-gradient(closest-side,rgba(79,70,229,.12),transparent 70%)' }}
      />

      <div className="wrap relative">
        <p className="inline-flex items-center gap-2.5 rounded-full border border-line bg-surface px-2 py-1 text-base text-ink3 shadow-[0_1px_2px_rgba(15,23,42,.04)]">
          <span className="inline-flex h-[22px] items-center rounded-full bg-indigo-soft px-2.5 text-xs font-bold text-indigo">
            LIVE
          </span>
          Validator-run inference, with per-validator receipts on chain
        </p>

        <h1 className="mt-5 max-w-[17ch] text-[clamp(38px,5.4vw,68px)] leading-[1.02] tracking-tightest">
          Trading desks that keep trading{' '}
          <span className="bg-gradient-to-r from-violet to-indigo bg-clip-text text-transparent">
            after you close the laptop.
          </span>
        </h1>

        <p className="mt-5 max-w-[60ch] text-[17px] leading-relaxed text-ink3 sm:text-[19px]">
          Lucid desks trade DreamDEX Event Contracts — short-dated binary markets on whether BTC
          closes above the price its window opened at.{' '}
          <b className="font-semibold text-ink">A desk is a contract, not a script.</b> Somnia&rsquo;s
          validators wake it, run the model as a committee, and record every decision — including
          every refusal — on chain.
        </p>

        <div className="mt-7 flex flex-wrap items-center gap-3">
          <ButtonLink href="/desks/" tone="primary" size="lg">
            Browse the Desks
            <IconArrowRight size={16} />
          </ButtonLink>
          <ButtonLink href="/system/" tone="default" size="lg">
            <IconWave size={16} />
            See the Machine Room
          </ButtonLink>
          <span className="text-base text-ink4">No key custody. Settles in tUSDC on Shannon.</span>
        </div>

        <dl className="mt-10 grid grid-cols-2 gap-x-8 gap-y-6 border-t border-line pt-6 sm:flex sm:flex-wrap sm:gap-x-9">
          <TrustStat
            label="desks deployed by the factory"
            value={<Value state={desks} w="2ch">{(rows) => count(rows.length)}</Value>}
          />
          <TrustStat
            label={
              activity.status === 'ready'
                ? `windows considered in the last ${blocksToDuration(activity.data.blocks)}`
                : 'windows considered in the scanned range'
            }
            value={<Value state={activity} w="3ch">{(a) => count(a.considered)}</Value>}
          />
          <TrustStat
            label="of those windows refused, on purpose"
            value={
              activity.status === 'ready' ? (
                refusedShare === null ? (
                  <Dash why="no windows were considered in the scanned range, so there is no share to compute" />
                ) : (
                  percent(refusedShare)
                )
              ) : activity.status === 'error' ? (
                <Dash why={activity.error.message} />
              ) : (
                <Skeleton w="4ch" />
              )
            }
          />
          <TrustStat
            label={`SOMI at the router, against a ${somi(SUBSCRIPTION_FLOOR_WEI, 0)} floor`}
            value={<Value state={router} w="5ch">{(r) => somi(r.balance)}</Value>}
          />
        </dl>

        <LiveWindowFrame />
      </div>
    </section>
  )
}

/**
 * The term comes first and the value second, as a definition list requires; the visual order is
 * flipped with `flex-col-reverse` so the number still reads above its label.
 */
function TrustStat({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col-reverse">
      <dt className="mt-0.5 max-w-[26ch] text-base text-ink4">{label}</dt>
      <dd className="text-[26px] font-extrabold tracking-tightest text-ink">{value}</dd>
    </div>
  )
}
