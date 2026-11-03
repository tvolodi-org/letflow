/** catalogItems.api — GH 3605 / REQ-673. Calls of the catalog_items module routes (REQ-668).
 *  Each write carries the idempotency key in the body and exactly the keys the route accepts;
 *  no call sends a tenant identifier. */
import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

const BASE = '/api/v1/modules/catalog_items'

export const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }

export interface CreateLotBody {
  item_id: string
  code: string
  producer?: string
  mark?: string
  expiry_date?: string
}

export interface EditLotBody {
  producer: string | null
  mark: string | null
  expiry_date: string | null
}

const seg = (id: string) => encodeURIComponent(id)

export const catalogItemsApi = {
  createLot: (body: CreateLotBody, key: string) =>
    client.post<unknown>(`${BASE}/lots`, { ...body, idempotency_key: key }),
  updateLot: (id: string, body: EditLotBody, key: string) =>
    client.patch<unknown>(`${BASE}/lots/${seg(id)}`, { ...body, idempotency_key: key }),
  retireLot: (id: string, key: string) =>
    client.post<unknown>(`${BASE}/lots/${seg(id)}/retire`, { idempotency_key: key }),
}

const MAX_PAGES = 50

/** Loads every record of a type matching the filters, following the cursor (max page size 200). */
export async function fetchAllRecords(
  type: string,
  filters: EntityQueryFilterClause[],
  sortField = 'code',
  sortDir: 'asc' | 'desc' = 'asc',
): Promise<EntityRecord[]> {
  const out: EntityRecord[] = []
  let cursor: string | undefined
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await entitiesApi.queryRecords(type, {
      filters,
      sort: [{ field: sortField, dir: sortDir }],
      page_size: 200,
      ...(cursor ? { cursor } : {}),
    })
    out.push(...res.items)
    if (!res.next_cursor || res.next_cursor === cursor) break
    cursor = res.next_cursor
  }
  return out
}
