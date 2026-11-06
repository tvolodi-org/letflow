// @vitest-environment jsdom
/** C5, S6 store — T-1443: the stored column ids are valid under the sanitize rules, and a reset reaches subscribers. */
import { describe, expect, it, vi } from 'vitest'
import { createLayoutStore } from '@/lib/layoutStore'
import { sanitizeUiLayout } from '@/lib/layoutPrefs'
import { DOC_KINDS } from '../documents/documentsModel'
import { lineColumns, lineColumnSpecs } from '../documents/lineColumns'

const t = (id: string) => id

describe('lineColumnSpecs', () => {
  it.each(DOC_KINDS)('%s: spec ids are the colIds of lineColumns, valid ids, flexible column last', (kind) => {
    const specs = lineColumnSpecs(kind)
    const ids = lineColumns(kind, t).flatMap((c) => (c.colId ? [c.colId] : []))
    if (kind === 'opening') {
      expect(specs).toEqual([])
      return
    }
    expect(specs.map((s) => s.id)).toEqual(ids)
    for (const s of specs) expect(s.id).toMatch(/^[a-z0-9-]{1,24}$/)
    expect(specs.slice(0, -1).reduce((n, s) => n + s.w, 0)).toBeLessThan(94)
  })

  it('a width for every receipt column survives sanitizeUiLayout', () => {
    const cols = Object.fromEntries(lineColumnSpecs('receipt').map((s) => [s.id, s.w]))
    const doc = sanitizeUiLayout({ v: 1, shell: {}, screens: { 'stock.documents': { cols: { lines: cols, 'lines-edit': cols } } } })
    expect(doc.screens['stock.documents']?.cols?.['lines']).toEqual(cols)
    expect(doc.screens['stock.documents']?.cols?.['lines-edit']).toEqual(cols)
  })
})

describe('layout store resetScreen', () => {
  it('forgets the screen and tells subscribers at once', () => {
    localStorage.clear()
    const store = createLayoutStore({ storageKey: 'test.reset' })
    store.setPanes('s', 'row', [20, 18])
    const seen = vi.fn()
    store.subscribe(seen)
    store.resetScreen('s')
    expect(seen).toHaveBeenCalledTimes(1)
    expect(store.getPanes('s', 'row')).toBeNull()
  })
})
