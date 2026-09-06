'use client'

import Link from 'next/link'
import { useMemo } from 'react'
import { SUBSCRIPTION_FLOOR_WEI } from '@/lib/chain/config'
import { foldDeskWindows } from '@/lib/chain/logs'
import { decodeSubscription } from '@/lib/chain/subscriptions'
import {
  blocksToDuration,
  count,
  millions,
  countdown,
  pctOf,
  probability,
  somi,
  somiPrecise,
  usdc,
  utcTimestamp,
} from '@/lib/format'
import {
  useBrainStatus,
  useDeskTable,
  useNow,
  useProtocolActivity,
  useRouterStatus,
  useSubscriptions,
} from '@/lib/hooks'
import { Card, CardFoot, CardIcon, SectionHead } from '@/components/ui/Card'
import { Meter, Stat } from '@/components/ui/Primitives'
import { Skeleton, Value } from '@/components/ui/Value'
import { RefusalBadge } from '@/components/domain/Refusal'
import { IconClock, IconCommittee, IconNo, IconShieldCheck } from '@/components/ui/Icon'

/**
 * The bento grid: four claims, each carrying the live number that either supports it or fails to.
 *
 * Nothing in these cards is illustrative. If a card cannot be filled from the chain right now it
 * shows a skeleton and then an honest gap, because a decorative number inside a claim about
 * honesty would undo the claim.
 */
export function Bento() {
  return (
    <section className="py-16 sm:py-24" aria-labelledby="two-ideas">
      <div className="wrap">
        <SectionHead
          id="two-ideas"
          kicker="Two ideas, both unusual"
          title={
            <>Every comparable product is a script on somebody&rsquo;s laptop holding an API key.</>
          }
        >
          <p>
            Lucid moves both halves on chain: the thing that decides, and the thing that says no.
            Everything below is a contract call you can replay from a block explorer.
          </p>
        </SectionHead>

        <div className="mt-10 grid gap-4 lg:grid-cols-6">
          <NoServerCard />
          <RefusalCard />
          <CommitteeCard />
          <ReactiveCard />
          <CapitalCard />
        </div>
      </div>
    </section>
  )
}

function NoServerCard() {
  const router = useRouterStatus()
  const subs = useSubscriptions()

  return (
    <Card className="lg:col-span-3">
      <CardIcon tone="indigo">
        <IconShieldCheck size={20} />
      </CardIcon>
      <h3 className="text-2xl tracking-tighter">There is no server</h3>
      <p className="mt-2.5 text-md text-ink3">
        A desk is a contract. A reactivity subscription runs its handler in the same block as the
        venue&rsquo;s log, so the desk wakes itself, and a second validator committee fetches its
        price the same way. There is no queue to drain, no cron to miss, and no key in an env file.
      </p>
      <CardFoot>
        <Stat label="subscriptions the router owns" size="sm">
          <Value state={subs} w="1ch">{(list) => count(list.length)}</Value>
        </Stat>
        <Stat label="SOMI at the router" size="sm">
          <Value state={router} w="5ch">{(r) => somi(r.balance)}</Value>
        </Stat>
        <Stat label="processes to keep alive" size="sm">
          0
        </Stat>
      </CardFoot>
      <p className="mt-3 text-sm text-ink5">
        This page has no backend either. Open the network tab: it talks to the Shannon RPC and the
        DreamDEX indexer, and to nothing of ours.
      </p>
    </Card>
  )
}

