import Link from 'next/link'
import type { ReactNode } from 'react'
import { clsx } from '@/lib/clsx'
import { explorerAddress, explorerBlock, explorerTx } from '@/lib/chain/config'
import { percent as formatPercent, shortAddress } from '@/lib/format'
import { IconExternal } from './Icon'

/* ============================================================================
   Buttons and links
   ========================================================================== */

type ButtonTone = 'primary' | 'default' | 'ghost' | 'inverse'
type ButtonSize = 'sm' | 'md' | 'lg'

function buttonClass(tone: ButtonTone, size: ButtonSize, className?: string): string {
  return clsx(
    'inline-flex items-center justify-center gap-2 rounded-[10px] font-semibold',
    'transition-[transform,box-shadow,background-color,border-color] duration-150 ease-out',
    '[touch-action:manipulation]',
    size === 'sm' && 'h-9 px-3.5 text-base',
    size === 'md' && 'h-10 px-4 text-md',
    size === 'lg' && 'h-12 px-5 text-lg',
    tone === 'primary' &&
      'border border-transparent bg-gradient-to-br from-violet to-indigo text-white shadow-primary hover:-translate-y-px hover:shadow-primaryHover',
    tone === 'default' &&
      'border border-line bg-surface text-ink shadow-btn hover:border-line2 hover:bg-[var(--slate-50)]',
    tone === 'ghost' && 'border border-transparent text-ink3 hover:bg-slate1 hover:text-ink',
    tone === 'inverse' && 'border border-[#334155] bg-transparent text-[#e2e8f0] hover:bg-[#1e293b]',
    className,
  )
}

export function ButtonLink({
  href,
  tone = 'default',
  size = 'md',
  className,
  children,
  external = false,
}: {
  href: string
  tone?: ButtonTone
  size?: ButtonSize
  className?: string
  children: ReactNode
  external?: boolean
}) {
  if (external) {
    return (
      <a
        href={href}
        target="_blank"
        rel="noreferrer noopener"
        className={buttonClass(tone, size, className)}
      >
        {children}
        <span className="sr-only"> (opens in a new tab)</span>
      </a>
    )
  }
  return (
    <Link href={href} className={buttonClass(tone, size, className)}>
      {children}
    </Link>
  )
}

/* ============================================================================
   Badges
   ========================================================================== */

export type BadgeTone = 'indigo' | 'emerald' | 'rose' | 'amber' | 'slate' | 'cyan'

export function Badge({
  tone = 'slate',
  children,
  className,
  title,
}: {
  tone?: BadgeTone
  children: ReactNode
  className?: string
  title?: string
}) {
  return (
    <span
      title={title}
      className={clsx(
        'inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-0.5 text-sm font-bold',
        tone === 'indigo' && 'bg-indigo-soft text-indigo',
        tone === 'emerald' && 'bg-emerald-soft text-emerald',
        tone === 'rose' && 'bg-rose-soft text-rose',
        tone === 'amber' && 'bg-amber-soft text-amber',
        tone === 'cyan' && 'bg-[#ECFEFF] text-cyan',
        tone === 'slate' && 'bg-slate1 text-ink4',
        className,
      )}
    >
      {children}
    </span>
  )
}

/** A badge with a leading dot, for a state rather than a label. */
export function StatusBadge({
  tone,
  children,
  title,
  pulse = false,
}: {
  tone: BadgeTone
  children: ReactNode
  title?: string
  pulse?: boolean
}) {
  return (
    <Badge tone={tone} title={title}>
      <span
        aria-hidden="true"
        className={clsx(
          'h-[7px] w-[7px] shrink-0 rounded-full bg-current',
          pulse && 'motion-safe:animate-blink',
        )}
      />
      {children}
    </Badge>
  )
}

/* ============================================================================
   Explorer links — every on-chain value in this app is one click from its proof.
   ========================================================================== */

export function AddressLink({
  address,
  label,
  className,
  mono = true,
  showIcon = false,
}: {
  address: string
  label?: string
  className?: string
  mono?: boolean
  showIcon?: boolean
}) {
  return (
    <a
      href={explorerAddress(address)}
      target="_blank"
      rel="noreferrer noopener"
      translate="no"
      title={`${address} — open on Shannon Explorer`}
      aria-label={`${label ?? address}, open on Shannon Explorer in a new tab`}
      className={clsx(
        'inline-flex items-center gap-1.5 rounded-[6px] underline decoration-line2 decoration-dotted underline-offset-[3px] transition-colors hover:decoration-indigo hover:text-indigo',
        mono && 'tabular-nums',
        className,
      )}
    >
      {label ?? shortAddress(address)}
      {showIcon ? <IconExternal size={12} /> : null}
    </a>
  )
}

