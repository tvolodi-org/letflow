/** kindChangeForm — T-1336 / C16. Pure model of the lines of a change of kind document (REQ-759): a stock side (item,
 *  unit, lot, quantity, location, responsible) that leaves the stock register and an asset side (kind, inventory
 *  number, name, org unit, location, holder, user) that enters the asset register. Checks mirror the server so the user
 *  is told early; the server stays the authority. A PUT replaces the whole line list, so every loaded value is sent
 *  back. `asset_card_id` is server-set and is never part of a body. */
import type { AssetDocumentLine } from './assetDocuments.api'
import { isDecimalAboveZero, trimZeros } from './documentForm'

export const TARGET_KINDS = ['low_value', 'fixed'] as const
export type TargetKind = (typeof TARGET_KINDS)[number]

export const INVENTORY_NUMBER_MAX = 64
export const ASSET_NAME_MAX = 200

export interface KindChangeLine {
  itemId: string
  uomId: string
  lotId: string
  quantity: string
  stockLocationId: string
  stockResponsibleId: string
  targetKind: string
  inventoryNumber: string
  assetName: string
  assetOrgUnitId: string
  assetLocationId: string
  materialResponsibleId: string
  actualUserId: string
}

export const emptyKindChangeLine = (): KindChangeLine => ({
  itemId: '', uomId: '', lotId: '', quantity: '1', stockLocationId: '', stockResponsibleId: '',
  targetKind: 'low_value', inventoryNumber: '', assetName: '', assetOrgUnitId: '', assetLocationId: '',
  materialResponsibleId: '', actualUserId: '',
})

/** Body key by form field (the order of `Kinds.@kind_change_line_keys`). */
const BODY_KEYS: ReadonlyArray<readonly [keyof KindChangeLine, string, boolean]> = [
  ['itemId', 'catalog_item_id', true],
  ['uomId', 'catalog_uom_id', true],
  ['lotId', 'catalog_lot_id', false],
  ['quantity', 'quantity', true],
  ['stockLocationId', 'stock_location_id', true],
  ['stockResponsibleId', 'stock_responsible_id', true],
  ['targetKind', 'target_kind', true],
  ['assetOrgUnitId', 'asset_org_unit_id', false],
  ['assetLocationId', 'asset_location_id', true],
  ['materialResponsibleId', 'material_responsible_id', true],
  ['actualUserId', 'actual_user_id', false],
  ['inventoryNumber', 'inventory_number', true],
  ['assetName', 'asset_name', true],
]

/** Body key of a form field -> form field (for placing a refusal that names a field). */
const FIELD_BY_BODY_KEY: Record<string, keyof KindChangeLine> = Object.fromEntries(BODY_KEYS.map(([f, k]) => [k, f]))

/** Message ids of one line by field. Required fields use `field_required`; the rest have their own text. */
export function validateKindChangeLine(l: KindChangeLine): Record<string, string> {
  const out: Record<string, string> = {}
  const required = 'assets.doc.error.field_required'
  for (const [field, , must] of BODY_KEYS) {
    if (must && l[field].trim() === '' && field !== 'quantity') out[field] = required
  }
  const q = l.quantity.trim()
  if (q === '') out['quantity'] = 'assets.doc.error.quantityRequired'
  else if (!isDecimalAboveZero(q)) out['quantity'] = 'assets.doc.error.quantity_invalid'
  else if (l.targetKind === 'fixed') {
    if (!/^1(\.0+)?$/.test(q)) out['quantity'] = 'assets.doc.error.quantityOne'
  } else if (!/^[0-9]+(\.0+)?$/.test(q)) out['quantity'] = 'assets.doc.error.quantityWhole'
  if (l.targetKind !== '' && !(TARGET_KINDS as readonly string[]).includes(l.targetKind)) out['targetKind'] = 'assets.doc.error.field_invalid'
  if (l.inventoryNumber.trim().length > INVENTORY_NUMBER_MAX) out['inventoryNumber'] = 'assets.doc.error.field_invalid'
  if (l.assetName.trim().length > ASSET_NAME_MAX) out['assetName'] = 'assets.doc.error.field_invalid'
  return out
}

/** Errors of the line list by key `lines.<i>.<field>`, including a repeated inventory number inside the document. */
export function validateKindChangeLines(lines: readonly KindChangeLine[]): Record<string, string> {
  const errors: Record<string, string> = {}
  const seen = new Set<string>()
  lines.forEach((l, i) => {
    for (const [field, id] of Object.entries(validateKindChangeLine(l))) errors[`lines.${i}.${field}`] = id
    const n = l.inventoryNumber.trim()
    if (n !== '') {
      if (seen.has(n)) errors[`lines.${i}.inventoryNumber`] = 'assets.doc.error.inventory_number_taken'
      seen.add(n)
    }
  })
  return errors
}

/** The `lines` of the request body: every key trimmed; an empty optional key is left out (the server reads it as
 *  cleared or defaulted: a blank asset org unit becomes the header unit); never `asset_card_id`. */
export function buildKindChangeLines(lines: readonly KindChangeLine[]): Record<string, string>[] {
  return lines.map((l) => {
    const out: Record<string, string> = {}
    for (const [field, key, must] of BODY_KEYS) {
      const v = l[field].trim()
      if (must || v !== '') out[key] = v
    }
    return out
  })
}

const s = (v: string | null | undefined): string => v ?? ''

/** The form lines of a loaded draft (every value, so a PUT does not clear any). */
export function kindChangeLinesFromDocument(lines: readonly AssetDocumentLine[]): KindChangeLine[] {
  return [...lines]
    .sort((a, b) => a.line_no - b.line_no)
    .map((l) => ({
      itemId: s(l.catalog_item_id),
      uomId: s(l.catalog_uom_id),
      lotId: s(l.catalog_lot_id),
      quantity: trimZeros(s(l.quantity)),
      stockLocationId: s(l.stock_location_id),
      stockResponsibleId: s(l.stock_responsible_id),
      targetKind: s(l.target_kind) || 'low_value',
      inventoryNumber: s(l.inventory_number),
      assetName: s(l.asset_name),
      assetOrgUnitId: s(l.asset_org_unit_id),
      assetLocationId: s(l.asset_location_id),
      materialResponsibleId: s(l.material_responsible_id),
      actualUserId: s(l.actual_user_id),
    }))
}

/** Where a refusal lands: `{ field }` is the form field of the line (undefined = the whole line). `not_linked` names
 *  the side: stock -> the stock location, asset -> the asset location. */
export function kindChangeRefusalField(reason: string | undefined, field: string | undefined, side: string | undefined): string | undefined {
  if (field !== undefined && FIELD_BY_BODY_KEY[field]) return FIELD_BY_BODY_KEY[field]
  switch (reason) {
    case 'not_linked': return side === 'asset' ? 'assetLocationId' : 'stockLocationId'
    case 'item_not_active': return 'itemId'
    case 'unit_not_valid': return 'uomId'
    case 'lot_not_valid':
    case 'lot_required':
    case 'lot_not_allowed':
    case 'lot_expiry_missing':
    case 'tracking_invalid': return 'lotId'
    case 'location_not_active': return 'stockLocationId'
    case 'quantity_invalid': return 'quantity'
    case 'inventory_number_taken': return 'inventoryNumber'
    default: return undefined
  }
}
