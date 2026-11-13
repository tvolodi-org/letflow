/** O-F2, O-M1..M5, O-P1, O-IMP4 — T-1877: the pure model of the asset opening document (lines, checks, body, refusals,
 *  check messages, import helpers). */
import { describe, expect, it } from 'vitest'
import { buildBody, emptyForm, formFromDocument, placeError, validateForm, type FormState } from '../documents/documentForm'
import {
  buildOpeningLines, checkMessages, emptyOpeningLine, openingLinesFromDocument, sameOpeningLines, validateExternalRef,
  validateOpeningLine, validateOpeningLines, type OpeningLine,
} from '../documents/openingForm'
import { summariseImport } from '../documents/openingImport'
import type { AssetDocument } from '../documents/assetDocuments.api'

const kinds: Record<string, string> = { fx: 'fixed', lv: 'low_value', ia: 'intangible' }
const cardOf = (id: string) => (kinds[id] ? { kind: kinds[id] } : undefined)
const line = (o: Partial<OpeningLine> = {}): OpeningLine => ({ ...emptyOpeningLine(), assetId: 'fx', locationId: 'l1', responsibleId: 'e1', ...o })
const fmt = (id: string, v?: Record<string, string | number>) => `${id}${v ? JSON.stringify(v) : ''}`

describe('O-F2 body', () => {
  const f: FormState = { ...emptyForm('opening', ''), from: { orgUnitId: 'u1', locationId: '', responsibleId: '', userId: '' }, opLines: [line()] }
  it('never carries event_time, a header place or people; the external pair only when both are filled', () => {
    expect(buildBody(f)).toEqual({ kind: 'opening', org_unit_id: 'u1', lines: [{ asset_id: 'fx', material_responsible_id: 'e1', quantity: '1', location_id: 'l1' }] })
    expect(buildBody({ ...f, externalRefSystem: ' erp ', externalRefId: 'OP-1', note: 'n' }, false)).toEqual({
      org_unit_id: 'u1', note: 'n', external_ref_system: 'erp', external_ref_id: 'OP-1',
      lines: [{ asset_id: 'fx', material_responsible_id: 'e1', quantity: '1', location_id: 'l1' }],
    })
    expect(buildBody({ ...f, externalRefSystem: 'erp' })).not.toHaveProperty('external_ref_system')
  })
  it('an empty event time is not an error for an opening', () => {
    expect(validateForm(f, cardOf).errors).toEqual({})
  })
  it('O-F3 a loaded draft keeps header and line external pairs, and every line value goes back', () => {
    const doc = {
      id: 'd', kind: 'opening', state: 'draft', number: null, event_time: null, org_unit_id: 'u1', external_ref_system: 'erp', external_ref_id: 'OP-1',
      lines: [
        { line_no: 2, asset_id: 'lv', quantity: '3.000000000', material_responsible_id: 'e2', actual_user_id: 'e3', location_id: 'l2', external_ref_system: 'erp', external_ref_id: 'r2' },
        { line_no: 1, asset_id: 'ia', quantity: '1.000000000', material_responsible_id: 'e1', external_ref_system: 'erp', external_ref_id: 'r1' },
      ],
    } as unknown as AssetDocument
    const form = formFromDocument(doc)
    expect(form.externalRefSystem).toBe('erp')
    expect(form.opLines.map((l) => l.assetId)).toEqual(['ia', 'lv'])
    expect(buildBody(form, false)['lines']).toEqual([
      { asset_id: 'ia', material_responsible_id: 'e1', quantity: '1', external_ref_system: 'erp', external_ref_id: 'r1' },
      { asset_id: 'lv', material_responsible_id: 'e2', quantity: '3', location_id: 'l2', actual_user_id: 'e3', external_ref_system: 'erp', external_ref_id: 'r2' },
    ])
    expect(buildOpeningLines(openingLinesFromDocument(doc.lines))).toHaveLength(2)
  })
})

