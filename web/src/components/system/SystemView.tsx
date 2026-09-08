'use client'

import { useMemo } from 'react'
import {
  EXPLORER_URL,
  INDEXER_URL,
  RPC_URL,
  SUBSCRIPTION_FLOOR_WEI,
  deployed,
} from '@/lib/chain/config'
import { decodeSubscription } from '@/lib/chain/subscriptions'
import { isZeroAddress } from '@/lib/chain/reads'
import {
  blocksToDuration,
  count,
  countdown,
  duration,
  millions,
  relativeTime,
  somi,
  somiPrecise,
  utcTimestamp,
} from '@/lib/format'
import {
  SERIES_MODE_BLURB,
  seriesModeName,
  skipReasonText,
} from '@/lib/protocol'
import {
  useBlockNumber,
  useBrainStatus,
  useKeeperStatus,
  useNow,
  useRelayStatus,
  useRouterEvents,
  useRouterStatus,
  useSeriesStatus,
  useSubscriptions,
} from '@/lib/hooks'
import { Card, PageHead, SectionHead } from '@/components/ui/Card'
import {
  AddressLink,
  Badge,
  ButtonLink,
  EmptyState,
  ErrorState,
  Hairline,
  Meter,
  Stat,
  StatusBadge,
} from '@/components/ui/Primitives'
import { Dash, Skeleton, Value } from '@/components/ui/Value'
import {
  IconBolt,
  IconClock,
  IconCommittee,
  IconExternal,
  IconGauge,
  IconInfo,
  IconLink,
  IconWarn,
} from '@/components/ui/Icon'

/**
 * The machine room.
 *
 * Every other page shows what the protocol decided. This one shows the machinery that let it
 * decide, in the state it is in right now — including the parts that are switched off. A page
 * that only ever showed green would be worth nothing here.
 */
export function SystemView() {
  const router = useRouterStatus()
  const block = useBlockNumber()

  return (
    <div className="wrap py-10 sm:py-14">
      <PageHead
        eyebrow="System"
        title="The machine room"
        lede={
          <p>
            Three jobs that normally need a server — the keeper, the model and the price feed — are
            done by Somnia validators. This page is where that stops being a claim: every
            subscription, balance, counter and mode below is read live, and so is every gap.
          </p>
        }
        aside={
          <ButtonLink href={`${EXPLORER_URL}/address/${deployed.router}`} tone="default" external>
            Router on Explorer
            <IconExternal size={13} />
          </ButtonLink>
        }
      />

      <NoBackendNote block={block} />

      <RouterSection />
      <SubscriptionsSection />
      <BrainSection />
      <ComponentsSection routerStatus={router} />
      <RouterLogSection />
    </div>
  )
}

/* ============================================================================
   The claim, checkable
   ========================================================================== */

function NoBackendNote({ block }: { block: ReturnType<typeof useBlockNumber> }) {
  return (
    <Card className="mt-8" pad="lg">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:gap-6">
        <span className="grid h-10 w-10 shrink-0 place-items-center rounded-r2 bg-indigo-soft text-indigo">
          <IconInfo size={20} />
        </span>
        <div className="min-w-0">
          <h2 className="text-2xl tracking-tighter">There is no backend behind this page</h2>
          <p className="mt-2 max-w-[74ch] text-md text-ink3">
            This site is a static export with no API routes, no server actions and no database. Open
            your network tab: every request it makes goes to one of the two endpoints below, both of
            them public, and neither of them ours to keep running.
          </p>
          <dl className="mt-4 grid gap-3 sm:grid-cols-2">
            <Endpoint label="Somnia Shannon RPC" href={RPC_URL}>
              Every contract read, every log page, and the reactivity precompile&rsquo;s own
              <code translate="no"> somnia_reactivity*</code> methods.
            </Endpoint>
            <Endpoint label="DreamDEX indexer" href={INDEXER_URL}>
              The venue&rsquo;s market rows: strike, cadence, expiry and settlement. Public GraphQL,
              no auth.
            </Endpoint>
          </dl>
          <p className="mt-4 text-base text-ink4">
            Chain {deployed.chainId} · head{' '}
            {block.status === 'ready' ? (
              <b className="font-semibold tabular-nums text-ink3">{count(block.data)}</b>
            ) : block.status === 'error' ? (
              <Dash why={block.error.message} />
            ) : (
              <Skeleton w="9ch" />
            )}
          </p>
        </div>
      </div>
    </Card>
  )
}

