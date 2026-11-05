/** O2/O3 — GH T-1316 / REQ-725: the opening balance kind in the pure model. */
import { describe, expect, it } from 'vitest'
import type { StockDocument } from '../documents/documents.api'
import {
  buildBody, documentErrorMessageId, emptyForm, formFromDocument, headerFields, placeError, validateForm, type FormState,
} from '../documents/documentsModel'
import { CAUSES, DOCUMENT_TYPES } from '../register/stockRegisterModel'

const valid = (): FormState => {
  const f = emptyForm('opening')
  f.orgUnitId = 'u1'
  f.lines = [{ ...f.lines[0], itemId: 'i1', uomId: 'm1', quantity: '3', locationId: 'l1', responsibleId: 'e1', receivedOn: '2026-09-15' }]
  return f
}

describe('opening model', () => {
  it('O1 body has no event time and no header location, only the line keys of the kind', () => {
    const f = valid()
    f.note = 'start'
    f.lines[0].unitPrice = '2.5'
    expect(buildBody(f)).toEqual({
      kind: 'opening', org_unit_id: 'u1', note: 'start',
      lines: [{
        catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', location_id: 'l1', responsible_id: 'e1',
        received_on: '2026-09-15', unit_price: '2.5',
      }],
    })
    expect(headerFields('opening')).toEqual(['orgUnitId', 'note', 'externalRefSystem', 'externalRefId'])
    expect(validateForm(f).errors).toEqual({})
  })
  it('O2 refuses a missing or future receipt date, a missing place and a zero quantity', () => {
    const f = valid()
    f.lines[0] = { ...f.lines[0], receivedOn: '', locationId: '', responsibleId: '', quantity: '0' }
    expect(validateForm(f).errors).toEqual({
      'lines.0.quantity': 'stock.doc.error.quantity_invalid',
      'lines.0.locationId': 'stock.doc.error.field_required',
      'lines.0.responsibleId': 'stock.doc.error.field_required',
      'lines.0.receivedOn': 'stock.doc.error.field_required',
    })
    f.lines[0] = { ...valid().lines[0], receivedOn: '2999-01-01' }
    expect(validateForm(f).errors).toEqual({ 'lines.0.receivedOn': 'stock.doc.error.received_on_in_future' })
  })
  it('O3 a loaded document round-trips to the same body', () => {
    const doc = {
      id: 'd', kind: 'opening', state: 'draft', number: null, org_unit_id: 'u1', location_id: null, responsible_id: null,
      event_time: null, note: null,
      lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15', line_value: '9' }],
    } as StockDocument
    expect(buildBody(formFromDocument(doc))).toEqual({
      kind: 'opening', org_unit_id: 'u1',
      lines: [{ catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15', line_value: '9' }],
    })
  })
  it('W4 header pair goes in the body when both given, is left out when empty, and is both-or-neither', () => {
    const f = valid()
    expect(buildBody(f)).not.toHaveProperty('external_ref_id')
    f.externalRefSystem = 'erp'
    expect(validateForm(f).errors).toEqual({ 'header.externalRefId': 'stock.doc.error.external_ref_pair' })
    f.externalRefId = 'OB-7'
    expect(validateForm(f).errors).toEqual({})
    expect(buildBody(f)).toMatchObject({ external_ref_system: 'erp', external_ref_id: 'OB-7' })
    f.externalRefId = 'x'.repeat(129)
    expect(validateForm(f).errors['header.externalRefId']).toBe('stock.doc.error.textTooLong')
  })
  it('W5 a loaded document sends back its header pair and the pair of each imported line', () => {
    const line = { catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15' }
    const doc = {
      id: 'd', kind: 'opening', state: 'draft', number: null, org_unit_id: 'u1', location_id: null, responsible_id: null,
      event_time: null, note: null, external_ref_system: 'erp', external_ref_id: 'OB-7',
      lines: [
        { line_no: 1, ...line, external_ref_system: 'erp', external_ref_id: 'L1' },
        { line_no: 2, ...line },
        { line_no: 3, ...line, external_ref_system: 'erp', external_ref_id: 'L3' },
      ],
    } as StockDocument
    const form = formFromDocument(doc)
    form.lines.splice(1, 1) // removing a middle row: the pair travels with its row
    const body = buildBody(form) as { lines: Record<string, unknown>[] }
    expect(body).toMatchObject({ external_ref_system: 'erp', external_ref_id: 'OB-7' })
    expect(body.lines.map((l) => l['external_ref_id'])).toEqual(['L1', 'L3'])
    expect(buildBody(formFromDocument(doc)).lines).toHaveLength(3)
    expect((buildBody(formFromDocument(doc)) as { lines: Record<string, unknown>[] }).lines[1]).not.toHaveProperty('external_ref_id')
  })
  it('O4 server refusals land on the line field and have their own message', () => {
    const err = { status: 422, details: { reason: 'received_on_in_future', line_no: 2, field: 'received_on' } }
    expect(placeError(err)).toEqual({ key: 'lines.1.receivedOn', messageId: 'stock.doc.error.received_on_in_future' })
  })
  it('O5 a 403 (second administrator rule) keeps the forbidden message', () => {
    expect(documentErrorMessageId({ status: 403, details: {} })).toBe('stock.doc.error.forbidden')
  })
  it('O6 the opening words are in the Movements filter lists', () => {
    expect(CAUSES).toContain('opening')
    expect(DOCUMENT_TYPES).toContain('stock_opening')
  })
})
