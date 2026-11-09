/** assets.api — T-1333 / C13. Calls of the assets module routes (REQ-750). Each write carries the idempotency key
 *  in the body and exactly the keys the route accepts; no call sends a tenant identifier. */
import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

const BASE = '/api/v1/modules/assets'

export const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }
export const ACTIVE_TRUE: EntityQueryFilterClause = { field: 'active', op: 'eq', value: true }

/** Body of a create or an update: strings only (decimals and dates stay strings); on update `null` removes an
 *  optional key. */
export type CardBody = Record<string, string | null>

const seg = (id: string) => encodeURIComponent(id)

export const assetsApi = {
  createCard: (b: CardBody, key: string) => client.post<EntityRecord>(`${BASE}/cards`, { ...b, idempotency_key: key }),
  updateCard: (id: string, b: CardBody, key: string) =>
    client.patch<EntityRecord>(`${BASE}/cards/${seg(id)}`, { ...b, idempotency_key: key }),
  cardLock: (id: string) => client.get<{ posted: boolean }>(`${BASE}/cards/${seg(id)}/lock`),
  retireCard: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/cards/${seg(id)}/retire`, { idempotency_key: key }),
}

const MAX_PAGES = 50

/** Loads every record of a type matching the filters, following the cursor (max page size 200). */
export async function fetchAllRecords(
  type: string,
  filters: EntityQueryFilterClause[],
  sortField = 'inventory_number',
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
