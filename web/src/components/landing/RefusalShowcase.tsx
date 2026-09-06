'use client'

import { blocksToDuration, count } from '@/lib/format'
import { useProtocolActivity } from '@/lib/hooks'
import { ButtonLink } from '@/components/ui/Primitives'
import { RefusalTally } from '@/components/domain/Refusal'

/**
 * The dark band.
 *
 * The headline is derived from the scan, not written into the page, so it cannot claim a
 * refusal rate the chain does not currently show. On a quiet range it says the range was quiet.
 */
export function RefusalShowcase() {
  const activity = useProtocolActivity()

  const headline =
    activity.status === 'ready'
      ? activity.data.considered === 0
        ? 'No window reached a desk in the scanned range. Nothing is hidden by that — the log is simply empty.'
        : `${count(activity.data.refused)} of the last ${count(activity.data.considered)} windows ended in a refusal. That is the desk working.`
      : null

  return (
    <section className="pb-16 sm:pb-24" aria-labelledby="refusals">
      <div className="wrap">
        <div className="relative overflow-hidden rounded-r4 bg-ink p-7 text-[#e2e8f0] sm:p-10 lg:p-14">
          <div
            aria-hidden="true"
            className="pointer-events-none absolute -right-[140px] -top-[140px] h-[520px] w-[520px]"
            style={{ background: 'radial-gradient(closest-side,rgba(190,18,60,.32),transparent 70%)' }}
          />
          <div className="relative grid items-center gap-10 lg:grid-cols-[minmax(0,1fr)_320px]">
            <div>
              <p className="text-[13px] font-bold uppercase tracking-widest text-[#fda4af]">
                Designed, not swallowed
              </p>
              <h2 id="refusals" className="mt-3 text-[clamp(26px,3.4vw,42px)] tracking-tightest text-white">
                {headline ?? (
                  <>
                    {/* The heading always has a name; only its live half is a skeleton. */}
                    <span className="sr-only">Counting refusals in the scanned range…</span>
                    <span
                      className="skeleton block h-[1.6em] w-full max-w-[24ch] !bg-[#1e293b]"
                      aria-hidden="true"
                    />
                  </>
                )}
              </h2>
              <p className="mt-4 max-w-[62ch] text-[17px] text-[#94a3b8]">
                Most automated traders fail quietly: a caught exception, a skipped tick, a log line
                nobody reads. Lucid makes the opposite promise.{' '}
                <b className="font-semibold text-white">
                  Every decision not to trade is an on-chain event with a reason code and the numbers
                  that produced it
                </b>{' '}
                — countable, auditable, and visible to anyone holding a copy of the chain.
              </p>
              <div className="mt-6 flex flex-wrap gap-3">
                <ButtonLink href="/desks/" tone="primary">
                  Browse the Refusal Logs
                </ButtonLink>
                <ButtonLink href="/windows/" tone="inverse">
                  See What Lucid Did With Each Window
                </ButtonLink>
              </div>
            </div>

            {activity.status === 'ready' ? (
              <RefusalTally
                tally={activity.data.refusalTally}
                total={activity.data.refused}
                footnote={`last ${blocksToDuration(activity.data.blocks)} of blocks`}
              />
            ) : activity.status === 'error' ? (
              <div className="rounded-r2 border border-[#1e293b] bg-[#111c2f] px-5 py-8 text-center">
                <p className="text-md font-semibold text-[#e2e8f0]">The log scan did not complete</p>
                <p className="mt-1.5 text-base text-ink-on-dark">{activity.error.message}</p>
              </div>
            ) : (
              <div className="flex flex-col gap-px overflow-hidden rounded-r2 border border-[#1e293b] bg-[#1e293b]">
                {Array.from({ length: 5 }).map((_, index) => (
                  <div key={index} className="flex items-center gap-3 bg-[#111c2f] px-4 py-3">
                    <span className="skeleton h-2 w-2 rounded-full !bg-[#1e293b]" aria-hidden="true" />
                    <span className="skeleton h-3 flex-1 !bg-[#1e293b]" aria-hidden="true" />
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  )
}
