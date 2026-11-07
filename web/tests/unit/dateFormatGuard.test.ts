// @vitest-environment node
/**
 * T-1381 guard -- dates are shown through the one shared formatter (`src/i18n/format.ts`).
 * Bans, in screens and helpers under src/: `.toLocaleDateString(`, `.toLocaleTimeString(`, `.toLocaleString(`,
 * `.toDateString(`, `.toTimeString(`, `new Date(...).toString(`, `Intl.DateTimeFormat` and `intl.formatDate(` /
 * `intl.formatTime(` outside the allowlist below. Comment lines are skipped.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import fg from 'fast-glob'

const SRC_ROOT = join(__dirname, '..', '..', 'src')

export const BANNED: { name: string; re: RegExp }[] = [
  { name: 'toLocale(Date|Time)?String', re: /\.toLocale(Date|Time)?String\(/ },
  { name: 'toDateString/toTimeString', re: /\.to(Date|Time)String\(/ },
  { name: 'new Date(...).toString()', re: /new Date\([^)]*\)\.toString\(/ },
  { name: 'Intl.DateTimeFormat', re: /\bIntl\.DateTimeFormat\b(?!Options|Part)/ },
  { name: 'intl.formatDate/formatTime', re: /\bintl\.format(Date|Time)\(/ },
]

/** file (relative to src, forward slashes) -> pattern names allowed there, each with its reason. */
const ALLOW: Record<string, { names: string[]; reason: string }> = {
  'i18n/format.ts': { names: ['Intl.DateTimeFormat'], reason: 'the shared formatter itself' },
  'modules/assets/documents/documentForm.ts': { names: ['Intl.DateTimeFormat'], reason: 'offsetMinutes: zone arithmetic for the input value, not display' },
  'modules/stock/documents/documentsModel.ts': { names: ['Intl.DateTimeFormat'], reason: 'offsetMinutes: zone arithmetic for the input value, not display' },
  'modules/stock/counts/countsModel.ts': { names: ['Intl.DateTimeFormat'], reason: 'parts(): the datetime-local input value, not display' },
}

export function violations(file: string, content: string): string[] {
  const allowed = ALLOW[file]?.names ?? []
  const code = content.split('\n').map((l, i) => ({ l, i: i + 1 })).filter(({ l }) => {
    const t = l.trim()
    return !t.startsWith('*') && !t.startsWith('//') && !t.startsWith('/*')
  })
  const out: string[] = []
  for (const { l, i } of code) for (const b of BANNED) if (!allowed.includes(b.name) && b.re.test(l)) out.push(`${file}:${i} ${b.name}`)
  return out
}

describe('T-1381 G1 -- no hand-built date strings in src/', () => {
  it('no banned date-format pattern outside the allowlist', async () => {
    const files = await fg('**/*.{ts,tsx}', { cwd: SRC_ROOT, ignore: ['**/__tests__/**', '**/*.test.*'] })
    const found = files.flatMap((f) => violations(relative(SRC_ROOT, join(SRC_ROOT, f)).split('\\').join('/'), readFileSync(join(SRC_ROOT, f), 'utf-8')))
    expect(found).toEqual([])
  })

  it('self-test: each banned pattern is flagged, an allowlisted one is not', () => {
    const samples = [
      'x.toLocaleDateString()', 'x.toLocaleTimeString("ru")', 'x.toLocaleString()', 'x.toDateString()', 'x.toTimeString()',
      'new Date(v).toString()', 'new Intl.DateTimeFormat("en")', 'intl.formatDate(d)', 'intl.formatTime(d)',
    ]
    for (const s of samples) expect(violations('pages/X.tsx', s).length, s).toBe(1)
    expect(violations('pages/X.tsx', '// x.toLocaleString()')).toEqual([])
    expect(violations('i18n/format.ts', 'new Intl.DateTimeFormat("en")')).toEqual([])
  })

  it('every allowlist entry still exists and still needs it', async () => {
    for (const f of Object.keys(ALLOW)) {
      const content = readFileSync(join(SRC_ROOT, f), 'utf-8')
      expect(BANNED.some((b) => ALLOW[f].names.includes(b.name) && b.re.test(content)), f).toBe(true)
    }
  })
})
