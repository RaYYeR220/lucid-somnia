'use client'

import { StatusBadge } from '@/components/ui/Primitives'

/**
 * Armed is two flags, not one, and the interface never collapses them.
 *
 * `policy.armed` is what the desk believes about itself. `router.deskArmed` is whether the router
 * will ever hand it a window. They can disagree — the factory sets the opening mandate before it
 * registers the clone — and a desk that looks armed to itself while being invisible to the chain
 * is funded, configured and silently dead. That is the one state worth shouting about.
 */
export function ArmedState({
  policyArmed,
  armedAtRouter,
}: {
  policyArmed: boolean
  armedAtRouter: boolean
}) {
  if (policyArmed && armedAtRouter) {
    return (
      <StatusBadge tone="emerald" pulse title="Armed in its own mandate and registered in the router’s fan-out list.">
        Armed
      </StatusBadge>
    )
  }
  if (!policyArmed && !armedAtRouter) {
    return (
      <StatusBadge tone="slate" title="Switched off. Every window is refused with NotArmed.">
        Disarmed
      </StatusBadge>
    )
  }
  if (policyArmed && !armedAtRouter) {
    return (
      <StatusBadge
        tone="rose"
        title="The mandate says armed, but the router has never registered this desk — so it will never hear about a window."
      >
        Armed, unregistered
      </StatusBadge>
    )
  }
  return (
    <StatusBadge
      tone="amber"
      title="The router will fan out to this desk, but its own mandate is disarmed, so it refuses every window with NotArmed."
    >
      Registered, disarmed
    </StatusBadge>
  )
}
