/** locations.api — GH 3607 / REQ-671. Calls of the locations module routes (REQ-666). Each write carries the
 *  idempotency key in the body and exactly the keys the route accepts; no call sends a tenant identifier. */
import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

const BASE = '/api/v1/modules/locations'

export const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }
export const ACTIVE_TRUE: EntityQueryFilterClause = { field: 'active', op: 'eq', value: true }

/** Optional keys are left out, never sent empty. `address_pattern: 'segments'` composes the address from the
 *  segments of the path (then no `address` key). */
export interface NodeCreate {
  code: string
  name: string
  node_kind: string
  parent_id?: string
  segment?: string
  location_type?: string
  address?: string
  address_pattern?: 'segments'
}
/** `null` removes an optional key. */
export interface NodeUpdate {
  name: string
  node_kind: string
  segment: string | null
  address: string | null
  location_type: string | null
}
/** Both keys are required by the link routes. */
export interface LinkBody { org_unit_id: string; location_id: string }

const seg = (id: string) => encodeURIComponent(id)

export const locationsApi = {
  createNode: (b: NodeCreate, key: string) => client.post<EntityRecord>(`${BASE}/nodes`, { ...b, idempotency_key: key }),
  updateNode: (id: string, b: NodeUpdate, key: string) =>
    client.patch<EntityRecord>(`${BASE}/nodes/${seg(id)}`, { ...b, idempotency_key: key }),
  moveNode: (id: string, parentId: string | null, key: string) =>
    client.post<EntityRecord>(`${BASE}/nodes/${seg(id)}/move`, { parent_id: parentId, idempotency_key: key }),
  retireNode: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/nodes/${seg(id)}/retire`, { idempotency_key: key }),
  linkUnit: (b: LinkBody, key: string) => client.post<EntityRecord>(`${BASE}/links`, { ...b, idempotency_key: key }),
  unlinkUnit: (b: LinkBody, key: string) =>
    client.post<EntityRecord>(`${BASE}/links/retire`, { ...b, idempotency_key: key }),
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
