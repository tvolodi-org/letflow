/** Pure helpers of the org screens (GH 3609 / REQ-669): the unit tree, move targets, BIN check, error mapping. */
import type { TreeNode } from '@/components/ui/TreeView'
import type { EntityRecord } from '@/types/api'

export const LEGAL_ENTITY = 'org_legal_entity'
export const SITE = 'org_site'
export const UNIT = 'org_unit'
export const POSITION = 'org_position'
export const EMPLOYEE = 'org_employee'

/** Every `reason` the org routes can answer (masters.ex, units.ex, org.ex, router.ex). Each has a message. */
export const ORG_REASONS = [
  'field_invalid',
  'field_not_allowed',
  'bin_taken',
  'legal_entity_in_use',
  'site_in_use',
  'legal_entity_inactive',
  'site_inactive',
  'parent_inactive',
  'unit_inactive',
  'cycle',
  'depth_exceeded',
  'node_has_grants',
  'unit_has_active_staff',
  'position_in_use',
  'position_not_in_unit',
  'position_inactive',
  'employee_inactive',
  'user_not_found',
  'record_payload_invalid',
  'idempotency_key_reuse',
  'request_refused',
] as const

export type OrgReason = (typeof ORG_REASONS)[number]

export function binValid(value: string): boolean {
  return /^\d{12}$/.test(value)
}

export function textOf(record: EntityRecord, key: string): string {
  const v = record.field_values[key]
  return typeof v === 'string' ? v : ''
}

export function isActive(record: EntityRecord): boolean {
  return record.field_values['active'] !== false
}

export interface UnitRow {
  record: EntityRecord
  depth: number
}

/** The loaded units as a flat list in display order: roots first (by code), each followed by its children.
 *  A unit whose parent is not in the loaded set is shown as a root (the list may hold active rows only). */
export function buildUnitTree(rows: EntityRecord[]): UnitRow[] {
  const ids = new Set(rows.map((r) => r.record_id))
  const byCode = (a: EntityRecord, b: EntityRecord) => textOf(a, 'code').localeCompare(textOf(b, 'code'))
  const children = new Map<string, EntityRecord[]>()
  const roots: EntityRecord[] = []
  for (const row of rows) {
    const parent = textOf(row, 'parent')
    if (parent !== '' && ids.has(parent) && parent !== row.record_id) {
      children.set(parent, [...(children.get(parent) ?? []), row])
    } else {
      roots.push(row)
    }
  }
  const out: UnitRow[] = []
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

export function descendantIds(rows: EntityRecord[], id: string): Set<string> {
  const out = new Set<string>()
  const stack = [id]
  while (stack.length > 0) {
    const current = stack.pop() as string
    for (const row of rows) {
      if (textOf(row, 'parent') === current && !out.has(row.record_id)) {
        out.add(row.record_id)
        stack.push(row.record_id)
      }
    }
  }
  return out
}

/** The units a unit may be moved under: active rows except itself and its descendants. */
export function moveTargets(rows: EntityRecord[], id: string): EntityRecord[] {
  const blocked = descendantIds(rows, id)
  return rows.filter((r) => isActive(r) && r.record_id !== id && !blocked.has(r.record_id))
}

export interface OrgErrorInfo {
  status?: number
  reason?: string
  field?: string
  fields?: string[]
}

/** Reads the RFC 9457 body the client keeps in `ApiError.details`. */
export function reasonOf(err: unknown): OrgErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: OrgErrorInfo = {}
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

function isReason(value: string | undefined): value is OrgReason {
  return value !== undefined && (ORG_REASONS as readonly string[]).includes(value)
}

/** The units as picker options in tree order, indented by depth. */
export function unitOptions(rows: EntityRecord[]): { value: string; label: string }[] {
  return buildUnitTree(rows).map(({ record, depth }) => ({
    value: record.record_id,
    label: '  '.repeat(depth) + (textOf(record, 'name') || textOf(record, 'code')),
  }))
}

/** Active positions of one unit (none when no unit is chosen). */
export function positionsOfUnit(positions: EntityRecord[], unitId: string): EntityRecord[] {
  if (unitId === '') return []
  return positions.filter((p) => isActive(p) && textOf(p, 'org_unit_id') === unitId)
}

/** The message id for an error of a write call. `ctx.userLinked`: the request body carried a user id. The router
 *  answers user_not_found as a plain 404 (INV-5), so a 404 on such a request names the user as a possible cause. */
export function errorMessageId(err: unknown, ctx: { userLinked?: boolean } = {}): string {
  const info = reasonOf(err)
  if (info.status === 403) return 'org.error.forbidden'
  if (info.status === 404) return ctx.userLinked ? 'org.error.user_not_found' : 'org.error.notFound'
  if (info.status === 409 || info.reason === 'idempotency_key_reuse') return 'org.error.idempotency_key_reuse'
  if (isReason(info.reason)) return `org.error.${info.reason}`
  if (info.status === 422 && info.reason !== undefined) return 'org.error.unknown'
  return 'org.error.generic'
}

/** The loaded units as nested TreeView nodes (same order and root rule as buildUnitTree). */
export function unitTreeNodes(rows: EntityRecord[]): TreeNode[] {
  const roots: TreeNode[] = []
  const stack: TreeNode[] = []
  for (const { record, depth } of buildUnitTree(rows)) {
    const node: TreeNode = {
      id: record.record_id,
      name: textOf(record, 'name') || textOf(record, 'code'),
      code: textOf(record, 'code'),
      retired: !isActive(record),
      children: [],
    }
    if (depth === 0) roots.push(node)
    else stack[depth - 1].children?.push(node)
    stack[depth] = node
    stack.length = depth + 1
  }
  return roots
}

/** Ids of the nodes that have children (the tree starts fully open). */
export function branchIds(nodes: TreeNode[]): string[] {
  return nodes.flatMap((n) => ((n.children ?? []).length > 0 ? [n.id, ...branchIds(n.children ?? [])] : []))
}

/** "Head office / Finance": names of the ancestors of a unit, root first (empty for a root). */
export function unitPath(rows: EntityRecord[], id: string): string {
  const byId = new Map(rows.map((r) => [r.record_id, r]))
  const names: string[] = []
  const seen = new Set<string>([id])
  let parent = textOf(byId.get(id) ?? ({ field_values: {} } as EntityRecord), 'parent')
  while (parent !== '' && byId.has(parent) && !seen.has(parent)) {
    seen.add(parent)
    const row = byId.get(parent) as EntityRecord
    names.unshift(textOf(row, 'name') || textOf(row, 'code'))
    parent = textOf(row, 'parent')
  }
  return names.join(' / ')
}
