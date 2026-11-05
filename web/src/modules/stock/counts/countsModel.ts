/** countsModel — GH 3735 / REQ-702. Pure helpers of the count screens: the whole-draft request body, the quantity
 *  check, tenant-zone times, refusal reasons -> message ids, which buttons a status and the atoms allow. */
import type { CountOrder, CountOrderBody, PaperworkKind } from './counts.api'
import type { StatusTone } from '@/components/ui/StatusPill'
import { STOCK_COUNT_ORDER, STOCK_COUNT_RECORD, STOCK_POST, STOCK_REVERSE } from '../stockPermissions'
import { formatDateTimeInZone } from '@/i18n/format'
export { STOCK_COUNT_ORDER, STOCK_COUNT_RECORD, STOCK_POST, STOCK_REVERSE }

/** Tenant time zone until the tenant setting exists: assumption of REQ-702, owner may change at GATE B (UTC+5, no DST). */
export const TENANT_TIME_ZONE = 'Asia/Almaty'
const TZ_OFFSET = '+05:00'


export const COUNT_STATUSES = ['draft', 'ordered', 'counting', 'counted', 'signed', 'posted', 'cancelled'] as const
export const COUNT_KINDS = ['full', 'selective'] as const

/** The 422 reasons of REQ-700 and REQ-701 criterion 4 of REQ-702; each has its own message `counts.reason.<reason>`. */
export const COUNT_REASONS = [
  'count_state_invalid',
  'count_scope_not_linked',
  'count_scope_overlaps',
  'count_scope_incomplete',
  'count_too_long',
  'chair_without_user',
  'employee_inactive',
  'org_unit_inactive',
  'not_chair',
  'not_commission_member',
  'count_not_due',
  'location_not_in_count',
  'item_inactive',
  'unit_invalid',
  'lot_invalid',
  'count_line_exists',
  'lines_uncounted',
  'line_not_found',
  'field_invalid',
  'code_retired',
  'code_assignment_conflict',
  'code_not_assigned',
  'code_not_countable',
  'scan_no_line',
  'scan_ambiguous',
  'scan_id_conflict',
  'signers_incomplete',
  'sheet_already_signed',
  'sheet_not_signed',
  'differences_already_issued',
  'differences_not_issued',
  'differences_too_many',
  'count_window_expired',
  'document_not_issued',
  // REQ-718 (422)
  'no_differences',
  'reason_invalid',
  'shortage_exceeds_balance',
] as const

/** The 409 reasons of the posting routes (REQ-718); each has its own message `counts.reason.<reason>`. */
export const COUNT_CONFLICTS = [
  'posting_pending',
  'count_posted',
  'count_not_posted',
  'count_reversed',
  'reversal_pending',
  'posting_inconsistent',
  'definition_not_active',
  'posting_record_exists',
] as const

/** A decimal string at least 0: digits, optional fraction; no sign, exponent, comma or space. */
export function isDecimalNonNegative(s: string): boolean {
  return /^\d+(\.\d+)?$/.test(s)
}

export interface OrderForm {
  org_unit_id: string
  kind: string
  planned_start: string
  planned_end: string
  chair_employee_id: string
  member_employee_ids: string[]
  location_ids: string[]
  note: string
}
export const EMPTY_ORDER_FORM: OrderForm = {
  org_unit_id: '',
  kind: 'full',
  planned_start: '',
  planned_end: '',
  chair_employee_id: '',
  member_employee_ids: [],
  location_ids: [],
  note: '',
}

/** `YYYY-MM-DDTHH:mm` (also with seconds, or a space for the T) typed in the tenant zone -> ISO 8601 with offset
 *  (seconds are dropped). Empty when the text is not a local time. */
export function zonedToIso(local: string): string {
  const m = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?$/.exec(local.trim())
  return m ? `${m[1]}T${m[2]}:00${TZ_OFFSET}` : ''
}

