/**
 * T-1586 (a): colour contrast of the design tokens in both themes, WCAG 2.1 AA (4.5:1 text, 3:1 non-text),
 * plus a scan of the component rules that put a token colour on a token background.
 * Result tables: docs/design-system/accessibility.md. Tenant brand colours are guarded by applyBranding.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { contrastRatio } from '../../src/theming/applyBranding'

const STYLES = join(__dirname, '../../src/styles')
type Rgb = [number, number, number]
type Theme = Record<string, string>

function hex(v: string): Rgb {
  let h = v.replace('#', '')
  if (h.length === 3) h = h.split('').map((c) => c + c).join('')
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) as Rgb
}

function declarations(block: string): Theme {
  const out: Theme = {}
  for (const m of block.matchAll(/--([a-z0-9-]+):\s*([^;]+);/g)) out[m[1]] = m[2].trim()
  return out
}

const tokens = readFileSync(join(STYLES, 'tokens.css'), 'utf8')
function blockAt(start: number): string {
  const open = tokens.indexOf('{', start)
  let depth = 0
  for (let i = open; i < tokens.length; i++) {
    if (tokens[i] === '{') depth++
    if (tokens[i] === '}' && --depth === 0) return tokens.slice(open + 1, i)
  }
  throw new Error('unbalanced tokens.css')
}
const light = declarations(blockAt(tokens.indexOf(':root, [data-theme="light"]')))
const dark = declarations(blockAt(tokens.indexOf('[data-theme="dark"] {')))
const darkMedia = declarations(blockAt(tokens.indexOf(':root:not([data-theme="light"])')))
const THEMES: Record<string, Theme> = { light, dark }

/** Resolve a token to a hex colour: `var(--x, #fallback)` takes the fallback, `var(--x)` follows x. */
function resolve(theme: Theme, name: string, depth = 0): Rgb | null {
  const v = theme[name]
  if (v === undefined || depth > 5) return null
  const m = v.match(/^var\(--([a-z0-9-]+)(?:,\s*(.+))?\)$/)
  if (m) {
    if (m[2] && /^#[0-9a-f]{3,6}$/i.test(m[2].trim())) return hex(m[2].trim())
    return resolve(theme, m[1], depth + 1)
  }
  return /^#[0-9a-f]{3,6}$/i.test(v) ? hex(v) : null
}

const ratio = (theme: Theme, fg: string, bg: string): number => contrastRatio(resolve(theme, fg)!, resolve(theme, bg)!)

const TEXT_PAIRS: Array<[string, string]> = []
for (const bg of ['paper', 'paper-raised', 'row-hover']) for (const fg of ['ink', 'ink-muted', 'ink-faint']) TEXT_PAIRS.push([fg, bg])
TEXT_PAIRS.push(['ink', 'paper-sunken'], ['ink-muted', 'paper-sunken'])
TEXT_PAIRS.push(['on-current', 'current'], ['current', 'paper-raised'], ['current-strong', 'paper-raised'], ['current', 'current-tint'], ['current-strong', 'current-tint'])
TEXT_PAIRS.push(['on-ember', 'ember'], ['ember-ink', 'paper'], ['on-night', 'night'], ['on-night-muted', 'night'])
for (const s of ['info', 'warning', 'success', 'danger']) TEXT_PAIRS.push([s, 'paper-raised'], [s, `${s}-tint`])

const NON_TEXT_PAIRS: Array<[string, string]> = [
  ['line-strong', 'paper'], ['line-strong', 'paper-raised'], ['focus', 'paper'], ['focus', 'paper-raised'],
  ['focus', 'night'], ['current-on-night', 'night'], ['danger', 'paper'],
]

/** Known and accepted, with the reason (listed in accessibility.md). Pinned so a new one is a decision. */
const KNOWN_EXEMPT = ['ink-faint/paper-sunken (latent: no rule uses it, light 4.39:1)', 'line/paper (decorative divider, exempt from 1.4.11)']

describe('contrast of the design tokens', () => {
  for (const [name, theme] of Object.entries(THEMES)) {
    it(`C1a/b: text pairs reach 4.5:1 (${name})`, () => {
      const bad = TEXT_PAIRS.filter(([fg, bg]) => resolve(theme, fg) && resolve(theme, bg) && ratio(theme, fg, bg) < 4.5)
        .map(([fg, bg]) => `${fg}/${bg} ${ratio(theme, fg, bg).toFixed(2)}`)
      expect(bad).toEqual([])
      // Every pair must be resolvable, so a renamed token cannot drop out of the check unseen.
      expect(TEXT_PAIRS.filter(([fg, bg]) => !resolve(theme, fg) || !resolve(theme, bg))).toEqual([])
    })
    it(`C1c/d: non-text pairs reach 3:1 (${name})`, () => {
      const bad = NON_TEXT_PAIRS.filter(([fg, bg]) => ratio(theme, fg, bg) < 3).map(([fg, bg]) => `${fg}/${bg} ${ratio(theme, fg, bg).toFixed(2)}`)
      expect(bad).toEqual([])
    })
  }

  it('C1e: the two dark blocks hold the same values (media query vs data-theme)', () => {
    for (const [k, v] of Object.entries(dark)) {
      if (k.startsWith('shadow') || k.startsWith('tenant')) continue
      if (darkMedia[k] !== undefined) expect(darkMedia[k], k).toBe(v)
    }
  })

  it('C1f: the exempt pairs stay exactly the documented ones', () => {
    const failing: string[] = []
    if (ratio(light, 'ink-faint', 'paper-sunken') < 4.5) failing.push('ink-faint/paper-sunken')
    if (ratio(light, 'line', 'paper') < 3) failing.push('line/paper')
    expect(failing).toEqual(['ink-faint/paper-sunken', 'line/paper'])
    expect(KNOWN_EXEMPT).toHaveLength(2)
  })
})

// C2: per component rule, token foreground on token background.
const SELECTORS_3_TO_1 = new Set<string>() // large text / icons: none needed today; add with a comment per entry.
const SKIPPED_PINNED_MAX = 12

function ruleContrast(file: string): { fails: string[]; checked: number; skipped: number } {
  const css = readFileSync(join(STYLES, file), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  const fails: string[] = []
  let checked = 0
  let skipped = 0
  for (const m of css.matchAll(/([^{}@]+)\{([^{}]*)\}/g)) {
    const sel = m[1].trim()
    const body = m[2]
    const fg = body.match(/(?:^|[;\s])color:\s*var\(--([a-z0-9-]+)\)/)
    const bg = body.match(/background(?:-color)?:\s*var\(--([a-z0-9-]+)\)/)
    if (!fg || !bg) continue
    for (const [name, theme] of Object.entries(THEMES)) {
      if (!resolve(theme, fg[1]) || !resolve(theme, bg[1])) { skipped++; continue }
      checked++
      const min = SELECTORS_3_TO_1.has(sel) ? 3 : 4.5
      const r = ratio(theme, fg[1], bg[1])
      if (r < min) fails.push(`${file} ${sel} (${name}): ${fg[1]} on ${bg[1]} ${r.toFixed(2)}`)
    }
  }
  return { fails, checked, skipped }
}

describe('contrast of component rules', () => {
  for (const file of ['components.css', 'base.css']) {
    it(`C2: every token colour on token background pair in ${file} reaches 4.5:1, light and dark`, () => {
      const r = ruleContrast(file)
      expect(r.checked).toBeGreaterThan(0)
      expect(r.skipped).toBeLessThanOrEqual(SKIPPED_PINNED_MAX)
      expect(r.fails).toEqual([])
    })
  }
})
