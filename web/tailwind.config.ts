import type { Config } from 'tailwindcss'

/**
 * The token table is lifted wholesale from the chosen design direction: an indigo → violet accent
 * on a slate ground, four radii, and two coloured card shadows. Nothing here is invented; every
 * value below appears in the source page, and every component in this app is built from these
 * and nothing else.
 */
const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: 'var(--bg)',
        surface: 'var(--surface)',
        slate1: 'var(--slate-100)',
        ink: 'var(--ink)',
        ink2: 'var(--ink-2)',
        ink3: 'var(--ink-3)',
        ink4: 'var(--ink-4)',
        ink5: 'var(--ink-5)',
        'ink-on-dark': 'var(--ink-on-dark)',
        line: 'var(--line)',
        line2: 'var(--line-2)',
        indigo: 'var(--indigo)',
        violet: 'var(--violet)',
        'indigo-soft': 'var(--indigo-soft)',
        emerald: 'var(--emerald)',
        'emerald-soft': 'var(--emerald-soft)',
        rose: 'var(--rose)',
        'rose-soft': 'var(--rose-soft)',
        'rose-line': 'var(--rose-line)',
        amber: 'var(--amber)',
        'amber-soft': 'var(--amber-soft)',
        cyan: 'var(--cyan)',
        // The dark showcase band and the code plates use their own small ramp.
        night: 'var(--night)',
        'night-2': 'var(--night-2)',
        'night-3': 'var(--night-3)',
      },
      borderRadius: {
        r1: '8px',
        r2: '12px',
        r3: '16px',
        r4: '24px',
      },
      boxShadow: {
        card: 'var(--sh-c)',
        cardHover: 'var(--sh-h)',
        frame: '0 2px 4px rgba(15,23,42,.04), 0 40px 80px -40px rgba(30,41,59,.5)',
        btn: '0 1px 2px rgba(15,23,42,.05)',
        primary: '0 4px 14px -4px rgba(79,70,229,.55)',
        primaryHover: '0 8px 22px -6px rgba(79,70,229,.6)',
        ring: '0 0 0 3px rgba(79,70,229,.14)',
      },
      fontFamily: {
        sans: ['var(--font-jakarta)', 'system-ui', 'sans-serif'],
      },
      fontSize: {
        // The source page runs on half-pixel steps; keeping them makes the rhythm identical.
        '2xs': ['10.5px', { lineHeight: '1.4' }],
        xs: ['11.5px', { lineHeight: '1.45' }],
        sm: ['12.5px', { lineHeight: '1.5' }],
        base: ['13.5px', { lineHeight: '1.55' }],
        md: ['14.5px', { lineHeight: '1.55' }],
        lg: ['16px', { lineHeight: '1.6' }],
        xl: ['18px', { lineHeight: '1.5' }],
        '2xl': ['21px', { lineHeight: '1.25' }],
        '3xl': ['26px', { lineHeight: '1.15' }],
        '4xl': ['32px', { lineHeight: '1.1' }],
      },
      letterSpacing: {
        tightest: '-.045em',
        tighter: '-.035em',
        tight: '-.02em',
        body: '-.008em',
        wide: '.06em',
        widest: '.12em',
      },
      transitionTimingFunction: {
        out: 'cubic-bezier(.2,.7,.3,1)',
      },
      keyframes: {
        blink: { '50%': { opacity: '.25' } },
        shimmer: { '100%': { transform: 'translateX(100%)' } },
        rise: {
          from: { opacity: '0', transform: 'translateY(6px)' },
          to: { opacity: '1', transform: 'none' },
        },
      },
      animation: {
        blink: 'blink 2.2s ease-in-out infinite',
        shimmer: 'shimmer 1.4s infinite',
        rise: 'rise .28s cubic-bezier(.2,.7,.3,1) both',
      },
    },
  },
  plugins: [],
}

export default config