function Endpoint({ label, href, children }: { label: string; href: string; children: React.ReactNode }) {
  return (
    <div className="rounded-r2 border border-line bg-[var(--slate-50)] px-4 py-3">
      <dt className="text-xs font-bold uppercase tracking-wide text-ink5">{label}</dt>
      <dd className="mt-1">
        <a
          href={href}
          target="_blank"
          rel="noreferrer noopener"
          translate="no"
          className="break-all rounded-[6px] text-base font-semibold text-indigo underline decoration-line2 decoration-dotted underline-offset-[3px] hover:decoration-indigo"
        >
          {href}
        </a>
        <p className="mt-1 text-base text-ink4">{children}</p>
      </dd>
    </div>
  )
}

/* ============================================================================
   Router float
   ========================================================================== */

function RouterSection() {
  const router = useRouterStatus()

  const floorPct =
    router.status === 'ready'
      ? Math.min(200, (Number(router.data.balance) / Number(SUBSCRIPTION_FLOOR_WEI)) * 100)
      : 0

  return (
    <section className="mt-12" aria-labelledby="router">
      <SectionHead
        id="router"
        kicker="The bond"
        title={<>The router must hold {somi(SUBSCRIPTION_FLOOR_WEI, 0)}&nbsp;SOMI, or nothing is listening</>}
      >
        <p>
          The precompile checks the <em>subscribing contract&rsquo;s</em> balance on every renewal,
          including each per-window one-shot. A router that slips below the floor does not fail
          loudly — its subscriptions are removed and the whole protocol goes quiet. This is the
          single most important number on the page.
        </p>
      </SectionHead>

      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2" pad="lg">
          {router.status === 'error' ? (
            <ErrorState title="The router did not answer" error={router.error} onRetry={router.refetch} />
          ) : router.status === 'loading' ? (
            <div className="space-y-3">
              <div className="skeleton h-5 w-1/2" aria-hidden="true" />
              <div className="skeleton h-2.5 w-full" aria-hidden="true" />
              <div className="skeleton h-4 w-1/3" aria-hidden="true" />
            </div>
          ) : (
            <>
              <Meter
                label="Router float against the subscription floor"
                valueText={`${somi(router.data.balance)} / ${somi(SUBSCRIPTION_FLOOR_WEI, 0)} SOMI`}
                percent={floorPct / 2}
                describedAs={`The router holds ${somi(router.data.balance)} SOMI against a ${somi(
                  SUBSCRIPTION_FLOOR_WEI,
                  0,
                )} SOMI floor. The bar is full at twice the floor, so its midpoint is the floor itself.`}
                tone={router.data.aboveFloor ? 'emerald' : 'rose'}
                footLeft={
                  router.data.aboveFloor
                    ? `${somi(router.data.floorMargin)} SOMI above the floor`
                    : `${somi(-router.data.floorMargin)} SOMI below the floor`
                }
                footRight="The bar’s midpoint is the floor; the notch is twice it"
              />
              <div className="mt-5">
                {router.data.aboveFloor ? (
                  <StatusBadge tone="emerald" pulse>
                    Subscriptions renew
                  </StatusBadge>
                ) : (
                  <StatusBadge tone="rose">
                    Below the floor — subscriptions are being removed
                  </StatusBadge>
                )}
              </div>
              <Hairline className="my-6" />
              <div className="grid gap-5 sm:grid-cols-3">
                <Stat label="SOMI earmarked as desk gas credit" size="sm" hint="Not free to pay for subscriptions.">
                  {somiPrecise(router.data.totalGasCredit)}
                </Stat>
                <Stat label="desks in the fan-out list" size="sm" hint="LucidRouter.armedDesks()">
                  {count(router.data.armedDesks.length)}
                </Stat>
                <Stat label="desks per firing, at most" size="sm" hint="MAX_FANOUT — beyond it the tail is skipped by name.">
                  {count(router.data.maxFanout)}
                </Stat>
              </div>
            </>
          )}
        </Card>

        <Card pad="lg">
          <h3 className="text-xl tracking-tighter">Why one router</h3>
          <p className="mt-2 text-md text-ink3">
            The floor is checked against whichever contract calls <code translate="no">subscribe</code>.
            A subscription per desk would lock {somi(SUBSCRIPTION_FLOOR_WEI, 0)}&nbsp;SOMI per user, which is not a product — so the
            desks share one bond rather than each posting their own. The venue subscription sits behind
            a second one, so a router that runs out of float stops booking wake-ups without also going
            deaf to the venue.
          </p>
          <dl className="mt-5 flex flex-col gap-2.5 text-base">
            <Wire label="Router">
              <AddressLink address={deployed.router} />
            </Wire>
            <Wire label="Venue watch">
              <AddressLink address={deployed.watch} />
            </Wire>
            <Wire label="Venue module">
              <Value state={router} w="12ch">{(r) => <AddressLink address={r.venueModule} />}</Value>
            </Wire>
            <Wire label="Venue id">
              <Value state={router} w="12ch">
                {(r) => (
                  <span className="tabular-nums" translate="no" title={r.venue}>
                    {`${r.venue.slice(0, 10)}…${r.venue.slice(-6)}`}
                  </span>
                )}
              </Value>
            </Wire>
            <Wire label="Handler gas">
              <Value state={router} w="6ch">{(r) => `${millions(r.handlerGasLimit)}M`}</Value>
            </Wire>
          </dl>
        </Card>
      </div>
    </section>
  )
}

