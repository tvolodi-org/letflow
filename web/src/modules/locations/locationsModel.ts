/** Pure helpers of the locations screens (GH 3607 / REQ-671): the trees, move targets, error mapping. */
import type { EntityRecord } from '@/types/api'

export const LOCATION_NODE = 'location_node'
export const LINK = 'location_org_unit_link'
export const ORG_UNIT = 'org_unit'

export const LOCATION_TYPES = ['receiving', 'pick', 'ship', 'reject', 'quarantine', 'custody', 'outdoor'] as const

/** Every `reason` the locations routes can answer (router.ex, tree.ex). Each has a message. */
export const LOCATION_REASONS = [
  'field_invalid',
  'field_not_allowed',
  'record_payload_invalid',
  'cycle',
  'has_active_descendants',
  'parent_inactive',
  'unit_inactive',
  'location_inactive',
  'idempotency_key_reuse',
  'request_refused',
] as const

export type LocationReason = (typeof LOCATION_REASONS)[number]

export function textOf(record: EntityRecord, key: string): string {
  const v = record.field_values[key]
  return typeof v === 'string' ? v : ''
}

export function isActive(record: EntityRecord): boolean {
  return record.field_values['active'] !== false
}

export interface TreeRow {
  record: EntityRecord
  depth: number
}

/** Rows in display order: roots first (by code), each followed by its children. A row whose parent is not in the
 *  loaded set is shown as a root. `parentKey` is the field holding the parent id. Cycle-safe. */
export function buildTree(rows: EntityRecord[], parentKey: string): TreeRow[] {
  const ids = new Set(rows.map((r) => r.record_id))
  const byCode = (a: EntityRecord, b: EntityRecord) => textOf(a, 'code').localeCompare(textOf(b, 'code'))
  const children = new Map<string, EntityRecord[]>()
  const roots: EntityRecord[] = []
  for (const row of rows) {
    const parent = textOf(row, parentKey)
    if (parent !== '' && ids.has(parent) && parent !== row.record_id) {
      children.set(parent, [...(children.get(parent) ?? []), row])
    } else {
      roots.push(row)
    }
  }
  const out: TreeRow[] = []
  const seen = new Set<string>()
  const walk = (row: EntityRecord, depth: number) => {
    if (seen.has(row.record_id)) return
    seen.add(row.record_id)
    out.push({ record: row, depth })
    for (const child of (children.get(row.record_id) ?? []).sort(byCode)) walk(child, depth + 1)
  }
  for (const root of roots.sort(byCode)) walk(root, 0)
  return out
}

export function descendantIds(rows: EntityRecord[], id: string, parentKey = 'parent_id'): Set<string> {
  const out = new Set<string>()
  const stack = [id]
  while (stack.length > 0) {
    const current = stack.pop() as string
    for (const row of rows) {
      if (textOf(row, parentKey) === current && !out.has(row.record_id)) {
        out.add(row.record_id)
        stack.push(row.record_id)
      }
    }
  }
  return out
}

/** The nodes a node may be moved under: active rows except itself and its descendants. */
export function moveTargets(rows: EntityRecord[], id: string): EntityRecord[] {
  const blocked = descendantIds(rows, id)
  return rows.filter((r) => isActive(r) && r.record_id !== id && !blocked.has(r.record_id))
}

/** The distinct, non-empty node kinds used in the loaded nodes, sorted. */
export function kindSuggestions(rows: EntityRecord[]): string[] {
  return [...new Set(rows.map((r) => textOf(r, 'node_kind')).filter((k) => k !== ''))].sort()
}

/** Picker options in tree order, indented by depth; `activeOnly` leaves retired rows out. */
export function treeOptions(
  rows: EntityRecord[],
  parentKey: string,
  activeOnly = true,
): { value: string; label: string }[] {
  return buildTree(rows, parentKey)
    .filter(({ record }) => !activeOnly || isActive(record))
    .map(({ record, depth }) => ({
      value: record.record_id,
      label: '  '.repeat(depth) + (textOf(record, 'name') || textOf(record, 'code')),
    }))
}

export interface LocationsErrorInfo {
  status?: number
  reason?: string
  field?: string
  fields?: string[]
}

/** Reads the RFC 9457 body the client keeps in `ApiError.details`. */
export function reasonOf(err: unknown): LocationsErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: LocationsErrorInfo = {}
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

function isReason(value: string | undefined): value is LocationReason {
  return value !== undefined && (LOCATION_REASONS as readonly string[]).includes(value)
}

/** The message id for an error of a write call. `ctx.link`: the request was a link or unlink; the router answers
 *  unit, location and link not found alike as a plain 404 (INV-5), so the text names all three. */
export function errorMessageId(err: unknown, ctx: { link?: boolean } = {}): string {
  const info = reasonOf(err)
  if (info.status === 403) return 'locations.error.forbidden'
  if (info.status === 404) return ctx.link ? 'locations.error.link_not_found' : 'locations.error.notFound'
  if (info.status === 409 || info.reason === 'idempotency_key_reuse') return 'locations.error.idempotency_key_reuse'
  if (isReason(info.reason)) return `locations.error.${info.reason}`
  if (info.status === 422 && info.reason !== undefined) return 'locations.error.unknown'
  return 'locations.error.generic'
}
