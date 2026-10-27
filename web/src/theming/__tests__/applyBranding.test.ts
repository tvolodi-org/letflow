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
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { applyBrandingColors } from '../applyBranding'

const TOKENS_CSS_PATH = join(__dirname, '../../styles/tokens.css')
const tokensCssContent = readFileSync(TOKENS_CSS_PATH, 'utf-8')

/** Must track tokens.css's --color-brand-600 — read live, never hard-coded. */
function readPlatformDefaultBrand600(): string {
  const match = tokensCssContent.match(/--color-brand-600:\s*([^;]+);/)
  if (!match) {
    throw new Error(
      'tokens.css no longer defines --color-brand-600 — this test fixture is out of date',
    )
  }
  return match[1].trim()
}

function readPlatformDefaultSecondary(): string {
  const match = tokensCssContent.match(/--color-brand-secondary:\s*([^;]+);/)
  if (!match) {
    throw new Error('tokens.css does not define --color-brand-secondary')
  }
  return match[1].trim()
}

let styleEl: HTMLStyleElement

beforeEach(() => {
  // Inject tokens.css's real :root rules so getComputedStyle resolves the same
  // cascade default the production app gets from its own <link>/import.
  styleEl = document.createElement('style')
  styleEl.textContent = tokensCssContent
  document.head.appendChild(styleEl)
})

afterEach(() => {
  document.head.removeChild(styleEl)
  // Clear any inline overrides applyBrandingColors left on the root so tests
  // don't leak state into each other.
  document.documentElement.removeAttribute('style')
})

describe('applyBrandingColors', () => {
  it('AC1: overrides --color-brand-600 to the tenant-supplied value — resolved computed value, not just "was set"', () => {
    applyBrandingColors({ primary: 'rebeccapurple' })

    const resolved = getComputedStyle(document.documentElement)
      .getPropertyValue('--color-brand-600')
      .trim()
    expect(resolved).toBe('rebeccapurple')
  })

  it('AC2a: brand_colors undefined (branding block absent) leaves the tokens.css platform default in place', () => {
    applyBrandingColors(undefined)

    const resolved = getComputedStyle(document.documentElement)
      .getPropertyValue('--color-brand-600')
      .trim()
    expect(resolved).toBe(readPlatformDefaultBrand600())
  })

  it('AC2 (case 2): brand_colors present but missing the "primary" sub-key leaves the platform default in place', () => {
    applyBrandingColors({})

    const resolved = getComputedStyle(document.documentElement)
      .getPropertyValue('--color-brand-600')
      .trim()
    expect(resolved).toBe(readPlatformDefaultBrand600())
  })

  it('AC3: a key outside the closed allowlist is never written to the document root, while the allowlisted key still applies', () => {
    applyBrandingColors({
      primary: 'cadetblue',
      notAllowed: 'tomato',
      '--totally-unrelated-var': 'tomato',
    })

    const unrelated = getComputedStyle(document.documentElement)
      .getPropertyValue('--totally-unrelated-var')
      .trim()
    expect(unrelated).toBe('')

    const primary = getComputedStyle(document.documentElement)
      .getPropertyValue('--color-brand-600')
      .trim()
    expect(primary).toBe('cadetblue')
  })

  it('REQ-585: brand_colors {primary, secondary} sets both custom properties on the document root', () => {
    applyBrandingColors({ primary: 'rebeccapurple', secondary: 'darkorange' })

    const style = getComputedStyle(document.documentElement)
    expect(style.getPropertyValue('--color-brand-600').trim()).toBe('rebeccapurple')
    expect(style.getPropertyValue('--color-brand-secondary').trim()).toBe('darkorange')
  })

  it('REQ-585: a missing secondary leaves the tokens.css default in place', () => {
    applyBrandingColors({ primary: 'rebeccapurple' })

    const resolved = getComputedStyle(document.documentElement)
      .getPropertyValue('--color-brand-secondary')
      .trim()
    expect(resolved).toBe(readPlatformDefaultSecondary())
    expect(resolved).not.toBe('')
  })

  it('REQ-585: only allowlisted keys apply — an unknown key beside secondary is ignored', () => {
    applyBrandingColors({ secondary: 'darkorange', tertiary: 'tomato' })

    const style = getComputedStyle(document.documentElement)
    expect(style.getPropertyValue('--color-brand-secondary').trim()).toBe('darkorange')
    expect(style.getPropertyValue('--color-brand-tertiary').trim()).toBe('')
    expect(style.getPropertyValue('--tertiary').trim()).toBe('')
  })

  it('AC3: applyBrandingColors only ever iterates the allowlist\'s own keys, never Object.keys(brandColors)', () => {
    // A brandColors object shaped entirely outside the allowlist (no 'primary'
    // key at all) must result in zero custom properties being written.
    applyBrandingColors({ evilKey: 'tomato', anotherKey: 'orange' })

    expect(getComputedStyle(document.documentElement).getPropertyValue('--evilKey').trim()).toBe('')
    expect(getComputedStyle(document.documentElement).getPropertyValue('--anotherKey').trim()).toBe('')
    expect(getComputedStyle(document.documentElement).getPropertyValue('--color-brand-600').trim()).toBe(
      readPlatformDefaultBrand600(),
    )
  })
})
