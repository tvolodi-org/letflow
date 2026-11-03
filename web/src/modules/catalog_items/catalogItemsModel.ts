/** Pure helpers of the catalog_items screen (GH 3605 / REQ-673): constants, error mapping. */
import type { EntityRecord } from '@/types/api'

export const CATALOG_LOT = 'catalog_lot'
export const CATALOG_ITEM = 'catalog_item'

/** Every `reason` the catalog_items lot routes can answer. Each has a message. */
export const LOT_REASONS = [
  'item_not_found',
  'item_inactive',
  'field_invalid',
  'field_not_allowed',
  'record_payload_invalid',
  'idempotency_key_reuse',
  'request_refused',
] as const

export type LotReason = (typeof LOT_REASONS)[number]

export function textOf(record: EntityRecord, key: string): string {
  const v = record.field_values[key]
  return typeof v === 'string' ? v : ''
}

export interface LotErrorInfo {
  status?: number
  reason?: string
  field?: string
  fields?: string[]
}

/** Reads the RFC 9457 body the client keeps in `ApiError.details`. */
export function reasonOf(err: unknown): LotErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: LotErrorInfo = {}
  if (e && typeof e === 'object') {
    if (typeof e.status === 'number') info.status = e.status
    const d = e.details
    if (d && typeof d === 'object') {
      if (typeof d['reason'] === 'string') info.reason = d['reason']
      if (typeof d['field'] === 'string') info.field = d['field']
      if (Array.isArray(d['fields'])) info.fields = d['fields'].filter((f): f is string => typeof f === 'string')
    }
  }
  return info
}

/** Validates that a string looks like YYYY-MM-DD (does not validate calendar correctness). */
export function isValidDateInput(v: string): boolean {
  return v === '' || /^\d{4}-\d{2}-\d{2}$/.test(v)
}

/** Builds the create body, omitting empty optional fields. */
export function lotBodyForCreate(form: {
  item_id: string
  code: string
  producer: string
  mark: string
  expiry_date: string
}) {
  const body: Record<string, string> = { item_id: form.item_id, code: form.code }
  if (form.producer.trim() !== '') body['producer'] = form.producer
  if (form.mark.trim() !== '') body['mark'] = form.mark
  if (form.expiry_date.trim() !== '') body['expiry_date'] = form.expiry_date
  return body
}

/** Builds the edit body: exactly producer, mark, expiry_date; null for emptied fields. */
export function lotBodyForEdit(form: { producer: string; mark: string; expiry_date: string }) {
  return {
    producer: form.producer.trim() === '' ? null : form.producer,
    mark: form.mark.trim() === '' ? null : form.mark,
    expiry_date: form.expiry_date.trim() === '' ? null : form.expiry_date,
  }
}

/** The message id for an error of a write call. */
export function errorMessageId(err: unknown): string {
  const info = reasonOf(err)
  if (info.status === 403) return 'catalog_items.error.forbidden'
  if (info.status === 404) return 'catalog_items.error.notFound'
  if (info.reason === 'idempotency_key_reuse') return 'catalog_items.error.idempotency_key_reuse'
  if (info.reason === 'item_not_found') return 'catalog_items.error.item_not_found'
  if (info.reason === 'item_inactive') return 'catalog_items.error.item_inactive'
  if (info.reason === 'field_invalid' && info.field === 'expiry_date') return 'catalog_items.error.expiryInvalid'
  if (info.reason === 'field_invalid') return 'catalog_items.error.field_invalid'
  if (info.reason === 'record_payload_invalid') return 'catalog_items.error.lotCodeTaken'
  if (info.reason === 'request_refused') return 'catalog_items.error.request_refused'
  if (info.status === 422 && info.reason !== undefined) return 'catalog_items.error.unknown'
  return 'catalog_items.error.generic'
}
