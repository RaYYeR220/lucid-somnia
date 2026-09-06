'use client'

import type { ReactNode } from 'react'
import type { QueryState } from '@/lib/query'

/**
 * The one component every on-chain number in this app is rendered through.
 *
 * It has exactly three outcomes, matching the three states a value can honestly be in:
 *
 *  - loading → a skeleton the size of the number that is coming
 *  - error   → an em dash that says, on hover and to a screen reader, why the value is missing
 *  - ready   → the value, including when the value is zero
 *
 * There is no fourth branch where a plausible digit stands in for one the chain did not give us.
 */
export function Skeleton({ w = '4.5ch', h = '1em' }: { w?: string; h?: string }) {
  return <span className="skeleton inline-block align-middle" style={{ width: w, height: h }} aria-hidden="true" />
}

export function Dash({ why }: { why: string }) {
  return (
    <span className="inline-flex items-center gap-1 text-ink5" title={why}>
      <span aria-hidden="true">—</span>
      <span className="sr-only">Not available: {why}</span>
    </span>
  )
}

interface ValueProps<T> {
  state: QueryState<T>
  /** How to render the value once it is in hand. */
  children: (value: T) => ReactNode
  /** Width of the skeleton, so the layout does not shift when the number lands. */
  w?: string
  /** Overrides the tooltip on the em dash. Defaults to the error's own message. */
  why?: string
}

export function Value<T>({ state, children, w = '5ch', why }: ValueProps<T>) {
  if (state.status === 'loading') return <Skeleton w={w} />
  if (state.status === 'error') {
    return <Dash why={why ?? state.error.message} />
  }
  return <>{children(state.data)}</>
}

/**
 * Loading text for anything that is not a number. Ends with an ellipsis, as loading copy should.
 */
export function LoadingText({ children = 'Loading' }: { children?: ReactNode }) {
  return (
    <span className="text-ink4" aria-live="polite">
      {children}…
    </span>
  )
}
