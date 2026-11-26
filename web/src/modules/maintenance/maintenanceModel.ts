/** maintenanceModel — GH 4802 / REQ-898. Pure helpers of the maintenance screens: the server's reasons and the
 *  message id each one gets, the limits the form counts, the status and urgency of a request. The server stays
 *  the authority: a reason the list does not know gets the generic text, never the raw code. */
import type { StatusTone } from '@/components/ui/StatusPill'
import { MAX_PHOTOS, MAX_DESCRIPTION } from './maintenanceLimits'

export { MAX_PHOTOS, MAX_DESCRIPTION }

/** Every `reason` the maintenance routes can answer (requests.ex, photos.ex, orders.ex). Each has a message. */
export const REASONS = [
  'asset_card_not_found',
  'asset_card_inactive',
  'asset_card_no_org_unit',
  'description_required',
  'description_too_long',
  'invalid_urgency',
  'reason_required',
  'invalid_filter',
  'field_not_allowed',
  'field_invalid',
  'request_not_new',
  'definition_not_active',
  'order_not_assignable',
  'order_source_invalid',
  'assignee_not_found',
  'idempotency_key_reuse',
] as const

export type Reason = (typeof REASONS)[number]

/** Every `reason` a photo upload can answer (the attachment service's refusals). */
export const PHOTO_REASONS = [
  'photo_type_not_allowed',
  'photo_malformed',
  'photo_too_large',
  'photo_infected',
  'owner_cap_reached',
  'caption_invalid',
  'invalid_order',
  'photo_not_own',
  'photo_locked',
  'storage_quota_exceeded',
  'upload_rate_exceeded',
  'scan_unavailable',
  'original_required',
] as const

export interface MaintenanceErrorInfo {
  status?: number
  reason?: string
}

/** Reads the RFC 9457 body the client keeps in `ApiError.details`. */
export function reasonOf(err: unknown): MaintenanceErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: MaintenanceErrorInfo = {}
  if (e && typeof e === 'object') {
    if (typeof e.status === 'number') info.status = e.status
    const d = e.details
    if (d && typeof d === 'object' && typeof d['reason'] === 'string') info.reason = d['reason']
  }
  return info
}

function isReason(value: string | undefined): value is Reason {
  return value !== undefined && (REASONS as readonly string[]).includes(value)
}

/** The message id of a refused write. 404 and 403 have one text each; a known reason has its own. */
export function errorMessageId(err: unknown): string {
  const info = reasonOf(err)
  if (info.status === 403) return 'maintenance.error.forbidden'
  if (info.status === 404) return 'maintenance.error.notFound'
  if (isReason(info.reason)) return `maintenance.error.${info.reason}`
  if (info.status === 422) return 'maintenance.error.unknown'
  return 'maintenance.error.generic'
}

/** The message id of a refused photo upload. */
export function photoErrorId(err: unknown): string {
  const info = reasonOf(err)
  if (info.reason !== undefined && (PHOTO_REASONS as readonly string[]).includes(info.reason)) {
    return `maintenance.photos.error.${info.reason}`
  }
  if (info.reason === 'request_not_new') return 'maintenance.photos.error.request_not_new'
  if (info.status === 404) return 'maintenance.photos.error.notFound'
  if (info.status === 403) return 'maintenance.photos.error.forbidden'
  if (info.status === 429) return 'maintenance.photos.error.upload_rate_exceeded'
  return 'maintenance.photos.error.generic'
}

/** Characters as the server counts them (code points), not UTF-16 units. */
export const codePoints = (text: string) => Array.from(text).length

/** The pill of a request status: a word and a glyph, never colour alone. */
export function statusTone(status: string): StatusTone {
  if (status === 'new') return 'info'
  if (status === 'ordered') return 'current'
  if (status === 'rejected') return 'warning'
  return 'neutral'
}

/** The pill of an urgency: urgent stands out, low stays quiet. */
export function urgencyTone(urgency: string): StatusTone {
  if (urgency === 'urgent') return 'danger'
  if (urgency === 'normal') return 'info'
  return 'neutral'
}

/** The date of a record as the screen shows it: the day and the time of the tenant. */
export function formatWhen(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}