/* ============================================================================
   Subscriptions
   ========================================================================== */

function SubscriptionsSection() {
  const subs = useSubscriptions()
  const now = useNow()

  const decoded = useMemo(
    () => (subs.status === 'ready' ? subs.data.map(decodeSubscription) : []),
    [subs],
  )

  return (
    <section className="mt-14" aria-labelledby="subscriptions">
      <SectionHead
        id="subscriptions"
        kicker="The keeper that is not a process"
        title="Reactivity subscriptions, in plain English"
      >
        <p>
          Read straight from the precompile over{' '}
          <code translate="no">somnia_reactivityGetSubscriptions</code> and{' '}
          <code translate="no">somnia_reactivityGetSubscriptionInfo</code>. A subscription is four
          opaque topics and a selector; what matters is the sentence they add up to.
        </p>
      </SectionHead>

      <div className="mt-6">
        {subs.status === 'loading' ? (
          <div className="grid gap-4 lg:grid-cols-2">
            {Array.from({ length: 2 }).map((_, index) => (
              <Card key={index} pad="md">
                <div className="skeleton h-5 w-1/3" aria-hidden="true" />
                <div className="skeleton mt-3 h-4 w-full" aria-hidden="true" />
                <div className="skeleton mt-2 h-4 w-2/3" aria-hidden="true" />
              </Card>
            ))}
          </div>
        ) : subs.status === 'error' ? (
          <ErrorState
            title="The reactivity precompile did not answer"
            error={subs.error}
            onRetry={subs.refetch}
          />
        ) : decoded.length === 0 ? (
          <EmptyState icon={<IconWarn size={20} />} title="No subscriptions are live">
            <p>
              Nothing is listening. This is exactly what dropping below the{' '}
              {somi(SUBSCRIPTION_FLOOR_WEI, 0)}&nbsp;SOMI floor looks
              like from the outside: no revert, no error, just a protocol that has stopped being
              woken.
            </p>
          </EmptyState>
        ) : (
          <ul className="grid gap-4 lg:grid-cols-2">
            {decoded.map((sub) => (
              <li key={sub.id.toString()}>
                <Card pad="md" className="h-full">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="flex items-center gap-2.5">
                      <span className="grid h-9 w-9 place-items-center rounded-r2 bg-indigo-soft text-indigo">
                        {sub.kind === 'timer' ? <IconClock size={17} /> : <IconBolt size={17} />}
                      </span>
                      <h3 className="text-xl tracking-tighter">{sub.title}</h3>
                    </div>
                    <Badge tone={sub.safeGas ? 'emerald' : 'rose'} title={
                      sub.safeGas
                        ? 'Provisioned above the gas floor a handler needs to actually run.'
                        : 'Below the measured gas floor: the handler would be billed for the full limit and never execute — no revert, no log.'
                    }>
                      {millions(sub.gasLimit)}M gas
                    </Badge>
                  </div>

                  <p className="mt-3 text-md text-ink3">{sub.description}</p>

                  <dl className="mt-4 flex flex-col gap-2 border-t border-line pt-4 text-base">
                    <Wire label="Subscription id">
                      <span className="tabular-nums" translate="no">
                        {sub.id.toString()}
                      </span>
                    </Wire>
                    <Wire label="Handler">
                      <AddressLink address={sub.handlerContract} />
                    </Wire>
                    <Wire label="Watches">
                      {isZeroAddress(sub.emitter) ? (
                        <span className="text-ink4">any contract</span>
                      ) : (
                        <AddressLink address={sub.emitter} />
                      )}
                    </Wire>
                    <Wire label="Paid by">
                      <AddressLink address={sub.owner} />
                    </Wire>
                    {sub.firesAt !== undefined ? (
                      <Wire label="Next wake-up">
                        {now === null ? (
                          <Skeleton w="7ch" />
                        ) : (
                          <span className="tabular-nums" title={utcTimestamp(sub.firesAt)}>
                            {sub.firesAt <= now ? 'due now' : `in ${countdown(sub.firesAt - now)}`}
                          </span>
                        )}
                      </Wire>
                    ) : null}
                  </dl>
                </Card>
              </li>
            ))}
          </ul>
        )}
      </div>

      <p className="mt-4 max-w-[80ch] text-base text-ink4">
        One-shot timers are consumed when they fire, so between windows the list holds only the
        standing log listener. That is the mechanism working, not a gap in it.
      </p>
    </section>
  )
}

