/** quickCountModel — REQ-855. Pure helpers: reason codes, validation, error handling. */

export const REASON_CODES = ['recount', 'found', 'missing', 'damaged', 'other'] as const
export type ReasonCode = (typeof REASON_CODES)[number]

export interface QuickCountForm {
  itemId: string
  locationId: string
  orgUnitId: string
  lotId: string
  countedQuantity: string
  reasonCode: string
  reasonText: string
}

export const EMPTY_FORM: QuickCountForm = {
  itemId: '',
  locationId: '',
  orgUnitId: '',
  lotId: '',
  countedQuantity: '',
  reasonCode: 'recount',
  reasonText: '',
}

const QUANTITY_RE = /^\d+(\.\d+)?$/
const SCALE = 9
const TEN_POW = 10n ** BigInt(SCALE)

/** Returns an error message key or undefined if valid. Only a plain decimal is a number here ('1e3', '0x10' and
 *  ' 5 ' are refused before sending, as the server refuses them). */
export function validateQuantity(value: string): string | undefined {
  if (value === '') return 'stock.qc.err.quantity_required'
  if (/^-\d+(\.\d+)?$/.test(value)) return 'stock.qc.err.quantity_negative'
  if (!QUANTITY_RE.test(value)) return 'stock.qc.err.quantity_invalid'
  const dot = value.indexOf('.')
  if (dot !== -1 && value.length - dot - 1 > SCALE) return 'stock.qc.err.quantity_decimals'
  return undefined
}

/** A decimal string (optional minus, up to 9 decimals) as an integer of 10^-9 units, or null when it is not one. */
function toUnits(value: string): bigint | null {
  const m = /^(-)?(\d+)(?:\.(\d{1,9}))?$/.exec(value.trim())
  if (!m) return null
  const units = BigInt(m[2]!) * TEN_POW + BigInt((m[3] ?? '').padEnd(SCALE, '0'))
  return m[1] ? -units : units
}

/** counted - book, exact (no floats): '10.3' - '10.1' is '0.2', trailing zeros trimmed. Null when either side is not
 *  a decimal of at most 9 places (the preview is then not shown; validation names the field). */
export function subtractDecimal(counted: string, book: string): string | null {
  const a = toUnits(counted)
  const b = toUnits(book)
  if (a === null || b === null) return null
  const d = a - b
  const abs = d < 0n ? -d : d
  const whole = (abs / TEN_POW).toString()
  const frac = (abs % TEN_POW).toString().padStart(SCALE, '0').replace(/0+$/, '')
  return `${d < 0n ? '-' : ''}${whole}${frac ? `.${frac}` : ''}`
}

/** The server needs a lot for the policies lot and expiry (Checks.tracking_result/3); no policy counts as none. */
export function needsLot(fields: Record<string, unknown> | undefined): boolean {
  const policy = fields?.['tracking_policy']
  return policy === 'lot' || policy === 'expiry'
}

/** Maps a 422/409 error details.reason to a message key. */
export function errorReasonToMessageId(reason: string | undefined): string {
  switch (reason) {
    case 'count_in_progress': return 'stock.qc.error.count_in_progress'
    case 'location_frozen': return 'stock.qc.error.location_frozen'
    case 'quick_count_stale': return 'stock.qc.error.quick_count_stale'
    case 'unknown_kind': return 'stock.qc.error.unknown_kind'
    case 'reason_invalid': return 'stock.qc.error.reason_invalid'
    case 'quantity_invalid': return 'stock.qc.error.quantity_invalid'
    case 'lot_required': return 'stock.qc.error.lot_required'
    case 'tracking_policy_not_supported': return 'stock.qc.error.tracking_policy_not_supported'
    case 'field_required': return 'stock.qc.error.field_required'
    default: return 'stock.qc.error.generic'
  }
}

/** Returns the field name the error targets (for inline field errors), or undefined for banner errors. */
export function errorReasonToField(reason: string | undefined): keyof QuickCountForm | undefined {
  switch (reason) {
    case 'reason_invalid': return 'reasonCode'
    case 'quantity_invalid': return 'countedQuantity'
    case 'lot_required': return 'lotId'
    case 'tracking_policy_not_supported': return 'itemId'
    case 'field_required': return undefined
    default: return undefined
  }
}

/** Returns true if the error should be shown as a banner (not inline). */
export function isBannerError(reason: string | undefined): boolean {
  return reason === 'count_in_progress' || reason === 'location_frozen' || reason === 'quick_count_stale'
}
