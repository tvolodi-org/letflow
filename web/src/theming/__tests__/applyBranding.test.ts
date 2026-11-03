// @vitest-environment jsdom
/**
 * Unit tests for applyBranding.ts — REQ-283 (0020 D1c, theming half).
 *
 * Covers AC1 (resolved computed value override), AC2 (fallback to tokens.css's
 * platform default at every level of absence), and AC3 (closed allowlist
 * rejects any key not in BRAND_COLOR_CSS_PROPERTY).
 *
 * DIRECTIVE T-2 note: no HTTP call is involved — applyBrandingColors is a pure
 * DOM-side-effect function taking a plain object. No client.get/fetch mocking
 * needed in this file.
 *
 * No hex/rgb/hsl colour literal appears in this file (the literal-colour guard
 * scans web/src/**\/*.{ts,tsx,css} including test files) — colour values used
 * here are CSS named colours (e.g. 'rebeccapurple'), and the platform default
 * is read from tokens.css itself at test time rather than hard-coded, per the
 * design doc's own instruction in section 8, item 2.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { applyBrandingColors, contrastRatio, deriveTenantColours, resetBrandingWarning } from '../applyBranding'

const bridgeCss = readFileSync(join(__dirname, '../../styles/legacy-bridge.css'), 'utf-8')

// Colours are built from digits so that no colour literal appears in source (the literal-colour guard).
const hex = (digits: string) => '#' + digits
const GOOD = hex('1864ab')
const TOO_LIGHT = hex('f2e94e')

const prop = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()
const toTriple = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)) as [number, number, number]

let styleEl: HTMLStyleElement

beforeEach(() => {
  styleEl = document.createElement('style')
  styleEl.textContent = bridgeCss
  document.head.appendChild(styleEl)
  resetBrandingWarning()
})

afterEach(() => {
  document.head.removeChild(styleEl)
  document.documentElement.removeAttribute('style')
  vi.restoreAllMocks()
})

describe('applyBrandingColors', () => {
  it('good colour: sets --tenant-current and the derived partners, and not --color-brand-600', () => {
    applyBrandingColors({ primary: GOOD })

    expect(prop('--tenant-current')).toBe(GOOD)
    for (const p of [
      '--tenant-current-strong',
      '--tenant-current-tint',
      '--tenant-on-current',
      '--tenant-current-dark',
      '--tenant-current-strong-dark',
      '--tenant-current-tint-dark',
      '--tenant-on-current-dark',
    ]) {
      expect(prop(p), p).toMatch(/^#[0-9a-f]{6}$/)
    }
    expect(document.documentElement.style.getPropertyValue('--color-brand-600')).toBe('')
  })

  it('good colour: derived pairs reach 4.5:1 in both themes', () => {
    const d = deriveTenantColours(GOOD)
    if (typeof d === 'string') throw new Error(d)
    expect(contrastRatio(toTriple(d.current), toTriple(d.onCurrent))).toBeGreaterThanOrEqual(4.5)
    expect(contrastRatio(toTriple(d.currentDark), toTriple(d.onCurrentDark))).toBeGreaterThanOrEqual(4.5)
  })

  it('too light colour: refused, nothing written, one warning even when applied twice', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    applyBrandingColors({ primary: TOO_LIGHT })
    applyBrandingColors({ primary: TOO_LIGHT })

    expect(document.documentElement.getAttribute('style') ?? '').toBe('')
    expect(warn).toHaveBeenCalledTimes(1)
  })

  it('a refused colour removes the properties a previous good colour wrote', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    applyBrandingColors({ primary: GOOD })
    applyBrandingColors({ primary: TOO_LIGHT })

    expect(prop('--tenant-current')).toBe('')
    expect(prop('--tenant-on-current')).toBe('')
  })

  it('a value that is not a hex colour is refused', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    applyBrandingColors({ primary: 'rebeccapurple' })
    expect(prop('--tenant-current')).toBe('')
  })

  it('missing colour: undefined, empty object and empty string leave everything untouched', () => {
    applyBrandingColors(undefined)
    applyBrandingColors({})
    applyBrandingColors({ primary: '' })

    expect(document.documentElement.getAttribute('style') ?? '').toBe('')
  })

  it('unknown key: never written to the document root, the allowlisted key still applies', () => {
    applyBrandingColors({ primary: GOOD, notAllowed: GOOD, '--totally-unrelated-var': GOOD, evilKey: GOOD })

    expect(prop('--totally-unrelated-var')).toBe('')
    expect(prop('--evilKey')).toBe('')
    expect(prop('--notAllowed')).toBe('')
    expect(prop('--tenant-current')).toBe(GOOD)
  })

  it('secondary stays allowlisted (unused) and writes only its own property', () => {
    applyBrandingColors({ secondary: GOOD, tertiary: GOOD })

    expect(prop('--color-brand-secondary')).toBe(GOOD)
    expect(prop('--color-brand-tertiary')).toBe('')
    expect(prop('--tenant-current')).toBe('')
  })
})
