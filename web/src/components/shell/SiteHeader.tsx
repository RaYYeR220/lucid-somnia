'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useEffect, useState } from 'react'
import { clsx } from '@/lib/clsx'
import { EXPLORER_URL, SUBSCRIPTION_FLOOR_WEI, deployed } from '@/lib/chain/config'
import { somi } from '@/lib/format'
import { useRouterStatus } from '@/lib/hooks'
import { ButtonLink, StatusBadge } from '@/components/ui/Primitives'
import { IconExternal, IconMark } from '@/components/ui/Icon'

const NAV = [
  { href: '/', label: 'Overview' },
  { href: '/desks/', label: 'Desks' },
  { href: '/windows/', label: 'Windows' },
  { href: '/system/', label: 'System' },
] as const

function isActive(pathname: string, href: string): boolean {
  if (href === '/') return pathname === '/'
  return pathname.startsWith(href.replace(/\/$/, ''))
}

/**
 * The announcement strip.
 *
 * It carries a live number, so it is a skeleton before the read lands and an honest sentence
 * without the number if the read fails. A bar that always says something confident whether or
 * not the chain answered would be the first small lie in a product whose whole claim is that it
 * does not tell them.
 */
function AnnounceBar() {
  const router = useRouterStatus()
  return (
    <div className="bg-ink px-5 py-2 text-center text-base text-[#cbd5e1]">
      <span
        className="inline-flex flex-wrap items-center justify-center gap-x-2 gap-y-1"
        aria-live="polite"
        aria-busy={router.status === 'loading'}
      >
        <span className="font-semibold text-white">Live on Somnia&nbsp;Shannon.</span>
        {router.status === 'ready' ? (
          <span>
            The router holds{' '}
            <b className="font-semibold text-white">{somi(router.data.balance)}&nbsp;SOMI</b> against
            a {somi(SUBSCRIPTION_FLOOR_WEI, 0)}&nbsp;SOMI subscription floor — and no servers at all.
          </span>
        ) : router.status === 'error' ? (
          <span>
            The router float could not be read from your browser. The machine room says which
            endpoint did not answer.
          </span>
        ) : (
          <span>
            The router holds{' '}
            <span className="skeleton inline-block h-[1em] w-[5ch] align-middle" aria-hidden="true" />
            &nbsp;SOMI against a {somi(SUBSCRIPTION_FLOOR_WEI, 0)}&nbsp;SOMI subscription floor —
            and no servers at all.
          </span>
        )}
        <Link
          href="/system/"
          className="rounded-[6px] font-semibold text-[#c7d2fe] underline underline-offset-[3px] transition-colors [touch-action:manipulation] hover:text-white"
        >
          See the machine room <span aria-hidden="true">→</span>
        </Link>
      </span>
    </div>
  )
}

export function SiteHeader() {
  const pathname = usePathname() ?? '/'
  const [open, setOpen] = useState(false)

  // The mobile panel closes on a route change and on Escape, and never traps focus behind itself.
  useEffect(() => setOpen(false), [pathname])
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open])

  return (
    <>
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100] focus:rounded-[10px] focus:bg-ink focus:px-4 focus:py-2 focus:text-md focus:font-semibold focus:text-white"
      >
        Skip to content
      </a>

      <AnnounceBar />

      <header className="sticky top-0 z-50 border-b border-line bg-[rgba(248,250,252,.86)] backdrop-blur-[14px]">
        <div className="wrap flex h-[66px] items-center gap-4 sm:gap-6">
          <Link
            href="/"
            className="flex shrink-0 items-center gap-2.5 rounded-[8px] text-xl font-extrabold tracking-tightest text-ink"
          >
            <span className="grid h-[30px] w-[30px] place-items-center rounded-[9px] bg-gradient-to-br from-violet to-indigo text-white shadow-[0_4px_12px_-4px_rgba(79,70,229,.6)]">
              <IconMark size={16} />
            </span>
            <span translate="no">Lucid</span>
          </Link>

          <nav aria-label="Primary" className="hidden md:block">
            <ul className="flex gap-1">
              {NAV.map((item) => {
                const active = isActive(pathname, item.href)
                return (
                  <li key={item.href}>
                    <Link
                      href={item.href}
                      aria-current={active ? 'page' : undefined}
                      className={clsx(
                        'inline-flex h-9 items-center rounded-r1 px-3 text-md font-medium transition-colors [touch-action:manipulation]',
                        active ? 'bg-slate1 text-ink' : 'text-ink3 hover:bg-slate1 hover:text-ink',
                      )}
                    >
                      {item.label}
                    </Link>
                  </li>
                )
              })}
            </ul>
          </nav>

          <span className="flex-1" />

          <div className="hidden items-center gap-2 sm:flex">
            <ButtonLink href={`${EXPLORER_URL}/address/${deployed.router}`} tone="ghost" size="sm" external>
              Router on Explorer
              <IconExternal size={13} />
            </ButtonLink>
            <ReadOnlyPill />
          </div>

          <button
            type="button"
            aria-label={open ? 'Close the menu' : 'Open the menu'}
            aria-expanded={open}
            aria-controls="mobile-nav"
            onClick={() => setOpen((value) => !value)}
            className="grid h-10 w-10 shrink-0 place-items-center rounded-r1 border border-line bg-surface text-ink shadow-btn transition-colors hover:bg-slate1 md:hidden [touch-action:manipulation]"
          >
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
              {open ? (
                <path d="m4.5 4.5 9 9m0-9-9 9" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
              ) : (
                <path d="M3 5h12M3 9h12M3 13h12" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
              )}
            </svg>
          </button>
        </div>

        <div
          id="mobile-nav"
          hidden={!open}
          className="border-t border-line bg-surface md:hidden"
        >
            <nav aria-label="Primary, mobile" className="wrap py-3">
              <ul className="flex flex-col gap-1">
                {NAV.map((item) => {
                  const active = isActive(pathname, item.href)
                  return (
                    <li key={item.href}>
                      <Link
                        href={item.href}
                        aria-current={active ? 'page' : undefined}
                        className={clsx(
                          'flex h-11 items-center rounded-r1 px-3 text-lg font-medium transition-colors [touch-action:manipulation]',
                          active ? 'bg-indigo-soft text-indigo' : 'text-ink2 hover:bg-slate1',
                        )}
                      >
                        {item.label}
                      </Link>
                    </li>
                  )
                })}
                <li className="mt-2 border-t border-line pt-3">
                  <a
                    href={`${EXPLORER_URL}/address/${deployed.router}`}
                    target="_blank"
                    rel="noreferrer noopener"
                    className="flex h-11 items-center gap-2 rounded-r1 px-3 text-lg font-medium text-ink3 [touch-action:manipulation]"
                  >
                    Router on Explorer
                    <IconExternal size={14} />
                    <span className="sr-only"> (opens in a new tab)</span>
                  </a>
                </li>
              </ul>
            </nav>
        </div>
      </header>
    </>
  )
}

/**
 * The one claim this app makes about itself, stated in the chrome: it can only read.
 * There is no wallet client in the bundle, so this is a description, not a promise.
 */
function ReadOnlyPill() {
  return (
    <StatusBadge tone="emerald" title="This front end has no wallet client and no write path. It only reads.">
      Read-only
    </StatusBadge>
  )
}
