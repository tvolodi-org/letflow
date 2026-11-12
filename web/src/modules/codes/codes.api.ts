/** codes.api — GH 3606 / REQ-672. Calls of the codes module routes (REQ-667). Each write carries the idempotency
 *  key in the body and exactly the keys the route accepts; no call sends a tenant identifier. */
import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

const BASE = '/api/v1/modules/codes'

export const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }

export interface ReceiveEntry { value: string; kind: string }
export interface AssignBody { target_type: string; target_id: string }

const seg = (id: string) => encodeURIComponent(id)

export const codesApi = {
  receive: (entries: ReceiveEntry[], key: string) =>
    client.post<unknown>(`${BASE}/receive`, { entries, idempotency_key: key }),
  assign: (id: string, b: AssignBody, key: string) =>
    client.post<unknown>(`${BASE}/${seg(id)}/assign`, { ...b, idempotency_key: key }),
  release: (id: string, key: string) => client.post<unknown>(`${BASE}/${seg(id)}/release`, { idempotency_key: key }),
  retire: (id: string, key: string) => client.post<unknown>(`${BASE}/${seg(id)}/retire`, { idempotency_key: key }),
  changeValue: (id: string, value: string, key: string) =>
    client.post<unknown>(`${BASE}/${seg(id)}/value`, { value, idempotency_key: key }),
  /** E3a label sheet (REQ-779): the body is exactly `code_ids` (the route takes no idempotency key and no tenant). */
  labels: (codeIds: string[]) => client.postBlob(`${BASE}/labels`, { code_ids: codeIds }),
}

/** The one "load everything" loop (cap and `truncated` flag included) is shared: lib/entities/fetchAllRecords. */
export { fetchAllRecords } from '@/lib/entities/fetchAllRecords'

/** Codes per request of the code list and of each "Load more" (T-1802). */
export const CODE_PAGE_SIZE = 100

export interface CodesPage {
  items: EntityRecord[]
  next_cursor: string | null
}

/** One page of records of a type, ascending by `sortField`. */
export async function fetchCodesPage(
  type: string,
  filters: EntityQueryFilterClause[],
  cursor?: string,
  sortField = 'value',
  pageSize = CODE_PAGE_SIZE,
): Promise<CodesPage> {
  const res = await entitiesApi.queryRecords(type, {
    filters,
    sort: [{ field: sortField, dir: 'asc' }],
    page_size: pageSize,
    ...(cursor ? { cursor } : {}),
  })
  return { items: res.items, next_cursor: res.next_cursor ?? null }
}
