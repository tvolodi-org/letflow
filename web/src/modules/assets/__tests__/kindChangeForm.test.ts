/** K2–K4 — T-1336 / C16: the pure model of a change of kind line: checks, request body, round trip, refusal placement. */
import { describe, expect, it } from 'vitest'
import { buildBody, emptyForm, formFromDocument, placeError, validateForm } from '../documents/documentForm'
import type { AssetDocument } from '../documents/assetDocuments.api'
import {
  buildKindChangeLines, emptyKindChangeLine, kindChangeLinesFromDocument, kindChangeRefusalField, validateKindChangeLine,
  validateKindChangeLines, type KindChangeLine,
} from '../documents/kindChangeForm'

const full = (over: Partial<KindChangeLine> = {}): KindChangeLine => ({
  itemId: 'i1', uomId: 'm1', lotId: 'lot1', quantity: '3', stockLocationId: 'l1', stockResponsibleId: 'e1', targetKind: 'low_value',
  inventoryNumber: ' LV-1 ', assetName: ' Chair ', assetOrgUnitId: 'u2', assetLocationId: 'l2', materialResponsibleId: 'e2', actualUserId: 'e3', ...over,
})

describe('K2 checks', () => {
  it('an empty line misses every required value; lot, org unit and user are optional', () => {
    const e = validateKindChangeLine(emptyKindChangeLine())
    expect(Object.keys(e).sort()).toEqual(['assetLocationId', 'assetName', 'inventoryNumber', 'itemId', 'materialResponsibleId', 'stockLocationId', 'stockResponsibleId', 'uomId'].sort())
    expect(validateKindChangeLine(full())).toEqual({})
    expect(validateKindChangeLine(full({ lotId: '', assetOrgUnitId: '', actualUserId: '' }))).toEqual({})
  })
  it('a fixed asset is exactly one; a low value item is a whole number', () => {
    expect(validateKindChangeLine(full({ targetKind: 'fixed', quantity: '2' }))['quantity']).toBe('assets.doc.error.quantityOne')
    expect(validateKindChangeLine(full({ targetKind: 'fixed', quantity: '1.000' }))).toEqual({})
    expect(validateKindChangeLine(full({ quantity: '1.5' }))['quantity']).toBe('assets.doc.error.quantityWhole')
    expect(validateKindChangeLine(full({ quantity: '0' }))['quantity']).toBe('assets.doc.error.quantity_invalid')
    expect(validateKindChangeLine(full({ quantity: '' }))['quantity']).toBe('assets.doc.error.quantityRequired')
  })
  it('lengths and a repeated inventory number inside the document', () => {
    expect(validateKindChangeLine(full({ inventoryNumber: 'x'.repeat(65) }))['inventoryNumber']).toBe('assets.doc.error.field_invalid')
    expect(validateKindChangeLine(full({ assetName: 'x'.repeat(201) }))['assetName']).toBe('assets.doc.error.field_invalid')
    const e = validateKindChangeLines([full(), full({ inventoryNumber: 'LV-2' }), full({ inventoryNumber: 'LV-1' })])
    expect(e).toEqual({ 'lines.2.inventoryNumber': 'assets.doc.error.inventory_number_taken' })
  })
  it('the form needs the org unit and at least one line', () => {
    const f = emptyForm('kind_change', '2026-11-04T10:00')
    expect(validateForm(f).errors['side.from.orgUnitId']).toBe('assets.doc.error.field_required')
    expect(validateForm({ ...f, kcLines: [] }).errors['lines']).toBe('assets.doc.error.lines_count')
    expect(validateForm({ ...f, from: { ...f.from, orgUnitId: 'u1' }, kcLines: [full()] }).errors).toEqual({})
  })
})

