// @vitest-environment node
/**
 * Migration bridge (task S0a): every old token name still used in web/src must be defined by
 * legacy-bridge.css (or by the generated tokens). When the last use is migrated, this list and the
 * bridge file go away together.
 */
import { readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import fg from 'fast-glob'
import { describe, expect, it } from 'vitest'

const WEB_ROOT = join(__dirname, '..', '..', '..')
const STYLES = join(WEB_ROOT, 'src', 'styles')
const DEF = /(?:^|[\s;{])(--[a-zA-Z0-9_-]+)\s*:/g

/** The names of the pre-design-system src/styles/tokens.css that the new generated tokens do not define. */
const LEGACY_NAMES = [
  ...['0', '50', '100', '200', '300', '400', '500', '600', '700', '800', '900'].map(n => `--color-neutral-${n}`),
  '--color-brand-400', '--color-brand-500', '--color-brand-600', '--color-brand-700', '--color-brand-secondary',
  '--color-success-light', '--color-success', '--color-success-dark', '--color-success-border', '--color-success-tint',
  '--color-warning-light', '--color-warning', '--color-warning-dark', '--color-warning-tint',
  '--color-warning-border', '--color-warning-text', '--color-warning-banner',
  '--color-error-light', '--color-error', '--color-error-dark', '--color-error-border',
  '--color-error-border-strong', '--color-error-tint', '--color-failure',
  '--color-info-light', '--color-info', '--color-info-dark', '--color-info-tint', '--color-info-text',
  '--surface-page', '--surface-card', '--surface-sidebar', '--surface-overlay', '--surface-overlay-slate',
  '--color-sidebar-active', '--text-primary', '--text-secondary', '--text-disabled', '--text-inverse',
  '--border-default', '--border-focus', '--border-error',
  '--interactive-primary', '--interactive-primary-hover', '--interactive-danger', '--interactive-danger-hover',
  '--minimap-mask-color', '--drop-shadow-overlay',
  '--shadow-card', '--shadow-sm', '--shadow-modal', '--shadow-modal-lg', '--shadow-lg', '--shadow-dialog',
  '--shadow-panel', '--shadow-modal-compact', '--shadow-focus-brand', '--shadow-focus-blue',
  ...['blue', 'teal', 'violet', 'orange', 'cyan', 'green', 'purple', 'sky', 'rust', 'indigo'].map(n => `--color-avatar-${n}`),
  '--text-xs', '--text-sm', '--text-base', '--text-lg', '--font-medium', '--z-conflict', '--z-conflict-panel',
]

function defs(file: string): Set<string> {
  return new Set([...readFileSync(join(STYLES, file), 'utf8').matchAll(DEF)].map(m => m[1]))
}

describe('legacy token bridge', () => {
  const bridge = defs('legacy-bridge.css')
  const generated = new Set([...defs('tokens.css'), ...defs('components.css')])

  it('does not redefine a name the generated tokens own', () => {
    expect([...bridge].filter(n => generated.has(n))).toEqual([])
  })

  it('defines every old name still used in web/src', async () => {
    const files = await fg('src/**/*.{ts,tsx,css}', { cwd: WEB_ROOT, ignore: ['src/styles/**'] })
    const missing: string[] = []
    for (const rel of files) {
      const text = readFileSync(join(WEB_ROOT, rel), 'utf8')
      for (const name of LEGACY_NAMES) {
        if (text.includes(`${name}`) && !bridge.has(name)) missing.push(`${relative(WEB_ROOT, join(WEB_ROOT, rel))}: ${name}`)
      }
    }
    expect(missing).toEqual([])
  })

  it('meta: a name missing from the bridge would be reported', () => {
    expect(bridge.has('--surface-page')).toBe(true)
    expect(bridge.has('--surface-not-a-token')).toBe(false)
  })
})