/* ============================================================================
   Brain
   ========================================================================== */

function BrainSection() {
  const brain = useBrainStatus()

  return (
    <section className="mt-14" aria-labelledby="brain">
      <SectionHead
        id="brain"
        kicker="The model that is not an API key"
        title="Two validator committees, priced in SOMI"
      >
        <p>
          Stage one asks a price-oracle committee for a cross-exchange median and discards readings
          that are stale or thin. Stage two asks the inference committee for the probability the
          window closes above its strike. Both file per-validator receipts on chain.
        </p>
      </SectionHead>

      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        <Card pad="lg">
          <span className="mb-4 grid h-10 w-10 place-items-center rounded-r2 bg-amber-soft text-amber">
            <IconCommittee size={20} />
          </span>
          <h3 className="text-xl tracking-tighter">Committee sizes</h3>
          <dl className="mt-4 flex flex-col gap-2.5 text-base">
            <Wire label="Inference committee">
              <Value state={brain} w="8ch">
                {(b) => `${count(b.committeeSize)} validators, quorum ${count(b.committeeThreshold)}`}
              </Value>
            </Wire>
            <Wire label="Price committee">
              <Value state={brain} w="8ch">
                {(b) => `${count(b.feedCommitteeSize)} validators, quorum ${count(b.feedThreshold)}`}
              </Value>
            </Wire>
            <Wire label="Minimum sources per reading">
              <Value state={brain} w="2ch">{(b) => count(b.minSources)}</Value>
            </Wire>
            <Wire label="Reading discarded after">
              <Value state={brain} w="5ch">{(b) => duration(Number(b.maxFeedAgeMillis) / 1000)}</Value>
            </Wire>
          </dl>
        </Card>

        <Card pad="lg">
          <span className="mb-4 grid h-10 w-10 place-items-center rounded-r2 bg-indigo-soft text-indigo">
            <IconGauge size={20} />
          </span>
          <h3 className="text-xl tracking-tighter">What a verdict costs</h3>
          <dl className="mt-4 flex flex-col gap-2.5 text-base">
            <Wire label="Price stage">
              <Value state={brain} w="6ch">{(b) => `${somiPrecise(b.quoteStage1)} SOMI`}</Value>
            </Wire>
            <Wire label="Inference stage">
              <Value state={brain} w="6ch">{(b) => `${somiPrecise(b.quoteStage2)} SOMI`}</Value>
            </Wire>
            <Wire label="Total per window">
              <Value state={brain} w="6ch">{(b) => `${somiPrecise(b.quote)} SOMI`}</Value>
            </Wire>
            <Wire label="Brain float">
              <Value state={brain} w="6ch">{(b) => `${somi(b.balance)} SOMI`}</Value>
            </Wire>
          </dl>
          <p className="mt-4 text-sm text-ink5">
            The router splits the fee across the desks that will actually pay it, and refuses
            outright rather than spending on a window it cannot finish.
          </p>
        </Card>

        <Card pad="lg">
          <span className="mb-4 grid h-10 w-10 place-items-center rounded-r2 bg-emerald-soft text-emerald">
            <IconClock size={20} />
          </span>
          <h3 className="text-xl tracking-tighter">Self-measured latency</h3>
          <dl className="mt-4 flex flex-col gap-2.5 text-base">
            <Wire label="Required slack">
              <Value state={brain} w="5ch">{(b) => duration(Number(b.requiredSlack))}</Value>
            </Wire>
            <Wire label="Price round trip">
              {brain.status === 'ready' ? (
                brain.data.feedLatencyEma === 0n ? (
                  <span className="text-ink4" title="The brain has not completed a price stage since deployment, so it has nothing measured to report.">
                    not yet measured
                  </span>
                ) : (
                  duration(Number(brain.data.feedLatencyEma))
                )
              ) : (
                <Skeleton w="6ch" />
              )}
            </Wire>
            <Wire label="Verdict round trip">
              {brain.status === 'ready' ? (
                brain.data.verdictLatencyEma === 0n ? (
                  <span className="text-ink4" title="The brain has not completed an inference stage since deployment, so it has nothing measured to report.">
                    not yet measured
                  </span>
                ) : (
                  duration(Number(brain.data.verdictLatencyEma))
                )
              ) : (
                <Skeleton w="6ch" />
              )}
            </Wire>
          </dl>
          <p className="mt-4 text-sm text-ink5">
            The brain measures its own round trip and publishes the slack a window must have left
            before it will accept the question. A 60-second cadence can never clear it, so those
            windows are considered and refused rather than silently skipped.
          </p>
        </Card>
      </div>
    </section>
  )
}

