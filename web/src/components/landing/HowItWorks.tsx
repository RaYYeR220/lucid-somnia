'use client'

import { count, duration, somiPrecise } from '@/lib/format'
import { useBrainStatus, useRouterStatus } from '@/lib/hooks'
import { Card, SectionHead } from '@/components/ui/Card'
import { Value } from '@/components/ui/Value'

/**
 * The mechanism, in three steps.
 *
 * The prose is explanation and does not change; the code plate under each step carries the live
 * parameters the contracts are actually configured with, so the illustration cannot drift away
 * from the deployment it illustrates.
 */
export function HowItWorks() {
  const brain = useBrainStatus()
  const router = useRouterStatus()

  return (
    <section className="py-12 sm:py-16" aria-labelledby="how-it-works">
      <div className="wrap">
        <SectionHead
          id="how-it-works"
          kicker="How a window runs"
          title={<>Wake, ask, dispose — starting in the same block.</>}
        >
          <p>
            A five-minute market, one decision, and a permanent record either way. Every step below
            is a transaction on Somnia.
          </p>
        </SectionHead>

        <ol className="mt-10 grid gap-4 lg:grid-cols-3">
          <li>
            <Card className="h-full">
              <StepNumber>1</StepNumber>
              <h3 className="text-xl">Somnia wakes the desk</h3>
              <p className="mt-2 text-md text-ink3">
                A window opens on DreamDEX. The reactivity subscription the router owns fires its
                handler in the same block as the venue&rsquo;s own log — no cron, no worker, no
                listener of ours. The router decodes the log and asks each armed desk&rsquo;s
                pre-filter whether it wants the window.
              </p>
              <div className="plate mt-4" translate="no" tabIndex={0} role="group" aria-label="Contract call">
                <code>
                  <span className="cm">{'// runs in the same block as the event'}</span>
                  {'\n'}
                  <span className="kw">on</span> MarketCreated(<span className="st">venue</span>)
                  {'\n'}
                  {'  → '}router.onEvent(){'\n'}
                  {'  → '}fan-out to{' '}
                  <span className="st">
                    <Value state={router} w="2ch">{(r) => count(r.armedDesks.length)}</Value>
                  </span>{' '}
                  armed desk(s)
                </code>
              </div>
            </Card>
          </li>

          <li>
            <Card className="h-full">
              <StepNumber>2</StepNumber>
              <h3 className="text-xl">The committee answers</h3>
              <p className="mt-2 text-md text-ink3">
                Part-way into the window a second firing asks the brain. Stage one takes a
                cross-exchange median from a price-oracle committee; stage two asks the inference
                committee for the probability the window closes above its strike. Every member files
                its own receipt on chain, and the desk takes the median of what came back.
              </p>
              <div className="plate mt-4" translate="no" tabIndex={0} role="group" aria-label="Contract call">
                <code>
                  <span className="kw">stage 1</span> price ·{' '}
                  <span className="st">
                    <Value state={brain} w="1ch">{(b) => count(b.feedCommitteeSize)}</Value>
                  </span>{' '}
                  validators, quorum{' '}
                  <span className="st">
                    <Value state={brain} w="1ch">{(b) => count(b.feedThreshold)}</Value>
                  </span>
                  {'\n'}
                  <span className="kw">stage 2</span> verdict ·{' '}
                  <span className="st">
                    <Value state={brain} w="1ch">{(b) => count(b.committeeSize)}</Value>
                  </span>{' '}
                  validators, quorum{' '}
                  <span className="st">
                    <Value state={brain} w="1ch">{(b) => count(b.committeeThreshold)}</Value>
                  </span>
                  {'\n'}
                  cost{' '}
                  <span className="st">
                    <Value state={brain} w="5ch">{(b) => somiPrecise(b.quote)}</Value>
                  </span>{' '}
                  SOMI per verdict
                </code>
              </div>
            </Card>
          </li>

          <li>
            <Card className="h-full">
              <StepNumber>3</StepNumber>
              <h3 className="text-xl">Policy disposes</h3>
              <p className="mt-2 text-md text-ink3">
                The standing orders run in a fixed order — mandate, market, risk, committee answer,
                evidence, money — and the first failure wins. Pass and the desk trades. Fail and it
                emits a refusal carrying the arithmetic that produced it, then waits for the next
                window.
              </p>
              <div className="plate mt-4" translate="no" tabIndex={0} role="group" aria-label="Contract call">
                <code>
                  <span className="kw">emit</span> Refused({'\n'}
                  {'  '}marketId,{'\n'}
                  {'  '}reason: <span className="st">LowEdge</span>,{'\n'}
                  {'  '}probUpBps, pBookBps){'\n'}
                  <span className="cm">
                    {'// window must have ≥ '}
                  </span>
                  <span className="st">
                    <Value state={brain} w="3ch">{(b) => duration(Number(b.requiredSlack))}</Value>
                  </span>
                  <span className="cm">{' left'}</span>
                </code>
              </div>
            </Card>
          </li>
        </ol>
      </div>
    </section>
  )
}

function StepNumber({ children }: { children: React.ReactNode }) {
  return (
    <span
      aria-hidden="true"
      className="mb-4 grid h-[34px] w-[34px] place-items-center rounded-[11px] bg-ink text-lg font-extrabold text-white"
    >
      {children}
    </span>
  )
}
