/** catalogItems.api — GH 3605 / REQ-673. Calls of the catalog_items module routes (REQ-668).
 *  Each write carries the idempotency key in the body and exactly the keys the route accepts;
 *  no call sends a tenant identifier. */
import { client } from '@/api/client'
import type { EntityQueryFilterClause } from '@/types/api'

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

export { fetchAllRecords } from '@/lib/entities/fetchAllRecords'