export function TxLink({ hash, children }: { hash: string; children?: ReactNode }) {
  return (
    <a
      href={explorerTx(hash)}
      target="_blank"
      rel="noreferrer noopener"
      translate="no"
      title={`${hash} — open the transaction on Shannon Explorer`}
      aria-label={`Transaction ${hash}, open on Shannon Explorer in a new tab`}
      className="inline-flex items-center gap-1.5 rounded-[6px] underline decoration-line2 decoration-dotted underline-offset-[3px] transition-colors hover:text-indigo hover:decoration-indigo"
    >
      {children ?? shortAddress(hash)}
    </a>
  )
}

export function BlockLink({ block, children }: { block: bigint; children?: ReactNode }) {
  return (
    <a
      href={explorerBlock(block)}
      target="_blank"
      rel="noreferrer noopener"
      translate="no"
      title={`Block ${block.toString()} — open on Shannon Explorer`}
      aria-label={`Block ${block.toString()}, open on Shannon Explorer in a new tab`}
      className="inline-flex items-center gap-1.5 rounded-[6px] tabular-nums underline decoration-line2 decoration-dotted underline-offset-[3px] transition-colors hover:text-indigo hover:decoration-indigo"
    >
      {children ?? block.toString()}
    </a>
  )
}

/* ============================================================================
   Stats
   ========================================================================== */

/** A number with its label beneath it — the shape used in the hero and every card footer. */
export function Stat({
  label,
  children,
  hint,
  size = 'md',
  tone,
}: {
  label: ReactNode
  children: ReactNode
  hint?: string
  size?: 'sm' | 'md' | 'lg'
  tone?: 'default' | 'emerald' | 'rose' | 'indigo'
}) {
  return (
    <div className="min-w-0">
      <div
        className={clsx(
          'font-extrabold tracking-tighter text-ink',
          size === 'sm' && 'text-xl',
          size === 'md' && 'text-3xl',
          size === 'lg' && 'text-[clamp(24px,3vw,32px)]',
          tone === 'emerald' && 'text-emerald',
          tone === 'rose' && 'text-rose',
          tone === 'indigo' && 'text-indigo',
        )}
      >
        {children}
      </div>
      <div className="mt-0.5 text-base text-ink4" title={hint}>
        {label}
      </div>
    </div>
  )
}

/**
 * A key above a value, uppercase and small — the frame-header treatment.
 *
 * Renders a real `dt`/`dd` pair, because every caller puts these inside a `<dl>`: a definition
 * list whose children are anonymous `div`s is a list of nothing as far as assistive tech is
 * concerned.
 */
export function KeyValue({
  label,
  children,
  align = 'left',
}: {
  label: ReactNode
  children: ReactNode
  align?: 'left' | 'right'
}) {
  return (
    <div className={clsx('min-w-0', align === 'right' && 'text-right')}>
      <dt className="text-xs font-semibold uppercase tracking-wide text-ink5">{label}</dt>
      <dd className="mt-0.5 text-xl font-bold tracking-tight text-ink">{children}</dd>
    </div>
  )
}

/* ============================================================================
   Meters
   ========================================================================== */

/**
 * A limit and how close something is to it.
 *
 * Rendered as a `<meter>` would be read but drawn by hand, because the native control cannot be
 * styled consistently across browsers. The accessible name and the numbers are the same text a
 * sighted reader sees.
 */
