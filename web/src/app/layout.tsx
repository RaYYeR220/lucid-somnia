import type { Metadata, Viewport } from 'next'
import { Plus_Jakarta_Sans } from 'next/font/google'
import { SiteHeader } from '@/components/shell/SiteHeader'
import { SiteFooter } from '@/components/shell/SiteFooter'
import './globals.css'

const jakarta = Plus_Jakarta_Sans({
  subsets: ['latin'],
  weight: ['400', '500', '600', '700', '800'],
  display: 'swap',
  variable: '--font-jakarta',
})

export const metadata: Metadata = {
  title: {
    default: 'Lucid — Autonomous trading desks on Somnia',
    template: '%s · Lucid',
  },
  description:
    'Lucid runs autonomous trading desks for DreamDEX Event Contracts on Somnia. A desk is a contract: validators wake it, run the model as a committee, and record every decision — including every refusal — on chain.',
  applicationName: 'Lucid',
  robots: { index: true, follow: true },
}

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Zoom is never disabled.
  // The strip against the browser chrome is the dark announcement bar, not the page ground.
  themeColor: '#0f172a',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={jakarta.variable}>
      <head>
        <link rel="preconnect" href="https://api.infra.testnet.somnia.network" />
        <link rel="preconnect" href="https://dev.smk.somnia.host" />
      </head>
      <body className="font-sans">
        <div className="flex min-h-screen flex-col">
          <SiteHeader />
          {/* `tabIndex={-1}` so the skip link moves focus, not only the viewport. */}
          <main id="main" tabIndex={-1} className="flex-1 outline-none">
            {children}
          </main>
          <SiteFooter />
        </div>
      </body>
    </html>
  )
}
