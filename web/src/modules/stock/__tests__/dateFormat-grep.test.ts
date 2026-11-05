/** D-3 / T-TZ — GH 3735 R7: no screen formats a date on its own. Every date-time goes through
 *  `formatStockDateTime` / `i18n/format.ts`; the zone literal is named once. */
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = join(__dirname, '../../..')
const BAN = /toLocaleDateString|toLocaleTimeString|\.toLocaleString\(|new Intl\.DateTimeFormat\(/
/** Zone/offset helpers (not display formatting): exact allowlist, file -> number of hits. */
const ALLOW: Record<string, number> = {
  'modules/stock/documents/documentsModel.ts': 1,
  'modules/stock/counts/countsModel.ts': 1,
}

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) {
      if (name === '__tests__' || name === 'dev') continue
      walk(p, out)
    } else if (/\.(ts|tsx)$/.test(name) && !/\.test\./.test(name)) out.push(p)
  }
  return out
}

export function banHits(files: Record<string, string>): Record<string, number> {
  const hits: Record<string, number> = {}
  for (const [f, text] of Object.entries(files)) {
    const n = text.split('\n').filter((l) => BAN.test(l) && !l.trim().startsWith('*') && !l.trim().startsWith('//')).length
    if (n > 0) hits[f] = n
  }
  return hits
}

describe('D-3 no screen formats dates itself', () => {
  it('stock modules, pages and components only use the shared formatter', () => {
    const files: Record<string, string> = {}
    for (const root of ['modules/stock', 'pages', 'components']) {
      for (const f of walk(join(SRC, root))) files[relative(SRC, f)] = readFileSync(f, 'utf8')
    }
    const hits = banHits(files)
    for (const [f, n] of Object.entries(hits)) {
      expect(ALLOW[f], `${f} formats dates by hand (${n} hit(s)); use formatStockDateTime`).toBeDefined()
      expect(n).toBeLessThanOrEqual(ALLOW[f])
    }
  })

  it('self-test: a planted toLocaleDateString is caught', () => {
    expect(banHits({ 'x.tsx': 'const a = d.toLocale' + 'DateString()\n' })).toEqual({ 'x.tsx': 1 })
    expect(banHits({ 'x.tsx': '// d.toLocale' + 'DateString()\n' })).toEqual({})
  })

  it('T-TZ: the zone literal is named once in the stock module', () => {
    const files = walk(join(SRC, 'modules/stock')).filter((f) => readFileSync(f, 'utf8').includes("'Asia/Almaty'"))
    expect(files.map((f) => relative(SRC, f))).toEqual(['modules/stock/register/stockRegisterModel.ts'])
  })
})
