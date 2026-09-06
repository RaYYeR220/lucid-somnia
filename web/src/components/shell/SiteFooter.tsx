'use client'

import Link from 'next/link'
import { EXPLORER_URL, INDEXER_URL, RPC_URL, deployed } from '@/lib/chain/config'
import { count } from '@/lib/format'
import { useBlockNumber } from '@/lib/hooks'
import { AddressLink, BlockLink } from '@/components/ui/Primitives'
import { Dash } from '@/components/ui/Value'
import { IconMark } from '@/components/ui/Icon'

const COLUMNS = [
  {
    heading: 'Product',
    links: [
      { label: 'Overview', href: '/' },
      { label: 'Desks', href: '/desks/' },
      { label: 'Windows', href: '/windows/' },
      { label: 'System', href: '/system/' },
    ],
  },
  {
    heading: 'Contracts',
    links: [
      { label: 'Router', href: `${EXPLORER_URL}/address/${deployed.router}`, external: true },
      { label: 'Brain', href: `${EXPLORER_URL}/address/${deployed.brain}`, external: true },
      { label: 'Factory', href: `${EXPLORER_URL}/address/${deployed.factory}`, external: true },
      { label: 'Keeper', href: `${EXPLORER_URL}/address/${deployed.keeper}`, external: true },
      { label: 'Relay', href: `${EXPLORER_URL}/address/${deployed.relay}`, external: true },
      { label: 'Series', href: `${EXPLORER_URL}/address/${deployed.series}`, external: true },
    ],
  },
  {
    heading: 'Sources',
    links: [
      { label: 'Shannon RPC', href: RPC_URL, external: true },
      { label: 'DreamDEX indexer', href: INDEXER_URL, external: true },
      { label: 'Shannon Explorer', href: EXPLORER_URL, external: true },
    ],
  },
] as const

export function SiteFooter() {
  const block = useBlockNumber()

  return (
    <footer className="border-t border-line bg-surface pb-9 pt-12">
      <div className="wrap">
        <div className="grid gap-8 md:grid-cols-2 lg:grid-cols-[1.6fr_repeat(3,1fr)]">
          <div>
            <Link href="/" className="flex items-center gap-2.5 rounded-[8px] text-xl font-extrabold tracking-tightest text-ink">
              <span className="grid h-[30px] w-[30px] place-items-center rounded-[9px] bg-gradient-to-br from-violet to-indigo text-white shadow-[0_4px_12px_-4px_rgba(79,70,229,.6)]">
                <IconMark size={16} />
              </span>
              <span translate="no">Lucid</span>
            </Link>
            <p className="mt-3.5 max-w-[38ch] text-md text-ink4">
              Autonomous trading desks for DreamDEX Event Contracts on Somnia. Settled in tUSDC on
              the Shannon testnet.
            </p>
            <p className="mt-4 max-w-[38ch] text-base text-ink5">
              This page has no backend. Every number on it was fetched by your browser, from the
              Shannon RPC and the public DreamDEX indexer.
            </p>
          </div>

          {COLUMNS.map((column) => (
            <nav key={column.heading} aria-label={column.heading}>
              <h2 className="mb-3 text-sm font-bold uppercase tracking-wide text-ink5">{column.heading}</h2>
              <ul>
                {column.links.map((link) => (
                  <li key={link.label}>
                    {'external' in link && link.external ? (
                      <a
                        href={link.href}
                        target="_blank"
                        rel="noreferrer noopener"
                        className="block rounded-[6px] py-1.5 text-md text-ink3 transition-colors hover:text-ink"
                      >
                        {link.label}
                        <span className="sr-only"> (opens in a new tab)</span>
                      </a>
                    ) : (
                      <Link
                        href={link.href}
                        className="block rounded-[6px] py-1.5 text-md text-ink3 transition-colors hover:text-ink"
                      >
                        {link.label}
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="mt-10 flex flex-wrap justify-between gap-4 border-t border-line pt-5 text-base text-ink5">
          <p className="max-w-[64ch]">
            Shannon testnet, chain&nbsp;{deployed.chainId}. Event contracts carry risk; past window
            outcomes do not predict future ones. Nothing here is advice.
          </p>
          <p className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span>
              Router <AddressLink address={deployed.router} />
            </span>
            <span aria-hidden="true">·</span>
            <span>
              Block{' '}
              {block.status === 'ready' ? (
                <BlockLink block={block.data}>{count(block.data)}</BlockLink>
              ) : block.status === 'error' ? (
                <Dash why={block.error.message} />
              ) : (
                <span className="skeleton inline-block h-[1em] w-[9ch] align-middle" aria-hidden="true" />
              )}
            </span>
          </p>
        </div>
      </div>
    </footer>
  )
}
