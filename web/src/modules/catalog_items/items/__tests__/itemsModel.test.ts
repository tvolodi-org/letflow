/** A3 — T-1402: search, tracking filter, Show retired, sort and paging of the Items list (pure). */
import { describe, expect, it } from 'vitest'
import type { EntityRecord } from '@/types/api'
import { ITEMS_PAGE_SIZE, causeKey, filterItems, pageCountOf, pageOf, sortItems, toItemRow } from '../itemsModel'

function rec(id: string, fv: Record<string, unknown>): EntityRecord {
  return { record_id: id, entity_type: 'catalog_item', field_values: fv, deleted: false, entity_def_version: '1', last_event_global_seq: 1 }
}

const ROWS = [
  rec('1', { code: 'B-10', name: 'Bolt', active: true, tracking_policy: 'lot', base_uom_id: 'u' }),
  rec('2', { code: 'A-2', name: 'Nut', active: true }),
  rec('3', { code: 'A-10', name: 'Washer', active: false, tracking_policy: 'serial' }),
].map(toItemRow)

describe('A3 itemsModel', () => {
  it('an absent tracking_policy counts as none; active defaults to true', () => {
    expect(ROWS[1]?.tracking).toBe('none')
    expect(ROWS[1]?.active).toBe(true)
    expect(ROWS[2]?.active).toBe(false)
  })

  it('hides retired items unless asked, filters by tracking (none included) and by code or title', () => {
    const f = { q: '', tracking: '' as const, showRetired: false }
    expect(filterItems(ROWS, f).map((r) => r.code)).toEqual(['B-10', 'A-2'])
    expect(filterItems(ROWS, { ...f, showRetired: true })).toHaveLength(3)
    expect(filterItems(ROWS, { ...f, tracking: 'none' }).map((r) => r.code)).toEqual(['A-2'])
    expect(filterItems(ROWS, { ...f, q: 'bol' }).map((r) => r.code)).toEqual(['B-10'])
    expect(filterItems(ROWS, { ...f, q: 'A-' }).map((r) => r.code)).toEqual(['A-2'])
  })

  it('sorts by code naturally, by title and by status, both directions', () => {
    expect(sortItems(ROWS, 'code', 'asc').map((r) => r.code)).toEqual(['A-2', 'A-10', 'B-10'])
    expect(sortItems(ROWS, 'code', 'desc').map((r) => r.code)).toEqual(['B-10', 'A-10', 'A-2'])
    expect(sortItems(ROWS, 'name', 'asc').map((r) => r.name)).toEqual(['Bolt', 'Nut', 'Washer'])
    expect(sortItems(ROWS, 'status', 'asc').map((r) => r.code)).toEqual(['A-2', 'B-10', 'A-10'])
  })

  it('pages by 25 and clamps the page', () => {
    const many = Array.from({ length: 60 }, (_, i) => i)
    expect(ITEMS_PAGE_SIZE).toBe(25)
    expect(pageCountOf(60)).toBe(3)
    expect(pageCountOf(0)).toBe(1)
    expect(pageOf(many, 3)).toMatchObject({ page: 3, from: 51, to: 60 })
    expect(pageOf(many, 9).page).toBe(3)
    expect(pageOf([], 1)).toMatchObject({ from: 0, to: 0, rows: [] })
  })

  it('maps a movement cause to a message tag', () => {
    expect(causeKey('count_difference')).toBe('count')
    expect(causeKey('reversal')).toBe('reversal')
    expect(causeKey('opening')).toBe('receipt')
    expect(causeKey('something')).toBe('other')
  })
})
