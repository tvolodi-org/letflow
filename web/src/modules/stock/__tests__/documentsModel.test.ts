/** M1 — GH 3769 / REQ-722: pure logic of the stock document screens. */
import { describe, expect, it } from 'vitest'
import {
  DOC_EXTRA_REASONS, DOC_REASONS, DOC_SIDE_REASONS, actionsFor, buildBody, documentErrorMessageId, emptyForm, formFromDocument,
  isDecimalAboveZero, isDecimalNonNegative, isoToZonedLocal, placeError, sidesOf, validateForm, zonedLocalToIso,
  type FormState,
} from '../documents/documentsModel'
import type { StockDocument } from '../documents/documents.api'
import { stockDoc } from './stockTestKit'

describe('time zone', () => {
  it('writes the Asia/Almaty offset and round-trips', () => {
    expect(zonedLocalToIso('2026-11-04T10:00')).toBe('2026-11-04T10:00:00+05:00')
    expect(isoToZonedLocal('2026-11-04T05:00:00Z')).toBe('2026-11-04T10:00')
    expect(isoToZonedLocal(zonedLocalToIso('2026-01-15T23:30'))).toBe('2026-01-15T23:30')
    expect(zonedLocalToIso('garbage')).toBeNull()
    expect(isoToZonedLocal(null)).toBe('')
  })
  it('handles another zone with a negative offset', () => {
    expect(zonedLocalToIso('2026-01-15T10:00', 'America/New_York')).toBe('2026-01-15T10:00:00-05:00')
  })
})

describe('decimals', () => {
  it.each(['1', '0.000000001', '12.5', '999999999999999'])('%s is above zero', (v) => expect(isDecimalAboveZero(v)).toBe(true))
  it.each(['0', '0.0', '-1', '1e3', '.5', ' 1', '01', '1.0000000001', 'abc', ''])('%s is not above zero', (v) =>
    expect(isDecimalAboveZero(v)).toBe(false),
  )
  it('zero is a valid price', () => {
    expect(isDecimalNonNegative('0')).toBe(true)
    expect(isDecimalNonNegative('-0')).toBe(false)
  })
})

describe('actionsFor', () => {
  const all = () => true
  const none = () => false
  it('follows the state table', () => {
    expect(actionsFor('draft', all)).toMatchObject({ edit: true, discard: true, issue: true, retry: false, cancel: false, reverse: false })
    expect(actionsFor('issued', all)).toMatchObject({ edit: false, retry: true, cancel: true, waiting: true })
    expect(actionsFor('posted', all)).toMatchObject({ reverse: true, cancel: false, retry: false })
    expect(actionsFor('reversed', all)).toMatchObject({ cancel: true, reverse: false })
    expect(actionsFor('cancelled', all)).toMatchObject({ edit: false, cancel: false, reverse: false, retry: false })
  })
  it('hides everything without the atoms and no edit for other kinds', () => {
    for (const s of ['draft', 'issued', 'posted', 'reversed']) {
      const a = actionsFor(s, none)
      expect([a.edit, a.discard, a.issue, a.retry, a.cancel, a.reverse]).toEqual([false, false, false, false, false, false])
    }
    expect(actionsFor('draft', all, 'transfer').edit).toBe(true)
    expect(actionsFor('draft', all, 'unknown_kind').edit).toBe(false)
  })
})

describe('two sides (REQ-723)', () => {
  const sideDoc = (kind: string) =>
    ({
      ...stockDoc({ kind, org_unit_id: 'A', from_org_unit_id: 'F', to_org_unit_id: 'T' }),
      from_location_id: 'fl', from_responsible_id: 'fr', to_location_id: 'tl', to_responsible_id: 'tr',
    }) as unknown as StockDocument
  it('sidesOf and the round trip per kind', () => {
    expect(sidesOf(sideDoc('transfer'))).toEqual({
      from: { orgUnitId: 'A', locationId: 'fl', responsibleId: 'fr' }, to: { orgUnitId: 'T', locationId: 'tl', responsibleId: 'tr' },
    })
    expect(sidesOf(sideDoc('return'))).toEqual({
      from: { orgUnitId: 'F', locationId: 'fl', responsibleId: 'fr' }, to: { orgUnitId: 'A', locationId: 'tl', responsibleId: 'tr' },
    })
    for (const kind of ['transfer', 'hand_over', 'return']) {
      const body = buildBody(formFromDocument(sideDoc(kind)))
      expect(body).toMatchObject({ kind, from_location_id: 'fl', from_responsible_id: 'fr', to_location_id: 'tl', to_responsible_id: 'tr' })
      expect(body).not.toHaveProperty('location_id')
      expect(body).not.toHaveProperty('reason_text')
    }
    expect(buildBody(formFromDocument(sideDoc('return')))).toMatchObject({ from_org_unit_id: 'F', org_unit_id: 'A' })
    expect(buildBody(formFromDocument(sideDoc('hand_over')))).toMatchObject({ org_unit_id: 'A', to_org_unit_id: 'T' })
  })
  it('places side refusals', () => {
    expect(placeError({ status: 422, details: { reason: 'not_linked', side: 'to' } }).key).toBe('side.to')
    expect(placeError({ status: 422, details: { reason: 'employee_not_active', side: 'from' } }).key).toBe('side.from')
    expect(placeError({ status: 422, details: { reason: 'not_linked' } }).key).toBeNull()
    expect(placeError({ status: 422, details: { reason: 'not_linked', side: 'x' } }).key).toBeNull()
    expect(placeError({ status: 422, details: { reason: 'sides_equal' } }).key).toBe('sides')
    expect(placeError({ status: 422, details: { reason: 'field_required', field: 'to_location_id' } }).key).toBe('side.to.locationId')
  })
})

