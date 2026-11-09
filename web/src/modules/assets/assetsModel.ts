/** Pure helpers of the asset card screens (T-1333 / C13): form <-> request bodies, the decimal check, search,
 *  error mapping. Decimals and dates are strings everywhere; nothing here converts them to numbers. */
import type { EntityRecord } from '@/types/api'
import type { CardBody } from './assets.api'

export const ASSET_CARD = 'assets_card'
export const ORG_UNIT = 'org_unit'

export const ASSET_KINDS = ['fixed', 'low_value', 'intangible'] as const
export type AssetKind = (typeof ASSET_KINDS)[number]

/** Every `reason` the card routes can answer (router.ex, cards.ex). Each has a message. */
export const ASSET_REASONS = [
  'field_invalid',
  'field_not_allowed',
  'record_payload_invalid',
  'org_unit_not_active',
  'valid_until_not_allowed',
  'inventory_number_locked',
  'kind_locked',
  'currency_mismatch',
  'card_inactive',
  'idempotency_key_reuse',
  'request_refused',
] as const

export type AssetReason = (typeof ASSET_REASONS)[number]

export function textOf(record: EntityRecord, key: string): string {
  const v = record.field_values[key]
  return typeof v === 'string' ? v : ''
}

export function isActive(record: EntityRecord): boolean {
  return record.field_values['active'] !== false
}

export interface Form {
  inventory_number: string
  name: string
  kind: string
  acquisition_date: string
  currency: string
  acquisition_cost: string
  accumulated_depreciation: string
  book_value: string
  depreciation_as_of: string
  valid_until: string
}

export const EMPTY_FORM: Form = {
  inventory_number: '',
  name: '',
  kind: 'fixed',
  acquisition_date: '',
  currency: '',
  acquisition_cost: '',
  accumulated_depreciation: '',
  book_value: '',
  depreciation_as_of: '',
  valid_until: '',
}

const REQUIRED_KEYS = ['inventory_number', 'name'] as const
const OPTIONAL_KEYS = [
  'acquisition_date',
  'currency',
  'acquisition_cost',
  'accumulated_depreciation',
  'book_value',
  'depreciation_as_of',
  'valid_until',
] as const

export const DECIMAL_KEYS = ['acquisition_cost', 'accumulated_depreciation', 'book_value'] as const

export function formOf(record: EntityRecord | null): Form {
  if (record === null) return { ...EMPTY_FORM }
  const form = { ...EMPTY_FORM }
  for (const key of Object.keys(form) as (keyof Form)[]) {
    const v = textOf(record, key)
    if (v !== '' || key !== 'kind') form[key] = v
  }
  return form
}

/** Create body: the required keys, the kind, and only the optional keys that hold text. `valid_until` goes only
 *  with kind intangible. Never `active`. */
export function createBody(form: Form): CardBody {
  const body: CardBody = { kind: form.kind }
  for (const key of REQUIRED_KEYS) body[key] = form[key].trim()
  for (const key of OPTIONAL_KEYS) {
    if (key === 'valid_until' && form.kind !== 'intangible') continue
    const v = form[key].trim()
    if (v !== '') body[key] = v
  }
  return body
}

/** Update body: only the keys that changed; a cleared optional key is `null`. Never `kind`, never `active`.
 *  `valid_until` is judged only for an intangible card. */
export function updateBody(initial: Form, form: Form): CardBody {
  const body: CardBody = {}
  for (const key of REQUIRED_KEYS) {
    if (form[key].trim() !== initial[key]) body[key] = form[key].trim()
  }
  for (const key of OPTIONAL_KEYS) {
    if (key === 'valid_until' && form.kind !== 'intangible') continue
    const now = form[key].trim()
    if (now !== initial[key]) body[key] = now === '' ? null : now
  }
  return body
}

const DECIMAL = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/

/** The server's strict decimal form with precision 24 and scale 9: at most 15 integer digits and 9 decimals.
 *  Empty text is fine (the field is optional). Returns the kind of fault, or null. */
export function decimalError(text: string): 'format' | 'size' | null {
  const v = text.trim()
  if (v === '') return null
  if (!DECIMAL.test(v)) return 'format'
  const [int, frac = ''] = v.replace(/^-/, '').split('.')
  return int.length > 15 || frac.length > 9 ? 'size' : null
}

/** Case-insensitive match of the search text against inventory number and name. */
export function matchesSearch(record: EntityRecord, search: string): boolean {
  const q = search.trim().toLowerCase()
  if (q === '') return true
  return (
    textOf(record, 'inventory_number').toLowerCase().includes(q) || textOf(record, 'name').toLowerCase().includes(q)
  )
}

export interface AssetsErrorInfo {
  status?: number
  reason?: string
  field?: string
  fields?: string[]
}

/** Reads the RFC 9457 body the client keeps in `ApiError.details`. */
export function reasonOf(err: unknown): AssetsErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: AssetsErrorInfo = {}
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

function isReason(value: string | undefined): value is AssetReason {
  return value !== undefined && (ASSET_REASONS as readonly string[]).includes(value)
}

/** The message id for an error of a write call. */
export function errorMessageId(err: unknown): string {
  const info = reasonOf(err)
  if (info.status === 403) return 'assets.error.forbidden'
  if (info.status === 404) return 'assets.error.notFound'
  if (info.status === 409 || info.reason === 'idempotency_key_reuse') return 'assets.error.idempotency_key_reuse'
  if (isReason(info.reason)) return `assets.error.${info.reason}`
  if (info.status === 422 && info.reason !== undefined) return 'assets.error.unknown'
  return 'assets.error.generic'
}

/** The form field a reason points at when the server names none. */
const REASON_FIELD: Record<string, string> = {
  org_unit_not_active: 'org_unit_id',
  valid_until_not_allowed: 'valid_until',
  inventory_number_locked: 'inventory_number',
  kind_locked: 'kind',
  currency_mismatch: 'currency',
}

/** True when the error marks this input. */
export function fieldMarked(error: unknown, name: string): boolean {
  const info = reasonOf(error)
  if (info.reason !== undefined && REASON_FIELD[info.reason] === name) return true
  const named = info.field === name || (info.fields ?? []).includes(name)
  return (
    (info.reason === 'field_invalid' || info.reason === 'field_not_allowed' || info.reason === 'record_payload_invalid') &&
    named
  )
}