export function Meter({
  label,
  valueText,
  percent,
  footLeft,
  footRight,
  tone = 'indigo',
  describedAs,
}: {
  label: ReactNode
  valueText: ReactNode
  percent: number
  footLeft?: ReactNode
  footRight?: ReactNode
  tone?: 'indigo' | 'rose' | 'emerald' | 'amber'
  /**
   * What the bar actually shows, when the fill is not a plain percentage of the limit. A label
   * that announces a number the drawing does not mean is worse than no label at all.
   */
  describedAs?: string
}) {
  const clamped = Math.max(0, Math.min(100, percent))
  const readable =
    describedAs ?? `${typeof label === 'string' ? label : 'Usage'}: ${formatPercent(clamped, 0)} of the limit`
  return (
    <div>
      <div className="flex items-baseline justify-between gap-3 text-base">
        <span className="min-w-0 truncate text-ink4">{label}</span>
        <b className="shrink-0 font-bold text-ink">{valueText}</b>
      </div>
      <div
        className="relative mt-2 h-2.5 overflow-hidden rounded-[5px] bg-slate1"
        role="img"
        aria-label={readable}
      >
        <span
          className={clsx(
            'absolute inset-y-0 left-0 w-full origin-left rounded-[5px] transition-transform duration-500 ease-out',
            tone === 'indigo' && 'bg-gradient-to-r from-[#818cf8] to-indigo',
            tone === 'rose' && 'bg-gradient-to-r from-[#fb7185] to-rose',
            tone === 'emerald' && 'bg-gradient-to-r from-[#34d399] to-emerald',
            tone === 'amber' && 'bg-gradient-to-r from-[#fbbf24] to-amber',
          )}
          style={{ transform: `scaleX(${clamped / 100})` }}
        />
        <span aria-hidden="true" className="absolute -top-0.5 bottom-[-2px] right-0 w-[3px] rounded-sm bg-ink" />
      </div>
      {footLeft !== undefined || footRight !== undefined ? (
        <div className="mt-2 flex flex-wrap justify-between gap-x-3 gap-y-1 text-sm text-ink5">
          <span className="min-w-0">{footLeft}</span>
          <span className="min-w-0 text-right">{footRight}</span>
        </div>
      ) : null}
    </div>
  )
}

/* ============================================================================
   Empty and error states
   ========================================================================== */

/**
 * `level` exists because these blocks stand in for real content, and the heading they carry has
 * to sit at whatever depth that content would have. Under a section heading they are an `h3`;
 * directly under a page's `h1` — which is where an error or empty branch usually lands — they
 * have to be an `h2`, or the document outline gains a hole exactly when something has gone wrong.
 */
export function EmptyState({
  icon,
  title,
  children,
  action,
  tone = 'slate',
  level = 'h3',
}: {
  icon?: ReactNode
  title: string
  children: ReactNode
  action?: ReactNode
  tone?: 'slate' | 'indigo'
  level?: 'h2' | 'h3'
}) {
  const Heading = level
  return (
    <div className="flex flex-col items-center gap-3 rounded-r3 border border-dashed border-line2 bg-[var(--slate-50)] px-6 py-12 text-center">
      {icon ? (
        <span
          className={clsx(
            'grid h-11 w-11 place-items-center rounded-r2',
            tone === 'indigo' ? 'bg-indigo-soft text-indigo' : 'bg-surface text-ink5 ring-1 ring-line',
          )}
        >
          {icon}
        </span>
      ) : null}
      <Heading className="text-xl">{title}</Heading>
      <div className="max-w-[52ch] text-md text-ink3">{children}</div>
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  )
}

export function ErrorState({
  title,
  error,
  onRetry,
  level = 'h3',
}: {
  title: string
  error: Error
  onRetry?: () => void
  level?: 'h2' | 'h3'
}) {
  const Heading = level
  return (
    <div
      role="alert"
      className="flex flex-col items-start gap-3 rounded-r3 border border-rose-line bg-rose-soft px-6 py-8"
    >
      <Heading className="text-xl text-rose">{title}</Heading>
      <p className="max-w-[62ch] text-md text-[#7a1d33]">
        {error.message}. The read comes straight from your browser, so a blocked request or an
        offline node looks exactly like this — retry, or check the endpoint.
      </p>
      {onRetry ? (
        <button
          type="button"
          onClick={onRetry}
          className={buttonClass('default', 'sm', 'mt-1')}
        >
          Try Again
        </button>
      ) : null}
    </div>
  )
}

/* ============================================================================
   Misc
   ========================================================================== */

/** A dotted-underline term with an explanation attached, used for jargon in body copy. */
export function Term({ children, explain }: { children: ReactNode; explain: string }) {
  return (
    <abbr
      title={explain}
      className="cursor-help border-b border-dotted border-line2 no-underline"
    >
      {children}
    </abbr>
  )
}

export function Hairline({ className }: { className?: string }) {
  return <hr className={clsx('border-0 border-t border-line', className)} />
}
