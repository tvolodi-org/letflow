/** org.api — GH 3609 / REQ-669. Calls of the org module routes (REQ-665). Each write carries the idempotency key
 *  in the body and exactly the keys the route accepts; no call sends a tenant identifier. */
import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'

const BASE = '/api/v1/modules/org'

export const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }
export const ACTIVE_TRUE: EntityQueryFilterClause = { field: 'active', op: 'eq', value: true }

export interface LegalEntityCreate { code: string; name: string; bin: string }
export interface LegalEntityUpdate { name: string; bin: string }
export interface SiteCreate { code: string; name: string; legal_entity_id: string }
export interface SiteUpdate { name: string; legal_entity_id: string }
/** `parent` is the parent unit's id; absent for a root. */
export interface UnitCreate { code: string; name: string; legal_entity_id: string; site_id: string; parent?: string }
export interface UnitUpdate { name: string; legal_entity_id: string; site_id: string }
/** Optional keys are left out, never sent empty. */
export interface PositionCreate { code: string; name: string; org_unit_id: string }
export interface PositionUpdate { name: string }
export interface EmployeeCreate { code: string; full_name: string; org_unit_id: string; position_id?: string; user_id?: string }
/** `user_id: null` removes the link. */
export interface EmployeeUpdate { full_name: string; user_id: string | null }
/** Both keys are required by the route; `position_id: null` means no position. */
export interface EmployeeTransfer { org_unit_id: string; position_id: string | null }

const seg = (id: string) => encodeURIComponent(id)

export const orgApi = {
  createLegalEntity: (b: LegalEntityCreate, key: string) =>
    client.post<EntityRecord>(`${BASE}/legal-entities`, { ...b, idempotency_key: key }),
  updateLegalEntity: (id: string, b: LegalEntityUpdate, key: string) =>
    client.patch<EntityRecord>(`${BASE}/legal-entities/${seg(id)}`, { ...b, idempotency_key: key }),
  retireLegalEntity: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/legal-entities/${seg(id)}/retire`, { idempotency_key: key }),
  createSite: (b: SiteCreate, key: string) => client.post<EntityRecord>(`${BASE}/sites`, { ...b, idempotency_key: key }),
  updateSite: (id: string, b: SiteUpdate, key: string) =>
    client.patch<EntityRecord>(`${BASE}/sites/${seg(id)}`, { ...b, idempotency_key: key }),
  retireSite: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/sites/${seg(id)}/retire`, { idempotency_key: key }),
  createUnit: (b: UnitCreate, key: string) => client.post<EntityRecord>(`${BASE}/units`, { ...b, idempotency_key: key }),
  updateUnit: (id: string, b: UnitUpdate, key: string) =>
    client.patch<EntityRecord>(`${BASE}/units/${seg(id)}`, { ...b, idempotency_key: key }),
  moveUnit: (id: string, parentId: string | null, key: string) =>
    client.post<EntityRecord>(`${BASE}/units/${seg(id)}/move`, { parent_id: parentId, idempotency_key: key }),
  retireUnit: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/units/${seg(id)}/retire`, { idempotency_key: key }),
  createPosition: (b: PositionCreate, key: string) =>
    client.post<EntityRecord>(`${BASE}/positions`, { ...b, idempotency_key: key }),
  updatePosition: (id: string, b: PositionUpdate, key: string) =>
    client.patch<EntityRecord>(`${BASE}/positions/${seg(id)}`, { ...b, idempotency_key: key }),
  retirePosition: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/positions/${seg(id)}/retire`, { idempotency_key: key }),
  createEmployee: (b: EmployeeCreate, key: string) =>
    client.post<EntityRecord>(`${BASE}/employees`, { ...b, idempotency_key: key }),
  updateEmployee: (id: string, b: EmployeeUpdate, key: string) =>
    client.patch<EntityRecord>(`${BASE}/employees/${seg(id)}`, { ...b, idempotency_key: key }),
  transferEmployee: (id: string, b: EmployeeTransfer, key: string) =>
    client.post<EntityRecord>(`${BASE}/employees/${seg(id)}/transfer`, { ...b, idempotency_key: key }),
  retireEmployee: (id: string, key: string) =>
    client.post<EntityRecord>(`${BASE}/employees/${seg(id)}/retire`, { idempotency_key: key }),
}

const MAX_PAGES = 50

/** Loads every record of a type matching the filters, following the cursor (max page size 200). */
export async function fetchAllRecords(type: string, filters: EntityQueryFilterClause[]): Promise<EntityRecord[]> {
  const out: EntityRecord[] = []
  let cursor: string | undefined
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await entitiesApi.queryRecords(type, {
      filters,
      sort: [{ field: 'code', dir: 'asc' }],
      page_size: 200,
      ...(cursor ? { cursor } : {}),
    })
    out.push(...res.items)
    if (!res.next_cursor || res.next_cursor === cursor) break
    cursor = res.next_cursor
  }
  return out
}