/* ============================================================================
   Keeper, relay, series
   ========================================================================== */

function ComponentsSection({ routerStatus }: { routerStatus: ReturnType<typeof useRouterStatus> }) {
  const routerKeeper = routerStatus.status === 'ready' ? routerStatus.data.keeper : undefined
  const routerRelay = routerStatus.status === 'ready' ? routerStatus.data.relay : undefined
  const routerSeries = routerStatus.status === 'ready' ? routerStatus.data.series : undefined

  const keeper = useKeeperStatus(routerKeeper)
  const relay = useRelayStatus(routerRelay)
  const series = useSeriesStatus(routerSeries)
  const now = useNow()

  return (
    <section className="mt-14" aria-labelledby="components">
      <SectionHead
        id="components"
        kicker="The rest of the machinery"
        title="Three things the settlement firing also drives"
      >
        <p>
          The same firing that settles a desk&rsquo;s window runs the venue&rsquo;s permissionless
          upkeep, executes anybody&rsquo;s pre-signed exit, and rolls a replacement window if the
          venue&rsquo;s own scheduler has gone quiet. None of it is about our desks.
        </p>
      </SectionHead>

      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        {/* Keeper */}
        <Card pad="lg">
          <div className="flex items-start justify-between gap-3">
            <h3 className="text-xl tracking-tighter">Keeper</h3>
            {keeper.status === 'ready' ? (
              keeper.data.attachedAtRouter ? (
                <StatusBadge tone="emerald">Attached</StatusBadge>
              ) : (
                <StatusBadge tone="amber" title="The router’s keeper slot is the zero address, so the settlement firing never calls it.">
                  Not attached
                </StatusBadge>
              )
            ) : (
              <Skeleton w="7ch" />
            )}
          </div>
          <p className="mt-2 text-md text-ink3">
            Built to run DreamDEX&rsquo;s five permissionless upkeep calls for every settled market,
            not only ours. Takes no fee and holds no funds. It has not yet landed one of those calls:
            the counters beside it read five zeros and a failure count, and we have not established
            why.
          </p>

          {keeper.status === 'ready' && !keeper.data.attachedAtRouter ? (
            <p className="mt-3 flex items-start gap-2 rounded-r2 bg-amber-soft px-3 py-2.5 text-base text-amber">
              <IconWarn size={15} className="mt-0.5 shrink-0" />
              <span>
                The router&rsquo;s <code translate="no">keeper()</code> slot is unset on this
                deployment, so these counters will stay at zero until it is attached. Venue-wide
                upkeep costs roughly 8&nbsp;SOMI an hour on this testnet, so the keeper runs in
                bursts rather than continuously.
              </span>
            </p>
          ) : null}

          <dl className="mt-4 grid grid-cols-2 gap-3 border-t border-line pt-4 text-base">
            <Counter label="finalized" state={keeper} pick={(k) => k.finalized} />
            <Counter label="released" state={keeper} pick={(k) => k.released} />
            <Counter label="synced" state={keeper} pick={(k) => k.synced} />
            <Counter label="poked" state={keeper} pick={(k) => k.poked} />
            <Counter label="voided" state={keeper} pick={(k) => k.voided} />
            <Counter
              label="failures"
              state={keeper}
              pick={(k) => k.failures}
              hint="A long run of failures is the healthy case: somebody else already did the upkeep."
            />
          </dl>
          <p className="mt-4 text-sm text-ink5">
            <AddressLink address={deployed.keeper} showIcon />
          </p>
        </Card>

        {/* Relay */}
        <Card pad="lg">
          <div className="flex items-start justify-between gap-3">
            <h3 className="text-xl tracking-tighter">Relay</h3>
            {relay.status === 'ready' ? (
              relay.data.attachedAtRouter ? (
                <StatusBadge tone="emerald">Attached</StatusBadge>
              ) : (
                <StatusBadge tone="amber">Not attached</StatusBadge>
              )
            ) : (
              <Skeleton w="7ch" />
            )}
          </div>
          <p className="mt-2 text-md text-ink3">
            Universal auto-redeem, with no owner at all. Anybody signs an EIP-712 exit once and it is
            executed for them after settlement.
          </p>
          <dl className="mt-4 grid grid-cols-2 gap-3 border-t border-line pt-4 text-base">
            <Counter label="relayed" state={relay} pick={(r) => r.relayed} />
            <Counter label="failed" state={relay} pick={(r) => r.failed} />
            <Counter
              label="queue ceiling"
              state={relay}
              pick={(r) => r.maxPending}
              hint="At most this many pending exits per window."
            />
          </dl>
          <p className="mt-4 text-sm text-ink5">
            Untested with contract signatures on Shannon, so in practice this is a pre-signed
            EOA-exit relay.
          </p>
          <p className="mt-2 text-sm text-ink5">
            <AddressLink address={deployed.relay} showIcon />
          </p>
        </Card>

        {/* Series */}
        <Card pad="lg">
          <div className="flex items-start justify-between gap-3">
            <h3 className="text-xl tracking-tighter">Failover watcher</h3>
            {series.status === 'ready' ? (
              <Badge tone={series.data.mode === 1 ? 'indigo' : series.data.mode === 2 ? 'amber' : 'slate'}>
                {seriesModeName(series.data.mode)}
              </Badge>
            ) : (
              <Skeleton w="8ch" />
            )}
          </div>
          <p className="mt-2 text-md text-ink3">
            {series.status === 'ready'
              ? (SERIES_MODE_BLURB[seriesModeName(series.data.mode)] ??
                'A mode this build does not recognise.')
              : 'Rolls a replacement window when the venue’s own scheduler stops rolling theirs.'}
          </p>

          <div className="mt-4 border-t border-line pt-4">
            {series.status === 'ready' ? (
              <>
                <div className="flex items-center gap-2">
                  {series.data.venueHealthy ? (
                    <StatusBadge tone="emerald" pulse>
                      Venue healthy
                    </StatusBadge>
                  ) : (
                    <StatusBadge tone="rose">Venue stale</StatusBadge>
                  )}
                  <span className="text-base text-ink4">
                    {series.data.venueHealthy
                      ? 'nothing is being spent'
                      : 'the roller will step in'}
                  </span>
                </div>
                <dl className="mt-3 flex flex-col gap-2 text-base">
                  <Wire label="Last venue window seen">
                    {now === null ? (
                      <Skeleton w="8ch" />
                    ) : series.data.lastVenueMarketAt === 0n ? (
                      <span className="text-ink4">never</span>
                    ) : (
                      <span title={utcTimestamp(Number(series.data.lastVenueMarketAt))}>
                        {relativeTime(Number(series.data.lastVenueMarketAt), now)}
                      </span>
                    )}
                  </Wire>
                  <Wire label="Considered stale after">
                    {duration(series.data.stalenessSeconds)}
                  </Wire>
                  <Wire label="Watched cadence">{duration(series.data.intervalSec)}</Wire>
                  <Wire label="Rolls today">
                    {`${count(series.data.rollsToday)} / ${count(series.data.maxRollsPerDay)}`}
                  </Wire>
                  <Wire label="Last roll">
                    {series.data.lastRollAt === 0n ? (
                      <span className="text-ink4" title="The roller has never had to step in.">
                        never
                      </span>
                    ) : now === null ? (
                      <Skeleton w="8ch" />
                    ) : (
                      <span title={utcTimestamp(Number(series.data.lastRollAt))}>
                        {relativeTime(Number(series.data.lastRollAt), now)}
                      </span>
                    )}
                  </Wire>
                  <Wire label="Creator float">
                    {`${somi(series.data.creatorFloat)} / ${somi(series.data.minCreatorFloat, 0)} SOMI`}
                  </Wire>
                </dl>
              </>
            ) : series.status === 'error' ? (
              <p className="text-base text-ink4">The failover watcher did not answer.</p>
            ) : (
              <div className="space-y-2">
                <div className="skeleton h-4 w-1/2" aria-hidden="true" />
                <div className="skeleton h-4 w-2/3" aria-hidden="true" />
                <div className="skeleton h-4 w-1/3" aria-hidden="true" />
              </div>
            )}
          </div>
          <p className="mt-4 text-sm text-ink5">
            <AddressLink address={deployed.series} showIcon />
          </p>
        </Card>
      </div>
    </section>
  )
}

