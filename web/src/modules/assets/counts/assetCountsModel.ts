/** assetCountsModel — T-1933 / REQ-822 (K7a). Pure helpers of the asset count order screens: the whole-draft request body,
 *  the local checks, tenant-zone times, refusal reasons -> message ids, which buttons a status and the atoms allow. */
import type { StatusTone } from '@/components/ui/StatusPill'
import { isoToZonedLocal, zonedLocalToIso } from '../documents/documentForm'
import { ASSETS_COUNT_ORDER } from '../assetsPermissions'
import type { AssetCountOrder, AssetCountOrderBody } from './assetCounts.api'

export const COUNT_STATUSES = ['draft', 'ordered', 'counting', 'counted', 'sheet_signed', 'signed', 'cancelled'] as const
export const COUNT_KINDS = ['fixed', 'low_value', 'intangible'] as const
export const CANCELLABLE: readonly string[] = ['draft', 'ordered', 'counting', 'counted', 'sheet_signed']
/** REQ-816: a count lasts at most 96 hours. */
export const MAX_HOURS = 96

/** The 422 reasons of the order routes; each has a message `assets.count.reason.<reason>`. */
export const COUNT_REASONS = [
  'field_invalid',
  'field_not_allowed',
  'org_unit_inactive',
  'employee_inactive',
  'chair_without_user',
  'count_scope_not_linked',
  'count_scope_overlaps',
  'count_too_long',
  'count_state_invalid',
  'not_chair',
] as const

/** The field a reason points at when the server names none. */
export const REASON_FIELD: Record<string, string> = {
  org_unit_inactive: 'org_unit_id',
  chair_without_user: 'chair_employee_id',
  count_scope_not_linked: 'location_ids',
  count_scope_overlaps: 'location_ids',
  count_too_long: 'planned_end',
  employee_inactive: 'member_employee_ids',
}

export interface OrderForm {
  org_unit_id: string
  kinds: string[]
  planned_start: string
  planned_end: string
  chair_employee_id: string
  member_employee_ids: string[]
  location_ids: string[]
  note: string
  freeze_locations: boolean
}
export const EMPTY_ORDER_FORM: OrderForm = {
  org_unit_id: '',
  kinds: [],
  planned_start: '',
  planned_end: '',
  chair_employee_id: '',
  member_employee_ids: [],
  location_ids: [],
  note: '',
  freeze_locations: false,
}

export function formFromOrder(o: AssetCountOrder): OrderForm {
  return {
    org_unit_id: o.org_unit_id,
    kinds: o.kinds ?? [],
    planned_start: isoToZonedLocal(o.planned_start),
    planned_end: isoToZonedLocal(o.planned_end),
    chair_employee_id: o.chair_employee_id ?? '',
    member_employee_ids: o.member_employee_ids ?? [],
    location_ids: o.location_ids ?? [],
    note: o.note ?? '',
    freeze_locations: o.freeze_locations === true,
  }
}

/** The whole draft, all nine keys every time; an empty note is null; times are read in the tenant zone. */
export function buildOrderBody(f: OrderForm): AssetCountOrderBody {
  return {
    org_unit_id: f.org_unit_id,
    kinds: COUNT_KINDS.filter((k) => f.kinds.includes(k)),
    planned_start: zonedLocalToIso(f.planned_start) ?? '',
    planned_end: zonedLocalToIso(f.planned_end) ?? '',
    chair_employee_id: f.chair_employee_id,
    member_employee_ids: f.member_employee_ids,
    location_ids: f.location_ids,
    note: f.note.trim() === '' ? null : f.note,
    freeze_locations: f.freeze_locations,
  }
}

export type OrderField = 'org_unit_id' | 'kinds' | 'planned_start' | 'planned_end' | 'chair_employee_id'

/** The invalid fields of the order form, in form order. An end that is not after the start, or more than 96 hours
 *  after it, flags `planned_end`. */
export function orderFormProblems(f: OrderForm): OrderField[] {
  const out: OrderField[] = []
  const start = zonedLocalToIso(f.planned_start)
  const end = zonedLocalToIso(f.planned_end)
  if (f.org_unit_id === '') out.push('org_unit_id')
  if (f.kinds.length === 0) out.push('kinds')
  if (start === null) out.push('planned_start')
  if (end === null) out.push('planned_end')
  else if (start !== null) {
    const span = new Date(end).getTime() - new Date(start).getTime()
    if (span <= 0 || span > MAX_HOURS * 3600_000) out.push('planned_end')
  }
  if (f.chair_employee_id === '') out.push('chair_employee_id')
  return out
}

export function reasonOf(err: unknown): string | null {
  const r = (err as { details?: { reason?: unknown } } | null | undefined)?.details?.reason
  return typeof r === 'string' ? r : null
}
export function fieldOf(err: unknown): string | null {
  const f = (err as { details?: { field?: unknown } } | null | undefined)?.details?.field
  if (typeof f === 'string') return f
  const r = reasonOf(err)
  return r !== null ? (REASON_FIELD[r] ?? null) : null
}
/** Every list of the answer is 404 when the module setting count_enabled is off (or the module is absent). */
export const isFlagOff = (err: unknown): boolean => (err as { status?: unknown } | null | undefined)?.status === 404

/** Message id of a failed call: its own reason, else forbidden / not found / generic. */
export function reasonMessageId(err: unknown): string {
  const status = (err as { status?: unknown } | null | undefined)?.status
  const reason = reasonOf(err)
  if (status === 422 && reason !== null && (COUNT_REASONS as readonly string[]).includes(reason)) return `assets.count.reason.${reason}`
  if (status === 403) return 'assets.count.error.forbidden'
  if (status === 404) return 'assets.count.error.notFound'
  return 'assets.count.error.generic'
}

export function statusTone(status: string): StatusTone {
  switch (status) {
    case 'ordered': return 'info'
    case 'counting': return 'current'
    case 'counted':
    case 'sheet_signed':
    case 'signed': return 'success'
    case 'cancelled': return 'danger'
    default: return 'neutral'
  }
}

type Atoms = (permission: string) => boolean
export const canEdit = (o: AssetCountOrder, can: Atoms) => can(ASSETS_COUNT_ORDER) && o.status === 'draft'
export const canIssue = canEdit
export const canCancel = (o: AssetCountOrder, can: Atoms) => can(ASSETS_COUNT_ORDER) && CANCELLABLE.includes(o.status)
