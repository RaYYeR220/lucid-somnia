'use client'

import { useEffect, useState } from 'react'
import { isAddress } from 'viem'
import { DeskDetail } from '@/components/desks/DeskDetail'
import { ButtonLink, EmptyState } from '@/components/ui/Primitives'
import { IconInbox } from '@/components/ui/Icon'

/**
 * The 404, and the fallback for desks that did not exist when this bundle was built.
 *
 * A static export can only pre-render the desks the factory had at build time. Rather than
 * telling somebody with a valid, newly created desk that their desk does not exist, this route
 * reads the address out of the path and renders the same view against the live chain — which is
 * where the data was coming from anyway.
 */
export default function NotFound() {
  const [path, setPath] = useState<string | null>(null)
  useEffect(() => setPath(window.location.pathname), [])

  // Until the path is known this route cannot tell a genuine 404 from a desk that simply was
  // not pre-rendered, so it claims neither.
  if (path === null) {
    return (
      <div className="wrap py-24 text-center" aria-live="polite">
        <p className="text-md text-ink4">Working out where you meant to go…</p>
      </div>
    )
  }

  const deskAddress = path.match(/^\/desks\/(0x[0-9a-fA-F]{40})\/?$/)?.[1]

  if (deskAddress !== undefined && isAddress(deskAddress)) {
    return <DeskDetail address={deskAddress} />
  }

  return (
    <div className="wrap py-16 sm:py-24">
      <h1 className="sr-only">Page not found</h1>
      <EmptyState icon={<IconInbox size={20} />} title="There is nothing at this address">
        <p>
          The page you asked for is not part of this site. Everything Lucid publishes is on one of
          the four routes below, and all of them read the chain live.
        </p>
      </EmptyState>
      <nav aria-label="Recovery" className="mt-6 flex flex-wrap justify-center gap-3">
        <ButtonLink href="/" tone="primary">
          Go to the Overview
        </ButtonLink>
        <ButtonLink href="/desks/" tone="default">
          Browse the Desks
        </ButtonLink>
        <ButtonLink href="/windows/" tone="default">
          See the Windows
        </ButtonLink>
        <ButtonLink href="/system/" tone="default">
          Inspect the System
        </ButtonLink>
      </nav>
      <p className="mt-6 text-center text-base text-ink5">
        Requested <code translate="no">{path}</code>
      </p>
    </div>
  )
}
