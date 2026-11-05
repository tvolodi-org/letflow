import { describe, it, expect } from 'vitest'
import { isUuid, labelOfRecord } from '../referenceLabel'

const ID = '5b58a738-1c2d-4e3f-8a9b-0c1d2e3f4a5b'
const r = (fv: Record<string, unknown>) => ({ field_values: fv })

describe('labelOfRecord', () => {
  it('is "code - title" when both exist', () => {
    expect(labelOfRecord('catalog_item', r({ code: 'ITM-1', name: 'Bolt M8' }))).toBe('ITM-1 - Bolt M8')
    expect(labelOfRecord('org_employee', r({ code: 'E-7', full_name: 'Aigul B.' }))).toBe('E-7 - Aigul B.')
  })
  it('is the one that exists when only one does', () => {
    expect(labelOfRecord('catalog_item', r({ name: 'Bolt M8' }))).toBe('Bolt M8')
    expect(labelOfRecord('org_unit', r({ code: 'MS' }))).toBe('MS')
  })
  it('shows a lot and a unit by code (unit falls back to its name)', () => {
    expect(labelOfRecord('catalog_lot', r({ code: 'LOT-7', item_id: ID }))).toBe('LOT-7')
    expect(labelOfRecord('catalog_uom', r({ code: 'PCS', name: 'Piece' }))).toBe('PCS')
    expect(labelOfRecord('catalog_uom', r({ name: 'pcs' }))).toBe('pcs')
  })
  it('does not repeat a code equal to the title', () => {
    expect(labelOfRecord('location_node', r({ code: 'A1', name: 'A1' }))).toBe('A1')
  })
  it('is null when the record has nothing to show: never the id', () => {
    expect(labelOfRecord('catalog_item', r({ active: true, base_uom_id: ID }))).toBeNull()
  })
})

describe('isUuid', () => {
  it('knows a uuid', () => {
    expect(isUuid(ID)).toBe(true)
    expect(isUuid(ID.toUpperCase())).toBe(true)
    expect(isUuid('i1')).toBe(false)
    expect(isUuid(null)).toBe(false)
  })
})