describe('O-M client checks mirror the server', () => {
  it('M1 asset and responsible are required', () => {
    expect(validateOpeningLine(line({ assetId: '', responsibleId: '' }))).toMatchObject({
      assetId: 'assets.doc.error.assetRequired', responsibleId: 'assets.doc.error.field_required',
    })
  })
  it('M2 quantity: 2 on a fixed asset, 1.5 on a low value one', () => {
    expect(validateOpeningLine(line({ quantity: '2' }), cardOf)['quantity']).toBe('assets.doc.error.quantityOne')
    expect(validateOpeningLine(line({ assetId: 'lv', quantity: '1.5' }), cardOf)['quantity']).toBe('assets.doc.error.quantityWhole')
    expect(validateOpeningLine(line({ assetId: 'lv', quantity: '4' }), cardOf)).toEqual({})
    expect(validateOpeningLine(line({ quantity: '' }), cardOf)['quantity']).toBe('assets.doc.error.quantityRequired')
  })
  it('M3 intangible with a location, fixed without one', () => {
    expect(validateOpeningLine(line({ assetId: 'ia' }), cardOf)['locationId']).toBe('assets.doc.opening.reason.location_not_allowed')
    expect(validateOpeningLine(line({ assetId: 'ia', locationId: '' }), cardOf)).toEqual({})
    expect(validateOpeningLine(line({ locationId: '' }), cardOf)['locationId']).toBe('assets.doc.opening.reason.location_required')
    // an unknown card (not on the loaded page): the server decides
    expect(validateOpeningLine(line({ assetId: 'zz', locationId: '' }), cardOf)).toEqual({})
  })
  it('M4 a fixed asset twice is a duplicate; a low value one only with the same placement', () => {
    expect(validateOpeningLines([line(), line()], cardOf)['lines.1.assetId']).toBe('assets.doc.opening.reason.duplicate_asset')
    const lv = (userId: string) => line({ assetId: 'lv', userId })
    expect(validateOpeningLines([lv('e2'), lv('e2')], cardOf)['lines.1.assetId']).toBe('assets.doc.opening.reason.duplicate_asset')
    expect(validateOpeningLines([lv('e2'), lv('e3')], cardOf)).toEqual({})
  })
  it('M5 the external pair is both or neither', () => {
    expect(validateExternalRef('erp', '')).toEqual({ 'header.externalRefId': 'assets.doc.error.external_ref_pair' })
    expect(validateExternalRef('', 'x')).toEqual({ 'header.externalRefSystem': 'assets.doc.error.external_ref_pair' })
    expect(validateExternalRef('erp', 'x')).toEqual({})
    expect(validateExternalRef('e'.repeat(129), 'x')['header.externalRefSystem']).toBe('assets.doc.error.textTooLong')
  })
  it('an opening needs an org unit and 1..100 lines', () => {
    const f = { ...emptyForm('opening'), opLines: [] as OpeningLine[] }
    expect(validateForm(f, cardOf).errors).toMatchObject({ 'side.from.orgUnitId': 'assets.doc.error.field_required', lines: 'assets.doc.error.lines_count' })
  })
})

describe('O-P1 where a refusal is shown', () => {
  const err = (status: number, details: Record<string, unknown>) => ({ status, details })
  it('not_linked on a line is about the LOCATION and has the opening text, not the header', () => {
    expect(placeError(err(422, { reason: 'not_linked', line_no: 2, field: 'location_id' }), 'opening')).toEqual({
      key: 'lines.1.locationId', messageId: 'assets.doc.opening.reason.not_linked',
    })
    expect(placeError(err(422, { reason: 'not_linked', line_no: 2 }), 'opening').key).toBe('lines.1.locationId')
  })
  it('employee_not_active names the person by field; asset_already_in_register lands on the asset', () => {
    expect(placeError(err(422, { reason: 'employee_not_active', line_no: 1, field: 'actual_user_id' }), 'opening')).toEqual({
      key: 'lines.0.userId', messageId: 'assets.doc.opening.reason.employee_not_active.actual_user_id',
    })
    expect(placeError(err(422, { reason: 'asset_already_in_register', line_no: 3 }), 'opening').key).toBe('lines.2.assetId')
  })
  it('header refusals: org unit and a taken external pair', () => {
    expect(placeError(err(409, { reason: 'external_ref_taken' }), 'opening')).toEqual({ key: 'header.externalRefId', messageId: 'assets.doc.error.external_ref_taken' })
    expect(placeError(err(422, { reason: 'org_unit_not_active' }), 'opening').key).toBe('side.from.orgUnitId')
  })
})

describe('check messages', () => {
  it('lists header reasons first, then every line reason in order, one message per employee field', () => {
    const out = checkMessages({
      ok: false,
      header: ['org_unit_not_active'],
      lines: [
        { line_no: 1, reasons: ['asset_already_in_register', 'not_linked'], fields: [] },
        { line_no: 2, reasons: ['employee_not_active'], fields: ['material_responsible_id', 'actual_user_id'] },
      ],
    }, fmt)
    expect(out).toHaveLength(5)
    expect(out[0]).toContain('assets.doc.opening.check.header')
    expect(out[1]).toContain('"line":1')
    expect(out[1]).toContain('asset_already_in_register')
    expect(out[3]).toContain('employee_not_active.material_responsible_id')
    expect(out[4]).toContain('employee_not_active.actual_user_id')
    expect(checkMessages({ ok: true, header: [], lines: [{ line_no: 1, reasons: [], fields: [] }] }, fmt)).toEqual([])
  })
})

describe('O-IMP4 import helpers', () => {
  it('summariseImport counts ok rows as added, none when rolled back, and refused rows carry the row number and header', () => {
    const ok = { status: 'ok', line: 2 }
    const bad = { status: 'refused', line: 3, reason: { code: 'x', header: 'asset_id' } }
    const a = summariseImport('en', { applied: true, results: [ok, bad] } as never)
    expect(a.added).toBe(1)
    expect(a.refused).toHaveLength(1)
    expect(a.refused[0]!.row).toBe(3)
    expect(a.refused[0]!.reason).toContain('asset_id')
    expect(summariseImport('en', { applied: false, results: [ok] } as never).added).toBe(0)
  })
  it('sameOpeningLines compares field by field', () => {
    expect(sameOpeningLines([line()], [line()])).toBe(true)
    expect(sameOpeningLines([line()], [line({ quantity: '2' })])).toBe(false)
    expect(sameOpeningLines([line()], [])).toBe(false)
  })
})
