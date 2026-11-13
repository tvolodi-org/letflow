/** openingForm — T-1877. Pure model of the lines of an asset OPENING document (decision 0083): the assets that are
 *  already in use enter the register with no backdating, each line placed on its own (location, material responsible,
 *  actual user). Cost, accumulated depreciation and dates stay on the card (0083 D2), so they are not line fields.
 *  Checks mirror the server so the user is told early; the server stays the authority. A PUT replaces the whole line
 *  list, so every loaded value (also the external pair the import wrote) is sent back. */
import type { AssetDocumentLine, OpeningCheckResult } from './assetDocuments.api'
import { isDecimalAboveZero, trimZeros, type LineCard } from './documentForm'

export interface OpeningLine {
  assetId: string
  quantity: string
  locationId: string
  responsibleId: string
  userId: string
  extRefSystem: string
  extRefId: string
}

export const emptyOpeningLine = (): OpeningLine => ({
  assetId: '', quantity: '1', locationId: '', responsibleId: '', userId: '', extRefSystem: '', extRefId: '',
})

/** Header and line reasons of `OpeningChecks` (check route and the issue refusals). */
export const OPENING_CHECK_REASONS = [
  'org_unit_not_active', 'card_not_active', 'duplicate_asset', 'quantity_invalid', 'org_unit_mismatch',
  'location_required', 'location_not_allowed', 'not_linked', 'employee_not_active', 'asset_already_in_register',
] as const

const s = (v: string | null | undefined): string => v ?? ''
const REF_MAX = 128

/** The form lines of a loaded draft (every value, so a PUT does not clear any). */
export function openingLinesFromDocument(lines: readonly AssetDocumentLine[]): OpeningLine[] {
  return [...lines]
    .sort((a, b) => a.line_no - b.line_no)
    .map((l) => ({
      assetId: s(l.asset_id),
      quantity: trimZeros(s(l.quantity)),
      locationId: s(l.location_id),
      responsibleId: s(l.material_responsible_id),
      userId: s(l.actual_user_id),
      extRefSystem: s(l.external_ref_system),
      extRefId: s(l.external_ref_id),
    }))
}

/** Message ids of one line by field. An unknown card kind skips the kind-dependent checks (the server decides). */
export function validateOpeningLine(l: OpeningLine, cardOf: (id: string) => LineCard | undefined = () => undefined): Record<string, string> {
  const out: Record<string, string> = {}
  const required = 'assets.doc.error.field_required'
  if (l.assetId === '') out['assetId'] = 'assets.doc.error.assetRequired'
  if (l.responsibleId === '') out['responsibleId'] = required
  const kind = l.assetId === '' ? undefined : cardOf(l.assetId)?.kind
  const q = l.quantity.trim()
  if (q === '') out['quantity'] = 'assets.doc.error.quantityRequired'
  else if (!isDecimalAboveZero(q)) out['quantity'] = 'assets.doc.error.quantity_invalid'
  else if (kind === 'fixed' || kind === 'intangible') {
    if (!/^1(\.0+)?$/.test(q)) out['quantity'] = 'assets.doc.error.quantityOne'
  } else if (kind !== undefined && !/^[0-9]+(\.0+)?$/.test(q)) out['quantity'] = 'assets.doc.error.quantityWhole'
  if (kind === 'intangible' && l.locationId !== '') out['locationId'] = 'assets.doc.opening.reason.location_not_allowed'
  else if ((kind === 'fixed' || kind === 'low_value') && l.locationId === '') out['locationId'] = 'assets.doc.opening.reason.location_required'
  return out
}

/** Errors of the line list by key `lines.<i>.<field>`; a repeat mirrors `OpeningChecks.duplicate?/4`: a fixed or
 *  intangible asset only once, a low value one only with another place or person. */
export function validateOpeningLines(lines: readonly OpeningLine[], cardOf: (id: string) => LineCard | undefined = () => undefined): Record<string, string> {
  const errors: Record<string, string> = {}
  const seenAssets = new Set<string>()
  const seenPlacements = new Set<string>()
  lines.forEach((l, i) => {
    for (const [field, id] of Object.entries(validateOpeningLine(l, cardOf))) errors[`lines.${i}.${field}`] = id
    if (l.assetId === '') return
    const kind = cardOf(l.assetId)?.kind
    const placement = `${l.assetId}|${l.locationId}|${l.responsibleId}|${l.userId}`
    const repeat = seenPlacements.has(placement) || ((kind === 'fixed' || kind === 'intangible') && seenAssets.has(l.assetId))
    if (repeat) errors[`lines.${i}.assetId`] = 'assets.doc.opening.reason.duplicate_asset'
    seenAssets.add(l.assetId)
    seenPlacements.add(placement)
  })
  return errors
}

