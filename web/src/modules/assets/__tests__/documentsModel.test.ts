/** M1 — T-1334 / C14: the pure model of the asset document screens. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import {
  DOC_KINDS, DOC_REASONS, HEADER_KEYS, REVERSE_REASONS, actionsFor, documentErrorMessageId, reasonTextError, sidesOf,
} from '../documents/documentsModel'
import type { AssetDocument } from '../documents/assetDocuments.api'
import { assetsMessages } from '../assetsMessages'

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
    const blocks = [...src.matchAll(/kind: "(\w+)"[\s\S]*?header_keys:\s*~w\(([^)]*)\)/g)]
    expect(blocks.map((b) => b[1])).toEqual([...DOC_KINDS])
    for (const b of blocks) expect(b[2].trim().split(/\s+/)).toEqual([...HEADER_KEYS[b[1] as keyof typeof HEADER_KEYS]])
  })
})
