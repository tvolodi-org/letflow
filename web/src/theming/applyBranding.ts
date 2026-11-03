/**
 * Applies tenant-supplied brand colours as CSS custom-property overrides on
 * document.documentElement. No React here — see BrandingProvider.tsx for the
 * component that calls this on mount.
 *
 * REQ-283 (0020 D1c); task S0e (design system NOTES.md section 3): the tenant primary colour sets
 * --tenant-current, the partners (strong, tint, on-current, and the -dark set) are derived here, and a
 * colour that cannot carry readable text is refused. tokens.css reads `var(--tenant-current, <teal>)`,
 * so a refused colour simply leaves the Letflow teal in place.
 *
 * No colour literal appears in this file: the fixed Letflow values (paper-raised and the default
 * on-current of each theme) are read from the generated tokens.css at build time (virtual:letflow-theme-tokens, vite.config.ts).
 */
import themeTokens from 'virtual:letflow-theme-tokens'
import { BRAND_COLOR_CSS_PROPERTY, TENANT_DERIVED_CSS_PROPERTY } from './brandingDefaults'

type Rgb = [number, number, number]

const MIN_CONTRAST = 4.5

function parseHex(value: string): Rgb | null {
  const m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(value.trim())
  if (!m) return null
  let h = m[1]
  if (h.length === 3) h = h.split('').map((c) => c + c).join('')
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) as Rgb
}

function toHex(c: Rgb): string {
  return '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('')
}

function luminance([r, g, b]: Rgb): number {
  const lin = (v: number) => {
    const s = v / 255
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

export function contrastRatio(a: Rgb, b: Rgb): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/** Mix `a` towards `b`; t = 0 gives a, t = 1 gives b. */
function mix(a: Rgb, b: Rgb, t: number): Rgb {
  return a.map((v, i) => v + (b[i] - v) * t) as Rgb
}

function fixed(value: string): Rgb {
  const c = parseHex(value)
  if (!c) throw new Error('virtual:letflow-theme-tokens gave a value that is not a hex colour')
  return c
}

const PAPER_RAISED = { light: fixed(themeTokens.paperRaisedLight), dark: fixed(themeTokens.paperRaisedDark) }
const ON_CURRENT_DEFAULT = { light: fixed(themeTokens.onCurrentLight), dark: fixed(themeTokens.onCurrentDark) }
const WHITE: Rgb = [255, 255, 255]
const BLACK: Rgb = [0, 0, 0]

let warned = false

function refuse(value: string, reason: string): void {
  if (warned) return
  warned = true
  console.warn(`[branding] tenant colour "${value}" refused (${reason}); the Letflow default stays in place`)
}

/** Test hook: lets a test observe the "log once" behaviour again. */
export function resetBrandingWarning(): void {
  warned = false
}

type Derived = Record<keyof typeof TENANT_DERIVED_CSS_PROPERTY, string>

/**
 * Derives the full set for a tenant primary colour, or returns a reason string when it is refused.
 * Light: the colour must reach 4.5:1 against paper-raised, and on-current text must reach 4.5:1 on it.
 * Dark: the colour is lightened until it reaches 4.5:1 against the dark paper-raised, so a dark brand
 * colour still works in the dark theme.
 */
export function deriveTenantColours(value: string): Derived | string {
  const base = parseHex(value)
  if (!base) return 'not a #rgb or #rrggbb colour'

  if (contrastRatio(base, PAPER_RAISED.light) < MIN_CONTRAST) return 'under 4.5:1 against paper-raised (light theme)'
  const onLight = ON_CURRENT_DEFAULT.light
  if (contrastRatio(base, onLight) < MIN_CONTRAST) return 'on-current text under 4.5:1 on the colour (light theme)'

  let dark = base
  for (let t = 0; contrastRatio(dark, PAPER_RAISED.dark) < MIN_CONTRAST && t < 1; ) {
    t += 0.05
    dark = mix(base, WHITE, t)
  }
  const onDark = [ON_CURRENT_DEFAULT.dark, ON_CURRENT_DEFAULT.light].find((c) => contrastRatio(dark, c) >= MIN_CONTRAST)
  if (!onDark || contrastRatio(dark, PAPER_RAISED.dark) < MIN_CONTRAST) return 'cannot reach 4.5:1 in the dark theme'

  return {
    current: toHex(base),
    currentStrong: toHex(mix(base, BLACK, 0.25)),
    currentTint: toHex(mix(base, PAPER_RAISED.light, 0.85)),
    onCurrent: toHex(onLight),
    currentDark: toHex(dark),
    currentStrongDark: toHex(mix(dark, WHITE, 0.25)),
    currentTintDark: toHex(mix(dark, PAPER_RAISED.dark, 0.8)),
    onCurrentDark: toHex(onDark),
  }
}

/**
 * Sets the CSS custom properties for every key present in the closed BRAND_COLOR_CSS_PROPERTY allowlist
 * and present (as a non-empty string) in `brandColors`. Keys outside the allowlist are never read: this
 * function iterates the allowlist's OWN keys, never `Object.keys(brandColors)`.
 *
 * `primary` also writes the derived partners (TENANT_DERIVED_CSS_PROPERTY); a refused colour writes
 * nothing, so tokens.css's Letflow teal applies. `secondary` stays in the allowlist but is unused.
 * Absent/falsy values are left untouched.
 */
export function applyBrandingColors(brandColors: Record<string, string> | undefined): void {
  const root = document.documentElement.style
  const allowlistedKeys = Object.keys(BRAND_COLOR_CSS_PROPERTY) as Array<keyof typeof BRAND_COLOR_CSS_PROPERTY>

  for (const key of allowlistedKeys) {
    const value = brandColors?.[key]
    if (typeof value !== 'string' || value.length === 0) continue

    if (key !== 'primary') {
      root.setProperty(BRAND_COLOR_CSS_PROPERTY[key], value)
      continue
    }

    const derived = deriveTenantColours(value)
    const props = [BRAND_COLOR_CSS_PROPERTY.primary, ...Object.values(TENANT_DERIVED_CSS_PROPERTY)]
    if (typeof derived === 'string') {
      refuse(value, derived)
      props.forEach((p) => root.removeProperty(p))
      continue
    }
    root.setProperty(BRAND_COLOR_CSS_PROPERTY.primary, derived.current)
    for (const [k, prop] of Object.entries(TENANT_DERIVED_CSS_PROPERTY)) {
      root.setProperty(prop, derived[k as keyof Derived])
    }
  }
}
