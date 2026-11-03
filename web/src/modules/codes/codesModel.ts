/** Pure helpers of the codes screen (GH 3606 / REQ-672): constants, line parsing, error mapping. */
import type { EntityRecord } from '@/types/api'

export const CODE_TAG = 'code_tag'
export const CODE_ASSIGNMENT = 'code_assignment'
export const CODE_KINDS = ['barcode', 'qr', 'epc', 'tid'] as const
export const STATUSES = ['not_assigned', 'assigned', 'retired'] as const
/** The target types the assign route accepts (writes.ex `@targets`). */
export const TARGET_TYPES = ['location_node', 'catalog_item', 'catalog_lot'] as const
/** Shown in the limit message only; the server decides. */
export const MAX_BATCH = 1000

/** Every `reason` the codes routes can answer (router.ex, writes.ex). Each has a message. */
export const CODE_REASONS = [
  'code_assigned',
  'code_retired',
  'code_not_assigned',
  'target_type_not_allowed',
  'target_inactive',
  'value_taken',
  'value_invalid',
  'batch_size',
  'entry_invalid',
  'field_invalid',
  'field_not_allowed',
  'record_payload_invalid',
  'idempotency_key_reuse',
  'request_refused',
] as const

/** Reasons of one rejected entry of a batch (`entry_reason`). */
export const ENTRY_REASONS = ['value_invalid', 'kind_invalid', 'duplicate_in_batch', 'value_taken'] as const

export type CodeReason = (typeof CODE_REASONS)[number]

export function textOf(record: EntityRecord, key: string): string {
  const v = record.field_values[key]
  return typeof v === 'string' ? v : ''
}

export interface Line { value: string; line: number }

/** The non-empty lines of the textarea in order, with their 1-based line numbers. Blank lines are skipped; a
 *  value is sent exactly as typed (the server compares exactly), only the line break (`\r`) is removed. */
export function parseLines(text: string): Line[] {
  const out: Line[] = []
  text.split('\n').forEach((raw, i) => {
    const value = raw.replace(/\r$/, '')
    if (value.trim() !== '') out.push({ value, line: i + 1 })
  })
  return out
}

export interface CodesErrorInfo {
  status?: number
  reason?: string
  field?: string
  fields?: string[]
  index?: number
  entryReason?: string
}

/** Reads the RFC 9457 body the client keeps in `ApiError.details`. */
export function reasonOf(err: unknown): CodesErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: CodesErrorInfo = {}
  if (e && typeof e === 'object') {
    if (typeof e.status === 'number') info.status = e.status
    const d = e.details
    if (d && typeof d === 'object') {
      if (typeof d['reason'] === 'string') info.reason = d['reason']
      if (typeof d['field'] === 'string') info.field = d['field']
      if (Array.isArray(d['fields'])) info.fields = d['fields'].filter((f): f is string => typeof f === 'string')
      if (typeof d['index'] === 'number') info.index = d['index']
      if (typeof d['entry_reason'] === 'string') info.entryReason = d['entry_reason']
    }
  }
  return info
}

function isReason(value: string | undefined): value is CodeReason {
  return value !== undefined && (CODE_REASONS as readonly string[]).includes(value)
}

/** The message id for an error of a write call. 404 covers code and target alike (INV-5). */
export function errorMessageId(err: unknown): string {
  const info = reasonOf(err)
  if (info.status === 403) return 'codes.error.forbidden'
  if (info.status === 404) return 'codes.error.notFound'
  if (info.status === 409 || info.reason === 'idempotency_key_reuse') return 'codes.error.idempotency_key_reuse'
  if (isReason(info.reason)) return `codes.error.${info.reason}`
  if (info.status === 422 && info.reason !== undefined) return 'codes.error.unknown'
  return 'codes.error.generic'
}

/** The message id of a rejected batch entry. */
export function entryReasonMessageId(entryReason: string | undefined): string {
  return (ENTRY_REASONS as readonly string[]).includes(entryReason ?? '')
    ? `codes.entry.${entryReason}`
    : 'codes.entry.unknown'
}

/** The code of a target record (falls back to the name). */
export function targetCode(record: EntityRecord | undefined): string {
  return record ? textOf(record, 'code') || textOf(record, 'name') : ''
}