function parts(iso: string): Record<string, string> | null {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  const out: Record<string, string> = {}
  for (const p of new Intl.DateTimeFormat('en-GB', {
    timeZone: TENANT_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(d)) out[p.type] = p.value
  return out
}

/** ISO instant -> `YYYY-MM-DDTHH:mm` in the tenant zone (the datetime-local value). */
export function isoToLocalInput(iso: string | null | undefined): string {
  const p = iso ? parts(iso) : null
  return p ? `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}` : ''
}

/** ISO instant -> `YYYY-MM-DD HH:mm` in the tenant zone, for tables and logs. */
export function formatInZone(iso: string | null | undefined): string {
  return formatDateTimeInZone(iso, { timeZone: TENANT_TIME_ZONE, enStyle: 'iso' })
}

/** The whole draft, every key every time; an empty note is null. */
export function buildOrderBody(f: OrderForm): CountOrderBody {
  return {
    org_unit_id: f.org_unit_id,
    kind: f.kind,
    planned_start: zonedToIso(f.planned_start),
    planned_end: zonedToIso(f.planned_end),
    chair_employee_id: f.chair_employee_id,
    member_employee_ids: f.member_employee_ids,
    location_ids: f.location_ids,
    note: f.note.trim() === '' ? null : f.note,
  }
}

export function formFromOrder(o: CountOrder): OrderForm {
  return {
    org_unit_id: o.org_unit_id,
    kind: o.kind,
    planned_start: isoToLocalInput(o.planned_start),
    planned_end: isoToLocalInput(o.planned_end),
    chair_employee_id: o.chair_employee_id ?? '',
    member_employee_ids: o.member_employee_ids ?? [],
    location_ids: o.location_ids ?? [],
    note: o.note ?? '',
  }
}

export type OrderField = 'org_unit_id' | 'planned_start' | 'planned_end' | 'chair_employee_id' | 'location_ids'

/** The invalid fields of the order form, in form order. An end that is not after the start flags `planned_end`. */
export function orderFormProblems(f: OrderForm): OrderField[] {
  const out: OrderField[] = []
  const start = zonedToIso(f.planned_start)
  const end = zonedToIso(f.planned_end)
  if (f.org_unit_id === '') out.push('org_unit_id')
  if (start === '') out.push('planned_start')
  if (end === '' || (start !== '' && new Date(end).getTime() <= new Date(start).getTime())) out.push('planned_end')
  if (f.chair_employee_id === '') out.push('chair_employee_id')
  if (f.location_ids.length === 0) out.push('location_ids')
  return out
}

export function formComplete(f: OrderForm): boolean {
  return orderFormProblems(f).length === 0
}

export function reasonOf(err: unknown): string | null {
  const r = (err as { details?: { reason?: unknown } } | null | undefined)?.details?.reason
  return typeof r === 'string' ? r : null
}
export function fieldOf(err: unknown): string | null {
  const f = (err as { details?: { field?: unknown } } | null | undefined)?.details?.field
  return typeof f === 'string' ? f : null
}

/** Message id of a failed call: its own reason, else forbidden / not found / generic. */
/** The ids the shortage refusal carries (REQ-718 P50c): the item and the location, never a balance. */
export function shortageOf(err: unknown): { item: string; location: string } | null {
  if (reasonOf(err) !== 'shortage_exceeds_balance') return null
  const d = (err as { details?: { catalog_item_id?: unknown; location_id?: unknown } }).details
  return typeof d?.catalog_item_id === 'string' && typeof d.location_id === 'string' ? { item: d.catalog_item_id, location: d.location_id } : null
}

export function reasonMessageId(err: unknown): string {
  const status = (err as { status?: unknown } | null | undefined)?.status
  const reason = reasonOf(err)
  if (status === 422 && reason !== null && (COUNT_REASONS as readonly string[]).includes(reason)) return `counts.reason.${reason}`
  if (status === 409 && reason !== null && (COUNT_CONFLICTS as readonly string[]).includes(reason)) return `counts.reason.${reason}`
  // 422 count_not_posted: the posting document is read before it exists
  if (status === 422 && reason === 'count_not_posted') return 'counts.reason.count_not_posted'
  if (status === 403) return 'counts.error.forbidden'
  if (status === 404) return 'counts.error.notFound'
  return 'counts.error.generic'
}

export function statusTone(status: string): StatusTone {
  switch (status) {
    case 'draft': return 'neutral'
    case 'ordered': return 'info'
    case 'counting': return 'current'
    case 'counted': return 'success'
    case 'signed': return 'success'
    case 'posted': return 'success'
    case 'cancelled': return 'danger'
    default: return 'neutral'
  }
}

type Atoms = (permission: string) => boolean
export const canEdit = (o: CountOrder, can: Atoms) => can(STOCK_COUNT_ORDER) && o.status === 'draft'
export const canIssue = canEdit
export const canCancel = (o: CountOrder, can: Atoms) =>
  can(STOCK_COUNT_ORDER) && ['draft', 'ordered', 'counting', 'counted'].includes(o.status)
export const canOpen = (o: CountOrder, can: Atoms) => can(STOCK_COUNT_RECORD) && o.status === 'ordered'
export const canClose = (o: CountOrder, can: Atoms) => can(STOCK_COUNT_RECORD) && o.status === 'counting'
/** The sheet exists from status counting on. */
export const hasSheet = (o: CountOrder) => ['counting', 'counted', 'signed', 'posted'].includes(o.status)

/** Sheet signing: the sheet is closed (counted) and not signed yet. */
export const canSignSheet = (o: CountOrder, can: Atoms) => can(STOCK_COUNT_RECORD) && o.status === 'counted' && !o.sheet_signed_at
export const canIssueDifferences = (o: CountOrder, can: Atoms) =>
  can(STOCK_COUNT_RECORD) && o.status === 'counted' && !!o.sheet_signed_at && !o.differences_document_id
export const canSignDifferences = (o: CountOrder, can: Atoms) =>
  can(STOCK_COUNT_RECORD) && o.status === 'counted' && !!o.differences_document_id && !o.differences_signed_at

/** REQ-718. Post: a signed count that nothing posted yet and that has a differences sheet. The sheet may be empty:
 *  the server then answers 422 no_differences, shown as its own message. */
export const canPost = (o: CountOrder, can: Atoms) =>
  can(STOCK_POST) && o.status === 'signed' && o.posting_state === 'none' && !!o.differences_document_id && o.differences_empty !== true
export const canReverse = (o: CountOrder, can: Atoms) =>
  can(STOCK_REVERSE) && o.posting_state === 'posted' && !o.reverse_pending
/** The posting record: the chair's step once the posting is done (the server checks the chair). */
export const canIssuePostingRecord = (o: CountOrder, can: Atoms) =>
  can(STOCK_COUNT_RECORD) && o.status === 'signed' && !o.posting_document_id &&
  (o.posting_state === 'posted' || (o.posting_state === 'none' && o.differences_empty === true && !o.post_pending))
export const canScan = (o: CountOrder, can: Atoms) => can(STOCK_COUNT_RECORD) && o.status === 'counting'

/** One scan id per accepted Enter; a retry reuses the failed body, so the same id. */
export function newScanId(): string {
  return crypto.randomUUID()
}

/** A request that never got an answer (no HTTP status): the scan may be retried with the same scan_id. */
export const isNetworkFailure = (err: unknown) => (err as { status?: unknown } | null | undefined)?.status === undefined

/** Which paperwork downloads exist: the order from its number/issue, the sheet and the differences by their documents. */
export function paperworkAvailable(o: CountOrder, kind: PaperworkKind): boolean {
  if (kind === 'order') return !!o.document_id || !!o.issued_at
  if (kind === 'sheet') return !!o.sheet_document_id
  return !!o.differences_document_id
}

export type Signer = { id: string; role: 'chair' | 'member' | 'responsible' }
/** Chair, members and the responsible employees of the lines, each once (chair, then members, then responsibles). */
export function requiredSigners(o: CountOrder, lines: { responsible_employee_id?: string | null }[]): Signer[] {
  const seen = new Set<string>()
  const out: Signer[] = []
  const add = (id: string | null | undefined, role: Signer['role']) => {
    if (!id || seen.has(id)) return
    seen.add(id)
    out.push({ id, role })
  }
  add(o.chair_employee_id, 'chair')
  for (const m of o.member_employee_ids) add(m, 'member')
  for (const l of lines) add(l.responsible_employee_id, 'responsible')
  return out
}

/** The file name of a Content-Disposition header (`filename*=UTF-8''x` first, then `filename="x"`), else the fallback. */
export function parseFilename(header: string | null | undefined, fallback: string): string {
  if (!header) return fallback
  const star = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/.exec(header)
  if (star?.[1]) {
    try {
      const v = decodeURIComponent(star[1].trim())
      if (v !== '') return v
    } catch {
      /* fall through to the plain name */
    }
  }
  const plain = /filename\s*=\s*"([^"]+)"/.exec(header) ?? /filename\s*=\s*([^;\s]+)/.exec(header)
  return plain?.[1] ? plain[1] : fallback
}