function RefusalCard() {
  const desks = useDeskTable()
  const activity = useProtocolActivity()

  const primary = desks.status === 'ready' ? desks.data[0] : undefined
  const lastRefusal = useMemo(() => {
    if (activity.status !== 'ready') return undefined
    for (const desk of activity.data.desks) {
      const found = desk.scan.events.find((event) => event.name === 'Refused')
      if (found !== undefined && found.name === 'Refused') return found
    }
    return undefined
  }, [activity])

  return (
    <Card className="lg:col-span-3">
      <CardIcon tone="rose">
        <IconNo size={20} />
      </CardIcon>
      <h3 className="text-2xl tracking-tighter">The refusal is the product</h3>
      <p className="mt-2.5 text-md text-ink3">
        The model only ever proposes. A policy contract disposes. Committee unavailable, confidence
        too low, no observable book, over cap, drawdown breached, window too short — each becomes an
        explicit{' '}
        <b className="font-semibold text-ink" translate="no">
          Refused(reason)
        </b>{' '}
        on chain, and no trade. A desk declining loudly is the feature.
      </p>

      <div className="mt-5">
        {desks.status === 'ready' && primary !== undefined ? (
          <Meter
            label="Daily budget, the live desk"
            valueText={`${usdc(primary.state.spentToday)} / ${usdc(primary.policy.dailyBudget)}`}
            percent={pctOf(primary.state.spentToday, primary.policy.dailyBudget)}
            tone={pctOf(primary.state.spentToday, primary.policy.dailyBudget) > 90 ? 'rose' : 'indigo'}
            footLeft={`${usdc(primary.policy.dailyBudget - primary.state.spentToday)} tUSDC of room left`}
            footRight={
              lastRefusal !== undefined && lastRefusal.name === 'Refused' ? (
                <span className="inline-flex flex-wrap items-center gap-1.5 font-semibold text-rose">
                  the last window ended in
                  <RefusalBadge code={lastRefusal.reason} />
                </span>
              ) : (
                'no refusal in the scanned range'
              )
            }
          />
        ) : desks.status === 'error' ? (
          <p className="text-base text-ink4">
            The desk&rsquo;s budget counter could not be read from your browser.
          </p>
        ) : (
          <div className="space-y-2">
            <div className="skeleton h-4 w-2/3" aria-hidden="true" />
            <div className="skeleton h-2.5 w-full" aria-hidden="true" />
            <div className="skeleton h-3 w-1/2" aria-hidden="true" />
          </div>
        )}
      </div>

      <p className="mt-4 text-sm text-ink5">
        <Link href="/desks/" className="rounded-[6px] underline decoration-line2 decoration-dotted underline-offset-[3px] hover:text-indigo">
          Every refusal is in the desk&rsquo;s own log <span aria-hidden="true">→</span>
        </Link>
      </p>
    </Card>
  )
}

function CommitteeCard() {
  const brain = useBrainStatus()
  const activity = useProtocolActivity()

  // The committee's reply reaches the desk as a median and a count; the per-validator receipts
  // live on the brain. Where only the desk's side is in range, say what is known and no more.
  const lastVerdict = useMemo(() => {
    if (activity.status !== 'ready') return undefined
    for (const desk of activity.data.desks) {
      const windows = foldDeskWindows(desk.scan.events)
      const withVerdict = windows.find((window) => window.verdict !== undefined)
      if (withVerdict !== undefined) return withVerdict.verdict
    }
    return undefined
  }, [activity])

  return (
    <Card className="lg:col-span-2">
      <CardIcon tone="amber">
        <IconCommittee size={20} />
      </CardIcon>
      <h3 className="text-xl tracking-tighter">
        The validators <em className="not-italic text-indigo">are</em> the model
      </h3>
      <p className="mt-2.5 text-md text-ink3">
        A committee runs inference and returns a verdict on chain, each member with its own receipt.
        Policy reads the median — never an average.
      </p>

      <dl className="mt-5 flex flex-col gap-2.5 text-base">
        <Row label="Committee">
          <Value state={brain} w="7ch">
            {(b) => `${count(b.committeeSize)} validators, quorum ${count(b.committeeThreshold)}`}
          </Value>
        </Row>
        <Row label="Price stage">
          <Value state={brain} w="7ch">
            {(b) => `${count(b.feedCommitteeSize)} validators, quorum ${count(b.feedThreshold)}`}
          </Value>
        </Row>
        <Row label="Cost per verdict">
          <Value state={brain} w="6ch">{(b) => `${somiPrecise(b.quote)} SOMI`}</Value>
        </Row>
      </dl>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-dashed border-line2 pt-3 text-base text-ink4">
        <span>Last median reaching a desk</span>
        {activity.status === 'ready' ? (
          lastVerdict === undefined ? (
            <b className="font-bold text-ink4" title="No verdict reached a desk inside the scanned block range.">
              —
            </b>
          ) : (
            <b className="font-bold text-indigo">
              {probability(lastVerdict.probUpBps)}% UP · {count(lastVerdict.responded)} answered
            </b>
          )
        ) : (
          <Skeleton w="10ch" />
        )}
      </div>
    </Card>
  )
}

