/** M1, M2 — T-1333 / C13: form <-> request bodies, the decimal check, the error mapping. */
import { describe, expect, it } from 'vitest'
import type { EntityRecord } from '@/types/api'
import { createBody, decimalError, errorMessageId, EMPTY_FORM, fieldMarked, formOf, matchesSearch, reasonOf, updateBody } from '../assetsModel'

const record = (fields: Record<string, unknown>): EntityRecord => ({
  record_id: 'c-1',
  entity_type: 'assets_card',
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})

describe('M1 bodies and decimals', () => {
  it('createBody drops empty optionals and never sends valid_until for a non-intangible kind or active', () => {
    const form = { ...EMPTY_FORM, inventory_number: ' A-1 ', name: 'Van', org_unit_id: 'u-1', valid_until: '2027-01-01', acquisition_cost: '10.5' }
    expect(createBody(form)).toEqual({ kind: 'fixed', inventory_number: 'A-1', name: 'Van', org_unit_id: 'u-1', acquisition_cost: '10.5' })
    expect(createBody({ ...form, kind: 'intangible' })).toMatchObject({ kind: 'intangible', valid_until: '2027-01-01' })
    expect(createBody(form)).not.toHaveProperty('active')
  })

  it('updateBody sends only changed keys, clears to null, never kind or active', () => {
    const initial = formOf(record({ inventory_number: 'A-1', name: 'Van', kind: 'intangible', org_unit_id: 'u-1', valid_until: '2027-01-01', currency: 'KZT' }))
    expect(updateBody(initial, initial)).toEqual({})
    expect(updateBody(initial, { ...initial, name: 'Truck', valid_until: '', currency: 'KZT' })).toEqual({ name: 'Truck', valid_until: null })
    expect(updateBody(initial, { ...initial, kind: 'fixed', name: 'Truck' })).not.toHaveProperty('kind')
    const fixed = formOf(record({ inventory_number: 'A-1', name: 'Van', kind: 'fixed', org_unit_id: 'u-1' }))
    expect(updateBody(fixed, { ...fixed, valid_until: '2027-01-01' })).toEqual({})
  })

  it('decimalError accepts the strict form and refuses the rest', () => {
    for (const ok of ['', '0', '-1.5', '123456789012345.123456789', '10']) expect(decimalError(ok), ok).toBeNull()
    for (const bad of ['1e3', '1,5', '01', '.5', '1.', 'abc']) expect(decimalError(bad), bad).toBe('format')
    expect(decimalError('1234567890123456')).toBe('size')
    expect(decimalError('1.1234567890')).toBe('size')
  })

  it('matchesSearch looks at inventory number and name', () => {
    const r = record({ inventory_number: 'FA-0001', name: 'Delivery van' })
    expect(matchesSearch(r, 'fa-00')).toBe(true)
    expect(matchesSearch(r, 'VAN')).toBe(true)
    expect(matchesSearch(r, 'truck')).toBe(false)
    expect(matchesSearch(r, '  ')).toBe(true)
  })
})

describe('M2 errors', () => {
  it('maps status and reason to a message id', () => {
    const e = (status: number, details: Record<string, unknown> = {}) => ({ status, details })
    expect(errorMessageId(e(403))).toBe('assets.error.forbidden')
    expect(errorMessageId(e(404))).toBe('assets.error.notFound')
    expect(errorMessageId(e(409, { reason: 'idempotency_key_reuse' }))).toBe('assets.error.idempotency_key_reuse')
    expect(errorMessageId(e(422, { reason: 'card_inactive' }))).toBe('assets.error.card_inactive')
    expect(errorMessageId(e(422, { reason: 'brand_new' }))).toBe('assets.error.unknown')
    expect(errorMessageId(e(500))).toBe('assets.error.generic')
    expect(errorMessageId(null)).toBe('assets.error.generic')
  })

  it('marks fields from field/fields and from the reasons that name one', () => {
    const e = (details: Record<string, unknown>) => ({ status: 422, details })
    expect(fieldMarked(e({ reason: 'record_payload_invalid', fields: ['inventory_number'] }), 'inventory_number')).toBe(true)
    expect(fieldMarked(e({ reason: 'field_invalid', field: 'name' }), 'inventory_number')).toBe(false)
    expect(fieldMarked(e({ reason: 'org_unit_not_active' }), 'org_unit_id')).toBe(true)
    expect(fieldMarked(e({ reason: 'valid_until_not_allowed' }), 'valid_until')).toBe(true)
    expect(fieldMarked(e({ reason: 'currency_mismatch' }), 'currency')).toBe(true)
    expect(reasonOf(e({ reason: 'x', fields: ['a', 1] })).fields).toEqual(['a'])
  })
})
