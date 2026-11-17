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

/** Returns an error message key or undefined if valid. */
export function validateQuantity(value: string): string | undefined {
  if (value === '') return 'stock.qc.err.quantity_required'
  const n = Number(value)
  if (isNaN(n) || value.trim() === '') return 'stock.qc.err.quantity_invalid'
  if (n < 0) return 'stock.qc.err.quantity_negative'
  const dot = value.indexOf('.')
  if (dot !== -1 && value.length - dot - 1 > 9) return 'stock.qc.err.quantity_decimals'
  return undefined
}

/** Maps a 422/409 error details.reason to a message key. */
export function errorReasonToMessageId(reason: string | undefined): string {
  switch (reason) {
    case 'count_in_progress': return 'stock.qc.error.count_in_progress'
    case 'location_frozen': return 'stock.qc.error.location_frozen'
    case 'quick_count_stale': return 'stock.qc.error.quick_count_stale'
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
