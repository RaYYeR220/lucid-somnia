import type { Metadata } from 'next'
import { Hero } from '@/components/landing/Hero'
import { Bento } from '@/components/landing/Bento'
import { HowItWorks } from '@/components/landing/HowItWorks'
import { RefusalShowcase } from '@/components/landing/RefusalShowcase'
import { ButtonLink } from '@/components/ui/Primitives'
import { IconArrowRight } from '@/components/ui/Icon'

export const metadata: Metadata = {
  description:
    'Lucid runs autonomous trading desks for DreamDEX Event Contracts on Somnia. A reactivity subscription wakes each desk, a validator committee runs the model, and a policy contract decides whether anything happens.',
}

export default function LandingPage() {
  return (
    <>
      <Hero />
      <Bento />
      <HowItWorks />
      <RefusalShowcase />

      <section className="pb-24 pt-4 text-center sm:pb-28">
        <div className="wrap">
          <h2 className="text-[clamp(28px,4.4vw,52px)] tracking-tightest">
            Watch a desk decide. Then close the laptop.
          </h2>
          <p className="mx-auto mt-4 max-w-[56ch] text-lg text-ink3">
            Nothing on these pages needs a wallet, a login or a server. Pick a desk, open its
            window loop, and follow the same events a block explorer would show you.
          </p>
          <div className="mt-7 flex flex-wrap justify-center gap-3">
            <ButtonLink href="/desks/" tone="primary" size="lg">
              Browse the Desks
              <IconArrowRight size={16} />
            </ButtonLink>
            <ButtonLink href="/system/" tone="default" size="lg">
              Inspect the Machine Room
            </ButtonLink>
          </div>
        </div>
      </section>
    </>
  )
}
