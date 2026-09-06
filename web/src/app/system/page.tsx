import type { Metadata } from 'next'
import { SystemView } from '@/components/system/SystemView'

export const metadata: Metadata = {
  title: 'System',
  description:
    'The machine room: the router’s reactivity subscriptions in plain English, its balance against the 32 SOMI subscription floor, the committee sizes and quote, and the keeper, relay and failover watcher — all read live.',
}

export default function SystemPage() {
  return <SystemView />
}
