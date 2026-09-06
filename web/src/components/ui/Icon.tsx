import type { SVGProps } from 'react'

/**
 * Every glyph in the product, drawn on the same 16-unit grid with the same 1.4–1.6 stroke, so an
 * icon lifted from one card sits correctly in another. Icons are decorative by default and are
 * hidden from assistive technology; anything load-bearing carries its own text.
 */
type IconProps = SVGProps<SVGSVGElement> & { size?: number; title?: string }

function Base({ size = 16, title, children, ...rest }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      focusable="false"
      {...rest}
    >
      {title ? <title>{title}</title> : null}
      {children}
    </svg>
  )
}

export function IconMark(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M8 1.5 14 5v6l-6 3.5L2 11V5l6-3.5Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      <circle cx="8" cy="8" r="1.9" fill="currentColor" />
    </Base>
  )
}

export function IconShieldCheck(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M8 1.6 14 4.9v6.2L8 14.4 2 11.1V4.9L8 1.6Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      <path d="M5.4 8.1 7.2 9.9l3.4-3.6" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </Base>
  )
}

export function IconNo(props: IconProps) {
  return (
    <Base {...props}>
      <circle cx="8" cy="8" r="5.9" stroke="currentColor" strokeWidth="1.5" />
      <path d="m5.6 10.4 4.8-4.8" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </Base>
  )
}

export function IconCommittee(props: IconProps) {
  return (
    <Base {...props}>
      <circle cx="4.4" cy="5.2" r="2.1" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="11.6" cy="5.2" r="2.1" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="8" cy="11.4" r="2.1" stroke="currentColor" strokeWidth="1.4" />
      <path d="M6.4 5.2h3.2M5.4 7.1l1.3 2.6M10.6 7.1 9.3 9.7" stroke="currentColor" strokeWidth="1.3" />
    </Base>
  )
}

export function IconClock(props: IconProps) {
  return (
    <Base {...props}>
      <circle cx="8" cy="8" r="5.9" stroke="currentColor" strokeWidth="1.4" />
      <path d="M8 4.8V8l2.2 1.7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </Base>
  )
}

export function IconLink(props: IconProps) {
  return (
    <Base {...props}>
      <circle cx="5.4" cy="5.6" r="2.1" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="11.2" cy="10.6" r="2.1" stroke="currentColor" strokeWidth="1.4" />
      <path d="M7.2 6.8 9.4 9.4" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </Base>
  )
}

export function IconArrowRight(props: IconProps) {
  return (
    <Base {...props}>
      <path
        d="M3.5 8h9M9 4.5 12.5 8 9 11.5"
        stroke="currentColor"
        strokeWidth="1.7"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Base>
  )
}

export function IconCheck(props: IconProps) {
  return (
    <Base viewBox="0 0 12 12" {...props}>
      <path
        d="m2.5 6.2 2.3 2.3L9.6 3.6"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Base>
  )
}

export function IconCross(props: IconProps) {
  return (
    <Base viewBox="0 0 12 12" {...props}>
      <path d="M3.4 3.4 8.6 8.6M8.6 3.4 3.4 8.6" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" />
    </Base>
  )
}

export function IconExternal(props: IconProps) {
  return (
    <Base {...props}>
      <path
        d="M6.5 3.5H3.5v9h9v-3M9.5 3.5h3v3M12.5 3.5 7.5 8.5"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Base>
  )
}

export function IconWave(props: IconProps) {
  return (
    <Base {...props}>
      <path
        d="M1.8 8h2L5.6 3.8 8 12.2l1.9-5.4 1 1.2h3.3"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Base>
  )
}

export function IconSort(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M8 3.2 5.4 6h5.2L8 3.2ZM8 12.8 5.4 10h5.2L8 12.8Z" fill="currentColor" />
    </Base>
  )
}

export function IconSortUp(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M8 4.4 4.8 8h6.4L8 4.4Z" fill="currentColor" />
    </Base>
  )
}

export function IconSortDown(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M8 11.6 4.8 8h6.4L8 11.6Z" fill="currentColor" />
    </Base>
  )
}

export function IconBolt(props: IconProps) {
  return (
    <Base {...props}>
      <path
        d="M8.8 1.6 3.4 9h3.4l-.6 5.4L12.6 7H9.2l-.4-5.4Z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
    </Base>
  )
}

export function IconGauge(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M2.4 11.4a6 6 0 1 1 11.2 0" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <path d="M8 11 10.4 6.6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </Base>
  )
}

export function IconWallet(props: IconProps) {
  return (
    <Base {...props}>
      <rect x="2" y="4" width="12" height="8.4" rx="2" stroke="currentColor" strokeWidth="1.4" />
      <path d="M2 7h12" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="11" cy="9.7" r=".9" fill="currentColor" />
    </Base>
  )
}

export function IconInfo(props: IconProps) {
  return (
    <Base {...props}>
      <circle cx="8" cy="8" r="6" stroke="currentColor" strokeWidth="1.4" />
      <path d="M8 7.2v3.4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      <circle cx="8" cy="5.2" r=".85" fill="currentColor" />
    </Base>
  )
}

export function IconWarn(props: IconProps) {
  return (
    <Base {...props}>
      <path d="M8 2.2 14.4 13H1.6L8 2.2Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      <path d="M8 6.4v3" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      <circle cx="8" cy="11.2" r=".85" fill="currentColor" />
    </Base>
  )
}

export function IconInbox(props: IconProps) {
  return (
    <Base {...props}>
      <path
        d="M2 9.4 3.8 3.4h8.4L14 9.4v2.2a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V9.4Z"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <path d="M2 9.4h3.2l.9 1.6h3.8l.9-1.6H14" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
    </Base>
  )
}
