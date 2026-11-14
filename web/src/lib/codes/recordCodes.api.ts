/** Codes attached to a record. Reuses the codes routes without sending a tenant identifier. */
import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import { fetchAllRecords } from '@/lib/entities/fetchAllRecords'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

export const RECORD_CODE_KINDS = ['barcode', 'qr', 'epc', 'tid'] as const
export type CodeKind = typeof RECORD_CODE_KINDS[number]
export type CodeTarget = 'catalog_item' | 'location_node' | 'catalog_lot'
export const PICK_PAGE_SIZE = 100
const ASSIGN_CHUNK = 200
const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }
const BASE = '/api/v1/modules/codes'
export const recordCodesKeys = {
  all: (tenant: string) => ['codes', tenant] as const,
  record: (tenant: string, type: CodeTarget, id: string) => ['codes', tenant, 'record', type, id] as const,
  pick: (tenant: string, search: string) => ['codes', tenant, 'record-pick', search] as const,
}
export const recordCodesApi = {
  receive: (value: string, kind: CodeKind, key: string) => client.post<unknown>(`${BASE}/receive`, { entries: [{ value, kind }], idempotency_key: key }),
  assign: (id: string, type: CodeTarget, target: string, key: string) => client.post<unknown>(`${BASE}/${encodeURIComponent(id)}/assign`, { target_type: type, target_id: target, idempotency_key: key }),
  release: (id: string, key: string) => client.post<unknown>(`${BASE}/${encodeURIComponent(id)}/release`, { idempotency_key: key }),
}
const text = (r: EntityRecord, field: string) => typeof r.field_values[field] === 'string' ? r.field_values[field] as string : ''
export interface RecordCode { codeId: string; value: string; kind: string; status: string; assignedAt: string }
export async function fetchRecordCodes(type: CodeTarget, id: string) {
  const assignments = await fetchAllRecords('code_assignment', [DELETED_FALSE,
    { field: 'target_type', op: 'eq', value: type }, { field: 'target_id', op: 'eq', value: id },
    { field: 'released_at', op: 'is_null' }], 'assigned_at')
  const ids = [...new Set(assignments.map((r) => text(r, 'code_id')))]
  const tags = new Map<string, EntityRecord>()
  let truncated = !!assignments.truncated
  for (let i = 0; i < ids.length; i += ASSIGN_CHUNK) {
    const part = await fetchAllRecords('code_tag', [DELETED_FALSE, { field: 'record_id', op: 'in', value: ids.slice(i, i + ASSIGN_CHUNK) }], 'value')
    truncated ||= !!part.truncated
    part.forEach((r) => tags.set(r.record_id, r))
  }
  const rows: RecordCode[] = assignments.flatMap((a) => {
    const tag = tags.get(text(a, 'code_id'))
    return tag ? [{ codeId: tag.record_id, value: text(tag, 'value'), kind: text(tag, 'kind'), status: text(tag, 'status'), assignedAt: text(a, 'assigned_at') }] : []
  })
  rows.sort((a, b) => a.value < b.value ? -1 : a.value > b.value ? 1 : 0)
  return { rows, truncated }
}
export async function fetchPickPage(search: string) {
  const result = await entitiesApi.queryRecords('code_tag', { filters: [DELETED_FALSE,
    { field: 'status', op: 'eq', value: 'not_assigned' }, ...(search ? [{ field: 'value', op: 'eq' as const, value: search }] : [])],
  sort: [{ field: 'value', dir: 'asc' }], page_size: PICK_PAGE_SIZE })
  return { items: result.items, more: !!result.next_cursor }
}
export function reasonOf(err: unknown) {
  const e = err as { status?: number; details?: { reason?: string; entry_reason?: string } } | null
  return { status: e?.status, reason: e?.details?.reason, entryReason: e?.details?.entry_reason }
}
export function errorMessageKey(err: unknown) {
  const { status, reason, entryReason } = reasonOf(err)
  if (status === 404) return 'notFound'
  if (status === 403) return 'forbidden'
  if (status === 409 || reason === 'idempotency_key_reuse') return 'retry'
  const keys: Record<string, string> = { value_taken: 'valueTaken', value_invalid: 'valueInvalid', kind_invalid: 'kindInvalid', code_assigned: 'codeAssigned', code_retired: 'codeRetired', code_not_assigned: 'codeNotAssigned', target_inactive: 'targetInactive', assignment_conflict: 'conflict' }
  return keys[reason === 'entry_invalid' ? entryReason ?? '' : reason ?? ''] ?? 'generic'
}
