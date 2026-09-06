'use client'

import { EXPLORER_URL, deployed } from '@/lib/chain/config'
import { count, somiPrecise, usdc } from '@/lib/format'
import { useDeskTable, useRouterStatus } from '@/lib/hooks'
import { Card, PageHead } from '@/components/ui/Card'
import {
  AddressLink,
  ButtonLink,
  EmptyState,
  ErrorState,
  Stat,
} from '@/components/ui/Primitives'
import { Dash } from '@/components/ui/Value'
import { IconExternal, IconInbox, IconWallet } from '@/components/ui/Icon'
import { DeskTable } from './DeskTable'

export function DesksView() {
  const desks = useDeskTable()
  const router = useRouterStatus()

  const totals =
    desks.status === 'ready'
      ? {
          count: desks.data.length,
          equity: desks.data.reduce((sum, desk) => sum + desk.equity, 0n),
          spentToday: desks.data.reduce((sum, desk) => sum + desk.state.spentToday, 0n),
          open: desks.data.reduce((sum, desk) => sum + desk.state.openMarkets, 0),
          armed: desks.data.filter((desk) => desk.armedAtRouter && desk.policy.armed).length,
        }
      : null

  return (
    <div className="wrap py-10 sm:py-14">
      <PageHead
        eyebrow="Desks"
        title="Every desk the factory has made"
        lede={
          <p>
            One desk per address, non-custodial, holding its owner&rsquo;s collateral and its own
            outcome legs. The armed state is two flags — what the mandate says, and whether the
            router will actually hand it a window.
          </p>
        }
        aside={
          <ButtonLink href={`${EXPLORER_URL}/address/${deployed.factory}`} tone="default" external>
            Factory on Explorer
            <IconExternal size={13} />
          </ButtonLink>
        }
      />

      <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <SummaryCard label="desks created" hint="LucidFactory.allDesks()">
          {totals === null ? <Placeholder state={desks.status} w="2ch" /> : count(totals.count)}
        </SummaryCard>
        <SummaryCard label="armed and registered" hint="Armed in the mandate and in the router’s fan-out list.">
          {totals === null ? <Placeholder state={desks.status} w="2ch" /> : count(totals.armed)}
        </SummaryCard>
        <SummaryCard label="tUSDC of equity across all desks" hint="Free collateral plus open notional, at cost.">
          {totals === null ? <Placeholder state={desks.status} w="7ch" /> : usdc(totals.equity)}
        </SummaryCard>
        <SummaryCard label="SOMI of gas credit at the router" hint="LucidRouter.totalGasCredit()">
          {router.status === 'ready' ? (
            somiPrecise(router.data.totalGasCredit)
          ) : router.status === 'error' ? (
            <Dash why={router.error.message} />
          ) : (
            <Placeholder state={router.status} w="6ch" />
          )}
        </SummaryCard>
      </div>

      <section className="mt-8" aria-label="All desks" aria-busy={desks.status === 'loading'}>
        {desks.status === 'loading' ? (
          <TableSkeleton />
        ) : desks.status === 'error' ? (
          <ErrorState
            level="h2"
            title="The desk list did not load"
            error={desks.error}
            onRetry={desks.refetch}
          />
        ) : desks.data.length === 0 ? (
          <EmptyState
            level="h2"
            icon={<IconInbox size={20} />}
            title="No desk has been created yet"
            action={
              <ButtonLink href={`${EXPLORER_URL}/address/${deployed.factory}`} tone="default" external>
                Inspect the Factory
                <IconExternal size={13} />
              </ButtonLink>
            }
          >
            <p>
              <code translate="no">LucidFactory.allDesks()</code> returned an empty list. The
              factory is deployed and the router is armed — there is simply nobody trading yet.
              A desk appears here the moment its owner&rsquo;s <code translate="no">createDesk</code>{' '}
              transaction lands, with no indexing step in between.
            </p>
          </EmptyState>
        ) : (
          <>
            <DeskTable desks={desks.data} />
            <p className="mt-3 text-base text-ink4">
              Every row is read straight from <code translate="no">LucidDesk</code> and{' '}
              <code translate="no">LucidRouter</code> by your browser. Shannon has no Multicall3, so
              these are concurrent calls rather than one atomic snapshot: fine for a status view,
              wrong as a ledger.
            </p>
          </>
        )}
      </section>

      <Card className="mt-8" pad="lg">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:gap-8">
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-r2 bg-indigo-soft text-indigo">
            <IconWallet size={20} />
          </span>
          <div>
            <h2 className="text-2xl tracking-tighter">Where the money actually sits</h2>
            <p className="mt-2 max-w-[74ch] text-md text-ink3">
              A desk holds its own tUSDC and its own ERC-6909 outcome legs. Nothing in it can pay
              anyone but its owner. The router never touches collateral — it holds only the SOMI gas
              credit that pays for handler firings and committee deposits, and a desk with none is
              skipped by name with{' '}
              <code translate="no">Skipped(NO_CREDIT)</code> rather than quietly dropped.
            </p>
            <p className="mt-3 flex flex-wrap gap-x-3 gap-y-1 text-base text-ink4">
              <span>
                Factory <AddressLink address={deployed.factory} />
              </span>
              <span aria-hidden="true">·</span>
              <span>
                Router <AddressLink address={deployed.router} />
              </span>
              <span aria-hidden="true">·</span>
              <span>
                Clone implementation <AddressLink address={deployed.deskImplementation} />
              </span>
            </p>
          </div>
        </div>
      </Card>
    </div>
  )
}

function SummaryCard({
  label,
  hint,
  children,
}: {
  label: string
  hint: string
  children: React.ReactNode
}) {
  return (
    <Card pad="sm">
      <Stat label={label} hint={hint} size="lg">
        {children}
      </Stat>
    </Card>
  )
}

function Placeholder({ state, w }: { state: 'loading' | 'ready' | 'error'; w: string }) {
  if (state === 'error') return <Dash why="the read did not complete in your browser" />
  return <span className="skeleton inline-block h-[1em] align-middle" style={{ width: w }} aria-hidden="true" />
}

function TableSkeleton() {
  return (
    <div className="overflow-hidden rounded-r4 border border-line bg-surface shadow-card">
      <div className="border-b border-line px-4 py-3">
        <div className="skeleton h-3 w-1/3" aria-hidden="true" />
      </div>
      {Array.from({ length: 4 }).map((_, index) => (
        <div key={index} className="flex items-center gap-6 border-b border-line px-4 py-4 last:border-0">
          <div className="skeleton h-4 w-1/4" aria-hidden="true" />
          <div className="skeleton h-4 w-1/6" aria-hidden="true" />
          <div className="skeleton h-4 w-1/6" aria-hidden="true" />
          <div className="skeleton h-4 w-1/6" aria-hidden="true" />
          <div className="skeleton h-4 w-1/12" aria-hidden="true" />
        </div>
      ))}
    </div>
  )
}