function ReactiveCard() {
  const subs = useSubscriptions()
  const activity = useProtocolActivity()
  const now = useNow()

  const decoded = subs.status === 'ready' ? subs.data.map(decodeSubscription) : []
  const nextTimer = decoded
    .filter((sub) => sub.firesAt !== undefined)
    .sort((a, b) => (a.firesAt ?? 0) - (b.firesAt ?? 0))[0]

  return (
    <Card className="lg:col-span-2">
      <CardIcon tone="cyan">
        <IconClock size={20} />
      </CardIcon>
      <h3 className="text-xl tracking-tighter">Reactive, not polled</h3>
      <p className="mt-2.5 text-md text-ink3">
        The router holds every subscription. Nothing polls; validators run the handler when the log
        lands, and book a one-shot timer for the decision and the settlement.
      </p>

      <ul className="mt-5 flex flex-col gap-2 text-base">
        {subs.status === 'loading' ? (
          <>
            <li className="skeleton h-4 w-full" aria-hidden="true" />
            <li className="skeleton h-4 w-4/5" aria-hidden="true" />
          </>
        ) : subs.status === 'error' ? (
          <li className="text-ink4">
            The reactivity precompile did not answer <code>somnia_reactivityGetSubscriptions</code>.
          </li>
        ) : decoded.length === 0 ? (
          <li className="text-ink4">
            The router owns no subscriptions right now. Nothing is listening, which is exactly what
            dropping below the {somi(SUBSCRIPTION_FLOOR_WEI, 0)}&nbsp;SOMI floor looks like.
          </li>
        ) : (
          decoded.map((sub) => (
            <li key={sub.id.toString()} className="flex items-baseline justify-between gap-3">
              <span className="min-w-0 truncate text-ink3">{sub.title}</span>
              <span className="shrink-0 text-sm tabular-nums text-ink5">
                {millions(sub.gasLimit)}M gas
              </span>
            </li>
          ))
        )}
      </ul>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-dashed border-line2 pt-3 text-base text-ink4">
        <span>Next scheduled wake-up</span>
        {subs.status !== 'ready' ? (
          <Skeleton w="7ch" />
        ) : nextTimer === undefined ? (
          <b
            className="font-bold text-ink4"
            title="The router books one-shot timers per window and they are consumed when they fire, so between windows there is nothing scheduled."
          >
            none booked
          </b>
        ) : now === null ? (
          <Skeleton w="7ch" />
        ) : (
          <b className="font-bold text-indigo tabular-nums" title={utcTimestamp(nextTimer.firesAt!)}>
            {countdown(nextTimer.firesAt! - now)}
          </b>
        )}
      </div>

      {activity.status === 'ready' ? (
        <p className="mt-3 text-sm text-ink5">
          {count(activity.data.considered)} windows considered in the last{' '}
          {blocksToDuration(activity.data.blocks)} of blocks.
        </p>
      ) : null}
    </Card>
  )
}

function CapitalCard() {
  const router = useRouterStatus()
  const desks = useDeskTable()

  const totalEquity =
    desks.status === 'ready' ? desks.data.reduce((sum, desk) => sum + desk.equity, 0n) : null

  return (
    <Card className="lg:col-span-2">
      <CardIcon tone="emerald">
        <IconShieldCheck size={20} />
      </CardIcon>
      <h3 className="text-xl tracking-tighter">Non-custodial by construction</h3>
      <p className="mt-2.5 text-md text-ink3">
        A desk holds its owner&rsquo;s collateral and its own outcome legs. Nothing in it can pay
        anyone but the owner, and the router never touches collateral — only the gas credit that
        pays for firings.
      </p>

      <dl className="mt-5 flex flex-col gap-2.5 text-base">
        <Row label="Equity across all desks">
          {totalEquity === null ? (
            desks.status === 'error' ? (
              <span className="text-ink5" title={desks.error.message}>—</span>
            ) : (
              <Skeleton w="8ch" />
            )
          ) : (
            `${usdc(totalEquity)} tUSDC`
          )}
        </Row>
        <Row label="Gas credit held for desks">
          <Value state={router} w="7ch">{(r) => `${somiPrecise(r.totalGasCredit)} SOMI`}</Value>
        </Row>
        <Row label="Subscription floor">
          {`${somi(SUBSCRIPTION_FLOOR_WEI, 0)} SOMI`}
        </Row>
      </dl>

      <div className="mt-3 border-t border-dashed border-line2 pt-3 text-base">
        {router.status === 'ready' ? (
          router.data.aboveFloor ? (
            <p className="text-emerald">
              <b className="font-bold">{somi(router.data.floorMargin)} SOMI</b> above the floor. The
              subscriptions renew.
            </p>
          ) : (
            <p className="text-rose">
              <b className="font-bold">{somi(-router.data.floorMargin)} SOMI</b> below the floor. The
              precompile removes subscriptions rather than failing loudly.
            </p>
          )
        ) : (
          <div className="skeleton h-4 w-3/4" aria-hidden="true" />
        )}
      </div>
    </Card>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="min-w-0 truncate text-ink4">{label}</dt>
      <dd className="shrink-0 font-semibold tracking-tight text-ink">{children}</dd>
    </div>
  )
}
