// @vitest-environment node
/** T-1520 D1..D3 and M1: the design note docs/design/process-designer.md stays in step with the code and the
 *  shipped packs, and the diagram's message catalogue has the same ids in en, ru and kk. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'
import { FORMAT_KEYS } from '../diagramConfig'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'

const REPO = join(__dirname, '..', '..', '..', '..', '..')
const NOTE = readFileSync(join(REPO, 'docs/design/process-designer.md'), 'utf8')

function section(heading: string): string {
  const i = NOTE.indexOf(`## ${heading}`)
  expect(i).toBeGreaterThanOrEqual(0)
  const j = NOTE.indexOf('\n## ', i + 3)
  return NOTE.slice(i, j < 0 ? undefined : j)
}

describe('process designer note', () => {
  it('D1 has the required sections and a licence on every library row', () => {
    for (const h of ['Library choice', 'What the definition holds', 'Instance path', 'Accessibility', 'Large definitions']) section(h)
    const rows = section('Library choice')
      .split('\n')
      .filter((l) => l.startsWith('|') && !l.startsWith('|---') && !l.startsWith('| option'))
    expect(rows.length).toBeGreaterThanOrEqual(3)
    for (const r of rows) expect(r).toMatch(/MIT|Apache|EPL|n\/a/)
  })

  it('D2 every known key and every shipped attribute key is in the inventory with a decision', () => {
    const table = section('What the definition holds')
      .split('\n')
      .filter((l) => l.startsWith('|'))
    const decided = (key: string) => table.some((l) => l.includes(`\`${key}\``) && /SHOWN|SUMMARISED|DOCUMENTED|IGNORED/.test(l))
    const keys = new Set<string>(Object.values(FORMAT_KEYS).flat())
    for (const rel of fg.sync('priv/modules/*/pack.json', { cwd: REPO })) {
      const pack = JSON.parse(readFileSync(join(REPO, rel), 'utf8')) as { definitions?: { graph?: { nodes?: { attributes?: unknown }[] } }[] }
      for (const d of pack.definitions ?? []) {
        for (const n of d.graph?.nodes ?? []) {
          const a = typeof n.attributes === 'string' ? (JSON.parse(n.attributes) as object) : n.attributes
          if (a && typeof a === 'object') for (const k of Object.keys(a)) keys.add(k)
        }
      }
    }
    for (const k of ['form_schema', 'module_writes', 'endpoint', 'service_id', 'distinct_from']) keys.add(k)
    const missing = [...keys].filter((k) => !decided(k))
    expect(missing).toEqual([])
  })

  it('D3 the instance-path section names its evidence sources', () => {
    const s = section('Instance path')
    for (const term of ['affected.node_id', 'TASK_COMPLETED', 'next_cursor', 'a parallel join is shown done once anything after it has certainly run']) {
      expect(s).toContain(term)
    }
  })
})

describe('processDiagram messages', () => {
  it('M1 en, ru and kk have the same ids; the page switch and badge are translated', () => {
    const en = Object.keys(processDiagramMessages.en).sort()
    expect(Object.keys(processDiagramMessages.ru).sort()).toEqual(en)
    expect(Object.keys(processDiagramMessages.kk).sort()).toEqual(en)
    for (const id of en) {
      expect(id.startsWith('processDiagram.')).toBe(true)
      for (const l of ['en', 'ru', 'kk'] as const) expect(processDiagramMessages[l][id].trim()).not.toBe('')
    }
    for (const id of ['group', 'diagram', 'editor', 'unsavedBadge'].map((x) => `processDiagram.view.${x}`)) {
      expect(processDiagramMessages.ru[id]).not.toBe(processDiagramMessages.en[id])
      expect(processDiagramMessages.kk[id]).not.toBe(processDiagramMessages.en[id])
    }
  })
})
