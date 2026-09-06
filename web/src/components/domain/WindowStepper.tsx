'use client'

import { clsx } from '@/lib/clsx'
import type { BrainEvent } from '@/lib/chain/logs'
import type { DeskWindow } from '@/lib/chain/logs'
import { contractPrice, count, probability, signedUsdc, strikePrice } from '@/lib/format'
import { isBookUnobserved, orderKindName, refusalName } from '@/lib/protocol'
import { IconCheck, IconCross } from '@/components/ui/Icon'

/**
 * How a step actually went. `unknown` is a first-class outcome and not a synonym for failure:
 * history here is read over a bounded span of blocks, and a step whose log fell outside that span
 * did not fail — it was not looked at.
 */
export type StepState = 'done' | 'live' | 'failed' | 'skipped' | 'unknown'

export interface Step {
  key: string
  title: string
  detail: string
  state: StepState
}

/**
 * The seven stages one window passes through, derived from the logs and from nothing else.
 *
 * The desk contributes `Considered`, `VerdictReceived`, `Executed`, `Refused` and `Settled`; the
 * brain contributes the price stage and the committee request. Where the brain's logs fall
 * outside the scanned span the two middle steps report `unknown` rather than inventing a result.
 */
export function buildSteps(window: DeskWindow, brainEvents: readonly BrainEvent[]): Step[] {
  const forMarket = brainEvents.filter(
    (event) => 'marketId' in event && event.marketId.toLowerCase() === window.marketId.toLowerCase(),
  )
  const priceOk = forMarket.find((e) => e.name === 'PriceReceived')
  const priceBad = forMarket.find(
    (e) => e.name === 'PriceGuardRejected' || e.name === 'PriceUnusable' || e.name === 'NoFeed',
  )
  const asked = forMarket.find((e) => e.name === 'VerdictRequested')
  const tooTight = forMarket.find((e) => e.name === 'WindowTooTight' || e.name === 'LateAbort')

  const refused = window.refusal !== undefined
  const executed = window.executions.length > 0
  const settled = window.settlement !== undefined

  const priceStep: Step =
    priceOk !== undefined && priceOk.name === 'PriceReceived'
      ? {
          key: 'price',
          title: 'Price Fetched',
          detail: `Median of ${count(priceOk.used)} validator readings: ${strikePrice(priceOk.spot)}.`,
          state: 'done',
        }
      : priceBad !== undefined
        ? {
            key: 'price',
            title: 'Price Fetched',
            detail:
              priceBad.name === 'PriceGuardRejected'
                ? 'Readings were discarded as stale or thin before the median.'
                : priceBad.name === 'NoFeed'
                  ? 'No price feed is configured for this asset.'
                  : 'The committee’s readings could not be used.',
            state: 'failed',
          }
        : {
            key: 'price',
            title: 'Price Fetched',
            detail: 'No price log inside the scanned block range.',
            state: 'unknown',
          }

  const askStep: Step =
    asked !== undefined && asked.name === 'VerdictRequested'
      ? {
          key: 'ask',
          title: 'Committee Asked',
          detail: `${count(asked.size)} validators, quorum ${count(asked.threshold)}.`,
          state: 'done',
        }
      : tooTight !== undefined
        ? {
            key: 'ask',
            title: 'Committee Asked',
            detail: 'The window was too short for the round trip; nothing was spent.',
            state: 'failed',
          }
        : {
            key: 'ask',
            title: 'Committee Asked',
            detail: 'No request log inside the scanned block range.',
            state: 'unknown',
          }

  const verdictStep: Step =
    window.verdict !== undefined
      ? {
          key: 'verdict',
          title: 'Verdict Returned',
          detail: `${count(window.verdict.responded)} validators answered. Median ${probability(window.verdict.probUpBps)}% UP.`,
          state: 'done',
        }
      : { key: 'verdict', title: 'Verdict Returned', detail: 'No verdict reached this desk.', state: 'unknown' }

  const gateStep: Step =
    refused || executed
      ? {
          key: 'gate',
          title: 'Policy Gate',
          detail: refused
            ? `The mandate stopped at ${refusalName(window.refusal!.reason)}.`
            : 'Every standing order passed.',
          state: refused ? 'failed' : 'done',
        }
      : { key: 'gate', title: 'Policy Gate', detail: 'The gate has not run yet.', state: 'unknown' }

  const actStep: Step = refused
    ? {
        key: 'act',
        title: 'Refused',
        detail: 'Written on chain with the numbers that produced it. No order placed.',
        state: 'failed',
      }
    : executed
      ? {
          key: 'act',
          title: 'Executed',
          detail: window.executions
            .map((e) => `${orderKindName(e.kind)} ${count(Number(e.quantity))} @ ${contractPrice(e.price)}`)
            .join(' · '),
          state: 'done',
        }
      : { key: 'act', title: 'Executed or Refused', detail: 'The window has not resolved yet.', state: 'unknown' }

  const settleStep: Step = settled
    ? {
        key: 'settle',
        title: 'Settled',
        detail: `Booked ${signedUsdc(window.settlement!.pnl)} tUSDC.`,
        state: 'done',
      }
    : refused
      ? { key: 'settle', title: 'Settled', detail: 'Skipped — there was nothing to settle.', state: 'skipped' }
      : { key: 'settle', title: 'Settled', detail: 'Waiting for the settlement firing.', state: 'unknown' }

  return [
    {
      key: 'considered',
      title: 'Considered',
      detail: window.considered
        ? 'The router woke the desk in the same block as the venue’s log.'
        : 'No Considered log inside the scanned block range.',
      state: window.considered ? 'done' : 'unknown',
    },
    priceStep,
    askStep,
    verdictStep,
    gateStep,
    actStep,
    settleStep,
  ]
}

