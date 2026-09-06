/** Joins class names, dropping anything falsy. One tiny helper instead of a dependency. */
export function clsx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ')
}
