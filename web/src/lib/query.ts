'use client'

import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * The three states every number in this app can be in, and the only three it is allowed to be in.
 *
 * There is no fourth state where a plausible-looking digit stands in for one the chain has not
 * returned. `loading` renders a skeleton, `error` renders an em dash that can explain itself, and
 * `ready` renders the value — including when the value is zero, which is a fact and says so.
 */
export type QueryState<T> =
  | { status: 'loading'; data?: undefined; error?: undefined; updatedAt?: undefined }
  | { status: 'ready'; data: T; error?: undefined; updatedAt: number }
  | { status: 'error'; data?: undefined; error: Error; updatedAt: number }

interface Entry {
  state: QueryState<unknown>
  promise?: Promise<void>
  listeners: Set<() => void>
  timer?: ReturnType<typeof setInterval>
  refreshMs: number
  fetcher: () => Promise<unknown>
}

/**
 * A module-level cache keyed by query string, so the block height in the footer and the block
 * height on a page are one request, not two, and a route change does not re-fetch what is
 * already in hand.
 */
const cache = new Map<string, Entry>()

function notify(entry: Entry): void {
  for (const listener of entry.listeners) listener()
}

function run(key: string, entry: Entry): Promise<void> {
  if (entry.promise !== undefined) return entry.promise
  const promise = entry
    .fetcher()
    .then((data) => {
      entry.state = { status: 'ready', data, updatedAt: Date.now() }
    })
    .catch((cause: unknown) => {
      const error = cause instanceof Error ? cause : new Error(String(cause))
      // A refresh that fails does not erase a good answer; it is reported alongside it.
      if (entry.state.status !== 'ready') {
        entry.state = { status: 'error', error, updatedAt: Date.now() }
      }
    })
    .finally(() => {
      entry.promise = undefined
      notify(entry)
    })
  entry.promise = promise
  return promise
}

function ensure(key: string, fetcher: () => Promise<unknown>, refreshMs: number): Entry {
  let entry = cache.get(key)
  if (entry === undefined) {
    entry = { state: { status: 'loading' }, listeners: new Set(), refreshMs, fetcher }
    cache.set(key, entry)
  } else {
    // Keep the newest closure so a fetcher that closes over changing arguments stays correct.
    entry.fetcher = fetcher
    entry.refreshMs = refreshMs
  }
  return entry
}

export interface QueryOptions {
  /** Poll interval in milliseconds. `0` fetches once and never again. */
  refreshMs?: number
  /** Skip the request entirely — for a key that is not knowable yet. */
  enabled?: boolean
}

/**
 * Reads one thing from the chain or the indexer, shared across every component that asks for the
 * same key, refreshed on an interval while at least one of them is mounted.
 */
export function useQuery<T>(
  key: string | null,
  fetcher: () => Promise<T>,
  options: QueryOptions = {},
): QueryState<T> & { refetch: () => void } {
  const { refreshMs = 0, enabled = true } = options
  const active = enabled && key !== null
  const fetcherRef = useRef(fetcher)
  fetcherRef.current = fetcher

  const [, force] = useState(0)
  const rerender = useCallback(() => force((n) => n + 1), [])

  useEffect(() => {
    if (!active) return
    const entry = ensure(key, () => fetcherRef.current(), refreshMs)
    entry.listeners.add(rerender)
    if (entry.state.status === 'loading' && entry.promise === undefined) void run(key, entry)

    if (refreshMs > 0 && entry.timer === undefined) {
      entry.timer = setInterval(() => {
        // Nothing polls a tab nobody is looking at.
        if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
        void run(key, entry)
      }, refreshMs)
    }

    return () => {
      entry.listeners.delete(rerender)
      if (entry.listeners.size === 0 && entry.timer !== undefined) {
        clearInterval(entry.timer)
        entry.timer = undefined
      }
    }
  }, [key, active, refreshMs, rerender])

  const refetch = useCallback(() => {
    if (key === null) return
    const entry = cache.get(key)
    if (entry !== undefined) void run(key, entry)
  }, [key])

  if (!active) return { status: 'loading', refetch }
  const entry = cache.get(key)
  const state = (entry?.state ?? { status: 'loading' }) as QueryState<T>
  return { ...state, refetch }
}

/** Maps a ready value through a function, carrying loading and error through untouched. */
export function mapQuery<T, U>(state: QueryState<T>, fn: (value: T) => U): QueryState<U> {
  if (state.status === 'ready') return { status: 'ready', data: fn(state.data), updatedAt: state.updatedAt }
  return state as QueryState<U>
}

/** Combines two queries into one, so a card can gate on both without nesting. */
export function joinQuery<A, B>(a: QueryState<A>, b: QueryState<B>): QueryState<[A, B]> {
  if (a.status === 'error') return a as QueryState<[A, B]>
  if (b.status === 'error') return b as QueryState<[A, B]>
  if (a.status === 'ready' && b.status === 'ready') {
    return { status: 'ready', data: [a.data, b.data], updatedAt: Math.max(a.updatedAt, b.updatedAt) }
  }
  return { status: 'loading' }
}