describe('K3 body', () => {
  it('sends the 13 keys trimmed, leaves out empty optional ones and never sends asset_card_id', () => {
    const [a, b] = buildKindChangeLines([full(), full({ lotId: '', assetOrgUnitId: '', actualUserId: '', inventoryNumber: 'LV-2' })])
    expect(a).toEqual({
      catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 'lot1', quantity: '3', stock_location_id: 'l1', stock_responsible_id: 'e1',
      target_kind: 'low_value', asset_org_unit_id: 'u2', asset_location_id: 'l2', material_responsible_id: 'e2', actual_user_id: 'e3',
      inventory_number: 'LV-1', asset_name: 'Chair',
    })
    expect(Object.keys(b)).not.toContain('catalog_lot_id')
    expect(Object.keys(b)).not.toContain('asset_org_unit_id')
    expect(Object.keys(b)).not.toContain('actual_user_id')
    expect(JSON.stringify([a, b])).not.toContain('asset_card_id')
  })
  it('POST body: header keys of the kind and its lines; PUT body drops the kind', () => {
    const f = { ...emptyForm('kind_change', '2026-11-04T10:00'), reasonText: ' stock to cards ', note: 'n', kcLines: [full()] }
    f.from.orgUnitId = 'u1'
    const post = buildBody(f)
    expect(Object.keys(post).sort()).toEqual(['event_time', 'kind', 'lines', 'note', 'org_unit_id', 'reason_text'])
    expect(post['kind']).toBe('kind_change')
    expect(post['event_time']).toBe('2026-11-04T10:00:00+05:00')
    expect(buildBody(f, false)['kind']).toBeUndefined()
    expect(buildBody({ ...f, reasonText: '', note: '' }, false)).not.toHaveProperty('reason_text')
  })
  it('a loaded draft round-trips: every line value is sent back, the card id is not', () => {
    const doc: AssetDocument = {
      id: 'd', kind: 'kind_change', state: 'draft', number: null, event_time: '2026-11-04T05:00:00Z', org_unit_id: 'u1', reason_text: 'r', note: null,
      lines: [
        { line_no: 2, asset_id: '', quantity: '1.000000000', catalog_item_id: 'i2', catalog_uom_id: 'm1', catalog_lot_id: null, stock_location_id: 'l1', stock_responsible_id: 'e1', target_kind: 'fixed', asset_org_unit_id: null, asset_location_id: 'l2', material_responsible_id: 'e2', actual_user_id: null, inventory_number: 'FA-9', asset_name: 'Van', asset_card_id: 'c9' },
        { line_no: 1, asset_id: '', quantity: '5.000000000', catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 'lot1', stock_location_id: 'l1', stock_responsible_id: 'e1', target_kind: 'low_value', asset_org_unit_id: 'u2', asset_location_id: 'l2', material_responsible_id: 'e2', actual_user_id: 'e3', inventory_number: 'LV-1', asset_name: 'Chair' },
      ],
    }
    const lines = kindChangeLinesFromDocument(doc.lines)
    expect(lines.map((l) => l.inventoryNumber)).toEqual(['LV-1', 'FA-9'])
    expect(lines[0]).toMatchObject({ quantity: '5', lotId: 'lot1', assetOrgUnitId: 'u2', actualUserId: 'e3' })
    const f = formFromDocument(doc)
    expect(f.kind).toBe('kind_change')
    expect(f.from.orgUnitId).toBe('u1')
    const body = buildBody(f, false)
    expect(body['reason_text']).toBe('r')
    expect(body['lines']).toEqual(buildKindChangeLines(lines))
    expect(JSON.stringify(body)).not.toContain('asset_card_id')
    expect(validateForm(f).errors).toEqual({})
  })
})

describe('T-1865 a location refusal of a line lands on the header location', () => {
  const err = (details: Record<string, unknown>) => ({ status: 422, details })
  it('location_id / to_location_id with a line number name the header field, not the asset', () => {
    expect(placeError(err({ reason: 'location_required', line_no: 2, field: 'location_id' }), 'commission').key).toBe('side.from.locationId')
    expect(placeError(err({ reason: 'location_required', line_no: 1, field: 'to_location_id', side: 'to' }), 'handover').key).toBe('side.to.locationId')
  })
})

describe('K4 where a refusal is shown', () => {
  const err = (details: Record<string, unknown>) => ({ status: 422, details })
  it('a named field lands on that cell of the line', () => {
    expect(placeError(err({ reason: 'location_not_active', line_no: 2, field: 'asset_location_id' }), 'kind_change').key).toBe('lines.1.assetLocationId')
    expect(placeError(err({ reason: 'employee_not_active', line_no: 1, field: 'actual_user_id' }), 'kind_change').key).toBe('lines.0.actualUserId')
    expect(placeError(err({ reason: 'org_unit_not_active', line_no: 1, field: 'asset_org_unit_id' }), 'kind_change').key).toBe('lines.0.assetOrgUnitId')
  })
  it('not_linked names the side: stock -> stock location, asset -> asset location, with its own message', () => {
    expect(placeError(err({ reason: 'not_linked', line_no: 3, side: 'stock' }), 'kind_change')).toEqual({ key: 'lines.2.stockLocationId', messageId: 'assets.doc.error.not_linked_stock' })
    expect(placeError(err({ reason: 'not_linked', line_no: 3, side: 'asset' }), 'kind_change')).toEqual({ key: 'lines.2.assetLocationId', messageId: 'assets.doc.error.not_linked_asset' })
  })
  it('reasons without a field land on their cell; inventory_number_taken on the number', () => {
    expect(placeError(err({ reason: 'inventory_number_taken', line_no: 2 }), 'kind_change').key).toBe('lines.1.inventoryNumber')
    expect(placeError(err({ reason: 'lot_required', line_no: 1 }), 'kind_change').key).toBe('lines.0.lotId')
    expect(placeError(err({ reason: 'item_not_active', line_no: 1 }), 'kind_change').key).toBe('lines.0.itemId')
    expect(kindChangeRefusalField('something_else', undefined, undefined)).toBeUndefined()
    expect(placeError(err({ reason: 'something_else', line_no: 4 }), 'kind_change').key).toBe('lines.3')
  })
  it('the header unit refusal (no line) lands on the org unit; the other kinds are unchanged', () => {
    expect(placeError(err({ reason: 'org_unit_not_active' }), 'kind_change').key).toBe('side.from.orgUnitId')
    expect(placeError(err({ reason: 'quantity_invalid', line_no: 1 }), 'commission').key).toBe('lines.0.quantity')
  })
})