/** The header's external pair: both or neither, each 1..128 characters. */
export function validateExternalRef(system: string, id: string): Record<string, string> {
  const out: Record<string, string> = {}
  const sys = system.trim()
  const ref = id.trim()
  if ((sys === '') !== (ref === '')) out[sys === '' ? 'header.externalRefSystem' : 'header.externalRefId'] = 'assets.doc.error.external_ref_pair'
  if (sys.length > REF_MAX) out['header.externalRefSystem'] = 'assets.doc.error.textTooLong'
  if (ref.length > REF_MAX) out['header.externalRefId'] = 'assets.doc.error.textTooLong'
  return out
}

/** The `lines` of the request body. `location_id` and `actual_user_id` are left out when empty; the external pair only
 *  when both halves are set. A line never carries cost, depreciation or dates (they stay on the card). */
export function buildOpeningLines(lines: readonly OpeningLine[]): Record<string, string>[] {
  return lines.map((l) => {
    const out: Record<string, string> = { asset_id: l.assetId, material_responsible_id: l.responsibleId, quantity: l.quantity.trim() }
    if (l.locationId.trim() !== '') out['location_id'] = l.locationId
    if (l.userId.trim() !== '') out['actual_user_id'] = l.userId
    if (l.extRefSystem.trim() !== '' && l.extRefId.trim() !== '') {
      out['external_ref_system'] = l.extRefSystem.trim()
      out['external_ref_id'] = l.extRefId.trim()
    }
    return out
  })
}

const REFUSAL_FIELDS: Record<string, string> = {
  asset_id: 'assetId', quantity: 'quantity', location_id: 'locationId', material_responsible_id: 'responsibleId',
  actual_user_id: 'userId', external_ref_id: 'assetId', external_ref_system: 'assetId',
}

/** The form field of a line refusal: the named field, else by reason (`not_linked` is about the LOCATION). */
export function openingRefusalField(reason: string | undefined, field: string | undefined): string | undefined {
  if (field !== undefined && REFUSAL_FIELDS[field]) return REFUSAL_FIELDS[field]
  switch (reason) {
    case 'quantity_invalid': return 'quantity'
    case 'location_required':
    case 'location_not_allowed':
    case 'not_linked': return 'locationId'
    case 'card_not_active':
    case 'duplicate_asset':
    case 'org_unit_mismatch':
    case 'asset_already_in_register': return 'assetId'
    default: return undefined
  }
}

/** Message id of an opening reason; `employee_not_active` names which person by `field`. */
export function openingReasonMessageId(reason: string, field?: string): string | null {
  if (!(OPENING_CHECK_REASONS as readonly string[]).includes(reason)) return null
  if (reason === 'employee_not_active') {
    return `assets.doc.opening.reason.employee_not_active.${field === 'actual_user_id' ? 'actual_user_id' : 'material_responsible_id'}`
  }
  return `assets.doc.opening.reason.${reason}`
}

/** True when the form lines are exactly the saved ones (field by field, so key order cannot matter). */
export function sameOpeningLines(a: readonly OpeningLine[], b: readonly OpeningLine[]): boolean {
  if (a.length !== b.length) return false
  const keys = Object.keys(emptyOpeningLine()) as (keyof OpeningLine)[]
  return a.every((l, i) => keys.every((k) => l[k] === b[i]![k]))
}

/** The messages of a check answer, header reasons first, then each line's reasons in order (one per employee field
 *  for `employee_not_active`). An empty list means every line passed. `fmt` formats a message id with values. */
export function checkMessages(result: OpeningCheckResult, fmt: (id: string, values?: Record<string, string | number>) => string): string[] {
  const out: string[] = []
  const text = (reason: string, field?: string): string => {
    const id = openingReasonMessageId(reason, field)
    return fmt(id ?? 'assets.doc.error.unknown')
  }
  for (const r of result.header) out.push(fmt('assets.doc.opening.check.header', { reason: text(r) }))
  for (const l of result.lines) {
    for (const r of l.reasons) {
      const fields = r === 'employee_not_active' && l.fields.length > 0 ? l.fields : [undefined]
      for (const f of fields) out.push(fmt('assets.doc.opening.check.line', { line: l.line_no, reason: text(r, f) }))
    }
  }
  return out
}