describe('errors', () => {
  it('maps status and reason to a message id', () => {
    expect(documentErrorMessageId({ status: 403 })).toBe('stock.doc.error.forbidden')
    expect(documentErrorMessageId({ status: 404 })).toBe('stock.doc.error.notFound')
    for (const r of [...DOC_REASONS, ...DOC_EXTRA_REASONS, ...DOC_SIDE_REASONS]) {
      expect(documentErrorMessageId({ status: 422, details: { reason: r } })).toBe(`stock.doc.error.${r}`)
    }
    expect(documentErrorMessageId({ status: 422, details: { reason: 'brand_new' } })).toBe('stock.doc.error.unknown')
    expect(documentErrorMessageId(new Error('x'))).toBe('stock.doc.error.generic')
  })
  it('places a refusal on its field or line', () => {
    expect(placeError({ status: 422, details: { reason: 'field_required', field: 'location_id' } }).key).toBe('header.locationId')
    expect(placeError({ status: 422, details: { reason: 'quantity_invalid', line_no: 3, field: 'quantity' } }).key).toBe('lines.2.quantity')
    expect(placeError({ status: 422, details: { reason: 'lot_required', line_no: 1 } }).key).toBe('lines.0')
    expect(placeError({ status: 409, details: { reason: 'document_not_draft' } }).key).toBeNull()
  })
})

function filled(kind: FormState['kind']): FormState {
  return {
    ...emptyForm(kind, '2026-11-04T10:00'),
    orgUnitId: 'u1', locationId: 'l1', responsibleId: 'e1',
    lines: [{ itemId: 'i1', uomId: 'm1', lotId: '', quantity: '3', unitPrice: '', lineValue: '' }],
  }
}

describe('buildBody and validateForm', () => {
  it('builds each kind with exactly its keys', () => {
    expect(buildBody(filled('issue'))).toEqual({
      kind: 'issue', event_time: '2026-11-04T10:00:00+05:00', org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1',
      lines: [{ catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3' }],
    })
    const r = { ...filled('receipt'), counterpartyId: 'c1', supplierRef: 'INV-1', receivedOn: '2026-11-03' }
    r.lines = [{ itemId: 'i1', uomId: 'm1', lotId: 't1', quantity: '3', unitPrice: '2.5', lineValue: '7.5' }]
    expect(Object.keys(buildBody(r)).sort()).toEqual(
      ['counterparty_id', 'event_time', 'kind', 'lines', 'location_id', 'org_unit_id', 'received_on', 'responsible_id', 'supplier_document_ref'],
    )
    const w = { ...filled('write_off'), reasonCode: 'lost' }
    expect(buildBody(w)).toMatchObject({ kind: 'write_off', reason_code: 'lost' })
    expect(buildBody(w)).not.toHaveProperty('reason_text')
  })
  it('requires reason text for other and a valid quantity', () => {
    expect(validateForm({ ...filled('write_off'), reasonCode: 'other' }).errors['header.reasonText']).toBeDefined()
    expect(validateForm({ ...filled('write_off'), reasonCode: 'other', reasonText: 'fire' }).errors).toEqual({})
    const bad = filled('issue')
    bad.lines[0].quantity = '0'
    expect(validateForm(bad).errors['lines.0.quantity']).toBe('stock.doc.error.quantity_invalid')
    expect(validateForm({ ...filled('issue'), lines: [] }).errors['lines']).toBe('stock.doc.error.lines_count')
  })
  it('an edit form keeps lots, prices and values and sends no server-set key', () => {
    const doc = stockDoc() as unknown as StockDocument
    const body = buildBody(formFromDocument(doc))
    expect(body['lines']).toEqual([
      { catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '3.000000000' },
      { catalog_item_id: 'i2', catalog_uom_id: 'm1', catalog_lot_id: 't2', quantity: '5.000000000', unit_price: '2', line_value: '10' },
    ])
    expect(JSON.stringify(body)).not.toMatch(/line_id|line_no|header_id|"number"|"state"/)
  })
})
