import type { ReactNode } from 'react'
import { clsx } from '@/lib/clsx'

/**
 * The one card shape in the product: a white surface on a slate ground, a hairline border, a
 * 24 px radius and the indigo-tinted shadow. Every panel on every page is this component or a
 * variant of it, which is what makes a page nobody has seen before still look like the same app.
 */
export function Card({
  as: Tag = 'div',
  className,
  children,
  hover = false,
  pad = 'md',
}: {
  as?: 'div' | 'section' | 'article' | 'li'
  className?: string
  children: ReactNode
  /** Lift on hover. Only for cards that are, or contain, a link. */
  hover?: boolean
  pad?: 'none' | 'sm' | 'md' | 'lg'
}) {
  return (
    <Tag
      className={clsx(
        'rounded-r4 border border-line bg-surface shadow-card',
        hover && 'transition-[box-shadow,transform] duration-200 ease-out hover:-translate-y-0.5 hover:shadow-cardHover',
        pad === 'sm' && 'p-4 sm:p-5',
        pad === 'md' && 'p-5 sm:p-7',
        pad === 'lg' && 'p-6 sm:p-8',
        className,
      )}
    >
      {children}
    </Tag>
  )
}

/** The tinted square that opens a bento card. */
export function CardIcon({
  tone = 'indigo',
  children,
}: {
  tone?: 'indigo' | 'emerald' | 'rose' | 'amber' | 'cyan'
  children: ReactNode
}) {
  return (
    <span
      className={clsx(
        'mb-4 grid h-10 w-10 place-items-center rounded-r2',
        tone === 'indigo' && 'bg-indigo-soft text-indigo',
        tone === 'emerald' && 'bg-emerald-soft text-emerald',
        tone === 'rose' && 'bg-rose-soft text-rose',
        tone === 'amber' && 'bg-amber-soft text-amber',
        tone === 'cyan' && 'bg-[#ECFEFF] text-cyan',
      )}
    >
      {children}
    </span>
  )
}

/** The hairline-topped footer row a bento card puts its numbers in. */
export function CardFoot({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={clsx('mt-5 flex flex-wrap gap-x-6 gap-y-3 border-t border-line pt-4', className)}>
      {children}
    </div>
  )
}

/** A section heading block: kicker, headline, standfirst. */
export function SectionHead({
  kicker,
  title,
  children,
  align = 'left',
  id,
}: {
  kicker?: string
  title: ReactNode
  children?: ReactNode
  align?: 'left' | 'center'
  id?: string
}) {
  return (
    <div className={clsx('max-w-[64ch]', align === 'center' && 'mx-auto text-center')}>
      {kicker ? (
        <p className="text-[13px] font-bold uppercase tracking-widest text-indigo">{kicker}</p>
      ) : null}
      <h2
        id={id}
        className="mt-3 text-[clamp(26px,3.8vw,44px)] tracking-tightest"
      >
        {title}
      </h2>
      {children ? <div className="mt-4 text-lg text-ink3">{children}</div> : null}
    </div>
  )
}

/** A page-level heading block, one per route. */
export function PageHead({
  eyebrow,
  title,
  lede,
  aside,
}: {
  eyebrow: string
  title: string
  lede: ReactNode
  aside?: ReactNode
}) {
  return (
    <header className="flex flex-col gap-6 border-b border-line pb-8 lg:flex-row lg:items-end lg:justify-between">
      <div className="max-w-[62ch]">
        <p className="text-[13px] font-bold uppercase tracking-widest text-indigo">{eyebrow}</p>
        <h1 className="mt-3 text-[clamp(30px,4.2vw,46px)] tracking-tightest">{title}</h1>
        <div className="mt-4 text-lg text-ink3">{lede}</div>
      </div>
      {aside ? <div className="shrink-0">{aside}</div> : null}
    </header>
  )
}