function Counter<T>({
  label,
  state,
  pick,
  hint,
}: {
  label: string
  state: { status: string; data?: T; error?: Error }
  pick: (value: T) => bigint
  hint?: string
}) {
  return (
    <div title={hint}>
      <dt className="text-xs font-semibold uppercase tracking-wide text-ink5">{label}</dt>
      <dd className="mt-0.5 text-xl font-bold tabular-nums text-ink">
        {state.status === 'ready' && state.data !== undefined ? (
          count(pick(state.data))
        ) : state.status === 'error' ? (
          <Dash why={state.error?.message ?? 'the read did not complete in your browser'} />
        ) : (
          <Skeleton w="3ch" />
        )}
      </dd>
    </div>
  )
}

/* ============================================================================
   Router log
   ========================================================================== */

function RouterLogSection() {
  const events = useRouterEvents(14)

  const allSkips = useMemo(
    () => (events.status === 'ready' ? events.data.events.filter((event) => event.name === 'Skipped') : []),
    [events],
  )

  // Eight identical rows say less than one row and a count, so the reasons are tallied first and
  // the most recent few kept as examples.
  const skipTally = useMemo(() => {
    const byReason = new Map<string, number>()
    for (const skip of allSkips) {
      if (skip.name !== 'Skipped') continue
      byReason.set(skip.reason, (byReason.get(skip.reason) ?? 0) + 1)
    }
    return [...byReason.entries()]
      .map(([reason, total]) => ({ reason, total }))
      .sort((a, b) => b.total - a.total)
  }, [allSkips])

  const skips = allSkips.slice(0, 6)

  const seen = events.status === 'ready' ? events.data.events.filter((e) => e.name === 'MarketSeen').length : 0

  return (
    <section className="mt-14" aria-labelledby="router-log">
      <SectionHead id="router-log" kicker="The router’s own voice" title="What was skipped, and why">
        <p>
          When the router cannot hand a window to a desk it says so by name rather than dropping it.
          Every reason below is a string the contract emitted, translated into a sentence.
        </p>
      </SectionHead>

      <div className="mt-6">
        {events.status === 'loading' ? (
          <Card pad="none">
            {Array.from({ length: 3 }).map((_, index) => (
              <div key={index} className="border-b border-line px-4 py-4 last:border-0">
                <div className="skeleton h-4 w-1/3" aria-hidden="true" />
              </div>
            ))}
          </Card>
        ) : events.status === 'error' ? (
          <ErrorState title="The router log scan did not complete" error={events.error} onRetry={events.refetch} />
        ) : (
          <>
            <div className="mb-3 flex flex-wrap items-center gap-3 text-base text-ink4">
              <Badge tone="slate">last {blocksToDuration(events.data.blocks)} of blocks</Badge>
              <span>
                {count(seen)} window{seen === 1 ? '' : 's'} seen · {count(allSkips.length)} skip
                {allSkips.length === 1 ? '' : 's'}
              </span>
            </div>
            {skipTally.length > 0 ? (
              <ul className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {skipTally.map((entry) => (
                  <li
                    key={entry.reason}
                    className="rounded-r2 border border-line bg-surface px-4 py-3 shadow-card"
                  >
                    <div className="flex items-baseline justify-between gap-3">
                      <Badge tone="amber">
                        <span translate="no">{entry.reason}</span>
                      </Badge>
                      <b className="text-xl font-bold tabular-nums text-ink">{count(entry.total)}</b>
                    </div>
                    <p className="mt-1.5 text-base text-ink3">{skipReasonText(entry.reason)}</p>
                  </li>
                ))}
              </ul>
            ) : null}

            {skips.length === 0 ? (
              <EmptyState icon={<IconLink size={20} />} title="Nothing was skipped">
                <p>
                  Across the scanned range the router handed every window it decoded to the desks
                  that wanted it. Nothing was dropped and nothing needed explaining.
                </p>
              </EmptyState>
            ) : (
              <Card pad="none" className="overflow-hidden">
                <p className="border-b border-line bg-[var(--slate-50)] px-4 py-2.5 text-sm font-semibold uppercase tracking-wide text-ink5">
                  The {count(skips.length)} most recent
                </p>
                <ul className="divide-y divide-line">
                  {skips.map((skip) =>
                    skip.name === 'Skipped' ? (
                      <li
                        key={`${skip.transactionHash}-${skip.logIndex}`}
                        className="flex flex-col gap-1.5 px-4 py-3.5 sm:flex-row sm:items-center sm:gap-4"
                      >
                        <Badge tone="amber" className="self-start" title={skipReasonText(skip.reason)}>
                          <span translate="no">{skip.reason}</span>
                        </Badge>
                        <span className="min-w-0 flex-1 text-base text-ink3">
                          {skipReasonText(skip.reason)}
                        </span>
                        <span className="shrink-0 text-sm text-ink5">
                          {isZeroAddress(skip.desk) ? (
                            <span title="A zero desk address means the whole fan-out for that window was skipped, not one participant.">
                              whole fan-out
                            </span>
                          ) : (
                            <>
                              desk <AddressLink address={skip.desk} className="no-underline" />
                            </>
                          )}
                        </span>
                      </li>
                    ) : null,
                  )}
                </ul>
              </Card>
            )}
          </>
        )}
      </div>
    </section>
  )
}

/* ============================================================================
   Shared row
   ========================================================================== */

function Wire({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="min-w-0 shrink text-ink4">{label}</dt>
      <dd className="min-w-0 shrink-0 text-right font-semibold text-ink">{children}</dd>
    </div>
  )
}
