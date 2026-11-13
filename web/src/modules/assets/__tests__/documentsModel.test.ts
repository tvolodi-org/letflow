/** M1 — T-1334 / C14: the pure model of the asset document screens. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import {
  DOC_KINDS, DOC_REASONS, HEADER_KEYS, REVERSE_REASONS, actionsFor, documentErrorInfo, documentErrorMessageId, reasonTextError, sidesOf,
} from '../documents/documentsModel'
import type { AssetDocument } from '../documents/assetDocuments.api'
import { assetsMessages } from '../assetsMessages'
import { OPENING_CHECK_REASONS, openingReasonMessageId } from '../documents/openingForm'

const can = (...atoms: string[]) => (a: string) => atoms.includes(a)

describe('M1 actionsFor', () => {
  it('draft: edit, discard and issue need AssetsPost; posted: reverse needs AssetsReverse; no other state has an action', () => {
    expect(actionsFor('draft', can('AssetsPost'))).toEqual({ edit: true, discard: true, issue: true, reverse: false })
    expect(actionsFor('draft', can('AssetsRead', 'AssetsReverse'))).toEqual({ edit: false, discard: false, issue: false, reverse: false })
    expect(actionsFor('posted', can('AssetsReverse'))).toEqual({ edit: false, discard: false, issue: false, reverse: true })
    expect(actionsFor('posted', can('AssetsPost'))).toEqual({ edit: false, discard: false, issue: false, reverse: false })
    for (const s of ['issued', 'reversed', 'cancelled']) expect(actionsFor(s, can('AssetsPost', 'AssetsReverse'))).toEqual({ edit: false, discard: false, issue: false, reverse: false })
  })
})

describe('M1 reasons and errors', () => {
  it('reverse reasons are the four of Posting.@reasons, and the list is pinned to the backend source', () => {
    const src = readFileSync(path.resolve(__dirname, '../../../../../lib/letflow/modules/assets/documents/posting.ex'), 'utf-8')
    const m = /@reasons ~w\(([^)]*)\)/.exec(src)
    expect(m?.[1].split(/\s+/)).toEqual([...REVERSE_REASONS])
  })
  it('reasonTextError: other needs a text, at most 500 characters', () => {
    expect(reasonTextError('other', '  ')).toBe('assets.doc.error.reasonTextRequired')
    expect(reasonTextError('wrong_document', '')).toBeNull()
    expect(reasonTextError('wrong_document', 'x'.repeat(501))).toBe('assets.doc.error.textTooLong')
    expect(reasonTextError('other', 'x'.repeat(500))).toBeNull()
  })
  it('maps statuses and reasons to message ids; every id of the closed list has a text in every language', () => {
    expect(documentErrorMessageId({ status: 403 })).toBe('assets.doc.error.forbidden')
    expect(documentErrorMessageId({ status: 404 })).toBe('assets.doc.error.notFound')
    expect(documentErrorMessageId({ status: 409, details: { reason: 'document_not_draft' } })).toBe('assets.doc.error.document_not_draft')
    expect(documentErrorMessageId({ status: 409, details: { reason: 'made_up' } })).toBe('assets.doc.error.unknown')
    expect(documentErrorMessageId({ status: 500 })).toBe('assets.doc.error.generic')
    expect(documentErrorMessageId(null)).toBe('assets.doc.error.generic')
    for (const l of ['en', 'ru', 'kk'] as const) for (const r of DOC_REASONS) expect(assetsMessages[l][`assets.doc.error.${r}`], `${l} ${r}`).toBeTruthy()
  })
})

const WEB_PENDING_KINDS: readonly string[] = []

describe('M1 sidesOf', () => {
  const base = { id: 'd', state: 'draft', number: null, event_time: null, lines: [] }
  it('change: one unit and location, two people each; handover: two units and locations; commission: one side', () => {
    const change = sidesOf({ ...base, kind: 'change', org_unit_id: 'u', location_id: 'l', from_material_responsible_id: 'f', from_actual_user_id: 'fu', to_material_responsible_id: 't', to_actual_user_id: 'tu' } as AssetDocument)
    expect(change.from).toEqual({ orgUnitId: 'u', locationId: 'l', responsibleId: 'f', userId: 'fu' })
    expect(change.to).toEqual({ orgUnitId: 'u', locationId: 'l', responsibleId: 't', userId: 'tu' })
    const hand = sidesOf({ ...base, kind: 'handover', org_unit_id: 'u', from_location_id: 'fl', from_material_responsible_id: 'f', to_org_unit_id: 'u2', to_location_id: 'tl', to_material_responsible_id: 't' } as AssetDocument)
    expect(hand.from).toMatchObject({ orgUnitId: 'u', locationId: 'fl', responsibleId: 'f' })
    expect(hand.to).toMatchObject({ orgUnitId: 'u2', locationId: 'tl', responsibleId: 't' })
    const com = sidesOf({ ...base, kind: 'commission', org_unit_id: 'u', location_id: 'l', material_responsible_id: 'r', actual_user_id: 'x' } as AssetDocument)
    expect(com.from).toEqual(com.to)
  })
  it('the header keys of every kind equal Kinds.header_keys', () => {
    const src = readFileSync(path.resolve(__dirname, '../../../../../lib/letflow/modules/assets/documents/kinds.ex'), 'utf-8')
    const blocks = [...src.matchAll(/kind: "(\w+)"[\s\S]*?header_keys:\s*~w\(([^)]*)\)/g)].filter(
      // Server kinds with no web form yet (none since T-1877 added the opening).
      (b) => !WEB_PENDING_KINDS.includes(b[1]),
    )
    expect(blocks.map((b) => b[1])).toEqual([...DOC_KINDS])
    for (const b of blocks) expect(b[2].trim().split(/\s+/)).toEqual([...HEADER_KEYS[b[1] as keyof typeof HEADER_KEYS]])
  })
})

describe('K1/K9b change of kind', () => {
  const root = path.resolve(__dirname, '../../../../../lib/letflow/modules')
  it('K9b: every reason atom of the issue checks is in DOC_REASONS (none falls to "unknown")', () => {
    const checks = readFileSync(path.resolve(root, 'assets/documents/kind_change_checks.ex'), 'utf-8')
    const stock = readFileSync(path.resolve(root, 'stock/documents/checks.ex'), 'utf-8')
    // check(<cond>, "reason", extras) and the tracking reasons returned by `tracking_reason/1`
    const issue = [...checks.matchAll(/"([a-z_]+)",\s*(?:Map\.put\(\s*)?extras/g)].map((m) => m[1]).filter((r) => !r.endsWith('_id') && r !== 'stock' && r !== 'asset') // field and side names passed to helpers
    const tracking = [...stock.matchAll(/def tracking_reason\([^)]*\)[^\n]*?, do: "([a-z_]+)"/g)].map((m) => m[1])
    expect(issue.length).toBeGreaterThanOrEqual(9)
    expect(tracking).toEqual(expect.arrayContaining(['lot_required', 'lot_not_allowed', 'lot_expiry_missing', 'tracking_invalid']))
    for (const r of [...issue, ...tracking]) expect(DOC_REASONS as readonly string[], r).toContain(r)
  })
  it('K8: Reverse is closed for a change of kind (the server refuses it), kept for the other kinds', () => {
    const can = (...a: string[]) => (atom: string) => a.includes(atom)
    expect(actionsFor('posted', can('AssetsReverse'), 'kind_change').reverse).toBe(false)
    for (const k of ['commission', 'change', 'handover', 'writeoff']) expect(actionsFor('posted', can('AssetsReverse'), k).reverse).toBe(true)
    expect(actionsFor('draft', can('AssetsPost'), 'kind_change')).toEqual({ edit: true, discard: true, issue: true, reverse: false })
  })
  it('a not_linked refusal carries its side', () => {
    expect(documentErrorInfo({ status: 422, details: { reason: 'not_linked', side: 'asset', line_no: 2 } })).toMatchObject({ side: 'asset', lineNo: 2 })
  })
})

describe('O-R1 opening reasons', () => {
  const root = path.resolve(__dirname, '../../../../../lib/letflow/modules/assets/documents')
  it('every reason of OpeningChecks (nine line reasons and the header one) is in OPENING_CHECK_REASONS with a text in en, ru and kk', () => {
    const src = readFileSync(path.resolve(root, 'opening_checks.ex'), 'utf-8')
    // only the `reasons =` list of line_result: employee_fields/2 has {"material_responsible_id", ...} tuples too
    const from = src.indexOf('reasons =')
    const slice = src.slice(from, src.indexOf('|> Enum.filter', from))
    const line = [...slice.matchAll(/\{"([a-z_]+)",/g)].map((m) => m[1])
    expect(line).toHaveLength(9)
    const all = [...line, 'org_unit_not_active']
    for (const r of all) expect(OPENING_CHECK_REASONS as readonly string[], r).toContain(r)
    const ids = [
      ...OPENING_CHECK_REASONS.filter((r) => r !== 'employee_not_active').map((r) => openingReasonMessageId(r)!),
      openingReasonMessageId('employee_not_active', 'material_responsible_id')!,
      openingReasonMessageId('employee_not_active', 'actual_user_id')!,
    ]
    for (const l of ['en', 'ru', 'kk'] as const) {
      for (const id of ids) expect(assetsMessages[l][id], `${l} ${id}`).toBeTruthy()
      for (const id of ['register_unreadable', 'external_ref_taken', 'external_ref_pair']) expect(assetsMessages[l][`assets.doc.error.${id}`], `${l} ${id}`).toBeTruthy()
    }
    for (const r of ['register_unreadable', 'external_ref_taken', 'external_ref_pair']) expect(DOC_REASONS as readonly string[]).toContain(r)
  })
})

describe('O-K2 opening sides and reverse', () => {
  it('sidesOf an opening has the org unit and no place or people; Reverse stays open for it', () => {
    const doc = { id: 'd', kind: 'opening', state: 'posted', number: 'AOP-1', event_time: null, org_unit_id: 'u', lines: [] } as AssetDocument
    expect(sidesOf(doc).from).toEqual({ orgUnitId: 'u', locationId: null, responsibleId: null, userId: null })
    expect(actionsFor('posted', can('AssetsReverse'), 'opening').reverse).toBe(true)
    expect(actionsFor('draft', can('AssetsPost'), 'opening')).toEqual({ edit: true, discard: true, issue: true, reverse: false })
  })
})