/**
 * The loop, drawn.
 *
 * Colour is never the only signal: a failed step carries a cross, a done step a tick, and an
 * unknown step neither, plus a dashed border and an explicit sentence.
 */
export function WindowStepper({ steps }: { steps: readonly Step[] }) {
  return (
    // `auto-fit` rather than fixed breakpoints: this stepper sits in a full-width card on one
    // page and in a narrower column on another, and a column count tied to the viewport does not
    // know the difference — at 90 px a step title breaks mid-word.
    <ol className="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-2.5">
      {steps.map((step, index) => (
        <li
          key={step.key}
          className={clsx(
            'relative min-w-0 rounded-r2 border p-3.5 transition-[background-color,border-color,box-shadow] duration-300',
            step.state === 'done' && 'border-[#c7d2fe] bg-surface shadow-[0_1px_2px_rgba(79,70,229,.1)]',
            step.state === 'live' && 'border-indigo bg-surface shadow-ring',
            step.state === 'failed' && 'border-rose-line bg-rose-soft',
            step.state === 'skipped' && 'border-line bg-[var(--slate-50)] opacity-70',
            step.state === 'unknown' && 'border-dashed border-line2 bg-[var(--slate-50)]',
          )}
        >
          <p className="text-2xs font-bold uppercase tracking-[.09em] text-ink5">Step {index + 1}</p>
          <div className="mt-1 flex items-start justify-between gap-2">
            <h3
              className={clsx(
                'min-w-0 break-words text-md font-bold tracking-tight',
                step.state === 'failed' ? 'text-rose' : 'text-ink',
              )}
            >
              {step.title}
            </h3>
            {step.state === 'done' ? (
              <span className="mt-0.5 grid h-[18px] w-[18px] shrink-0 place-items-center rounded-full bg-indigo text-white">
                <IconCheck size={10} />
              </span>
            ) : step.state === 'failed' ? (
              <span className="mt-0.5 grid h-[18px] w-[18px] shrink-0 place-items-center rounded-full bg-rose text-white">
                <IconCross size={10} />
              </span>
            ) : null}
          </div>
          <p className="mt-1 text-sm text-ink4">{step.detail}</p>
        </li>
      ))}
    </ol>
  )
}

/**
 * The book-implied probability, rendered so that "no quotes" can never be mistaken for "quoted
 * at 50 %". The protocol carries `type(uint16).max` for the first case; this is the only place
 * that distinction is turned into words.
 */
export function BookProbability({ pBookBps, className }: { pBookBps: number; className?: string }) {
  if (isBookUnobserved(pBookBps)) {
    return (
      <span
        className={clsx('inline-flex items-center gap-1.5 font-semibold text-ink4', className)}
        title="The protocol carries a sentinel meaning no side of the book quoted. An empty book is the absence of a market price, not a market price of 50 %."
      >
        <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-ink5" />
        No quotes
      </span>
    )
  }
  return (
    <span className={clsx('tabular-nums', className)} title="The book-implied probability the window closes up.">
      {probability(pBookBps)}%
    </span>
  )
}

