import type { Metadata } from 'next'
import { WindowsView } from '@/components/windows/WindowsView'

export const metadata: Metadata = {
  title: 'Windows',
  description:
    'Live and recently settled DreamDEX Event Contract windows, with strike, cadence, expiry countdown and what a Lucid desk did about each — read from the public indexer and the desks’ own logs.',
}

export default function WindowsPage() {
  return <WindowsView />
}
