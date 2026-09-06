'use client'

import { useCallback, useEffect, useState } from 'react'

/**
 * Stateful UI that lives in the URL, without a router dependency.
 *
 * Sort order, filters and tabs are things people share and bookmark, so they belong in the query
 * string rather than in a `useState` nobody else can reach. This reads the parameter on mount,
 * follows Back and Forward, and writes changes with `history.pushState` — a view somebody chose is
 * a place they can go back from. It works under a static export, where there is no server to
 * re-render a search param.
 */
export function useUrlState<T extends string>(
  key: string,
  fallback: T,
  allowed: readonly T[],
): [T, (next: T) => void] {
  const [value, setValue] = useState<T>(fallback)

  useEffect(() => {
    const read = () => {
      const found = new URLSearchParams(window.location.search).get(key)
      setValue(found !== null && (allowed as readonly string[]).includes(found) ? (found as T) : fallback)
    }
    read()
    // Back and Forward change the URL without a navigation, so the view has to follow it.
    window.addEventListener('popstate', read)
    return () => window.removeEventListener('popstate', read)
    // `allowed` is a module-level constant at every call site; keying on its identity would
    // re-run this effect forever.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, fallback])

  const update = useCallback(
    (next: T) => {
      setValue(next)
      const params = new URLSearchParams(window.location.search)
      if (next === fallback) params.delete(key)
      else params.set(key, next)
      const query = params.toString()
      // `pushState`, not `replaceState`: a filter or tab the reader chose is a place they can
      // go back from. The listener above keeps the view and the URL in step either way.
      window.history.pushState(
        null,
        '',
        `${window.location.pathname}${query === '' ? '' : `?${query}`}`,
      )
    },
    [key, fallback],
  )

  return [value, update]
}
