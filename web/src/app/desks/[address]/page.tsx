import type { Metadata } from 'next'
import { createPublicClient, http } from 'viem'
import { RPC_URL, deployed } from '@/lib/chain/config'
import { factoryAbi } from '@/lib/chain/synced'
import { DeskDetail } from '@/components/desks/DeskDetail'

export const metadata: Metadata = {
  title: 'Desk',
  description:
    'One Lucid desk in full: its live window loop, the committee vote behind it, the policy gate that disposed of it, its refusal log and its positions.',
}

/**
 * Which desk pages exist as files in the export.
 *
 * The list is read from the factory at build time, so a fresh build always carries every desk the
 * chain knows about. A build with no network still succeeds and falls back to the desks deployed
 * alongside the protocol; anything not pre-rendered is picked up client-side by the not-found
 * route, which reads the address out of the path and renders the same view.
 */
export async function generateStaticParams(): Promise<{ address: string }[]> {
  const fallback = deployed.seedDesks.map((address) => ({ address }))
  try {
    const client = createPublicClient({ transport: http(RPC_URL) })
    const desks = await client.readContract({
      address: deployed.factory,
      abi: factoryAbi,
      functionName: 'allDesks',
    })
    const params = desks.map((address) => ({ address }))
    return params.length > 0 ? params : fallback
  } catch {
    return fallback
  }
}

export default async function DeskPage({ params }: { params: Promise<{ address: string }> }) {
  const { address } = await params
  return <DeskDetail address={address} />
}
