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
}

const MAX_PAGES = 50

/** Loads every record of a type matching the filters, following the cursor (max page size 200). */
export async function fetchAllRecords(
  type: string,
  filters: EntityQueryFilterClause[],
  sortField = 'code',
): Promise<EntityRecord[]> {
  const out: EntityRecord[] = []
  let cursor: string | undefined
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await entitiesApi.queryRecords(type, {
      filters,
      sort: [{ field: sortField, dir: 'asc' }],
      page_size: 200,
      ...(cursor ? { cursor } : {}),
    })
    out.push(...res.items)
    if (!res.next_cursor || res.next_cursor === cursor) break
    cursor = res.next_cursor
  }
  return out
}
