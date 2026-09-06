import type { Metadata } from 'next'
import { DesksView } from '@/components/desks/DesksView'

export const metadata: Metadata = {
  title: 'Desks',
  description:
    'Every Lucid desk the factory has created, with its equity, today’s spend against the daily budget, open windows, loss streak and armed state — read live from Somnia Shannon.',
}

export default function DesksPage() {
  return <DesksView />
}
