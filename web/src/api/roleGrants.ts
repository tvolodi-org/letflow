/** T-1570 (D-097) — the per-tenant storekeeper grant for assets: `GET` / `PUT /api/v1/tenant/role-grants`
 *  (`lib/letflow/routers/tenant_role_grants.ex`). The PUT replaces the whole list; send the full list wanted. */
import { client } from './client'

export type StorekeeperAssetGrant = 'AssetsRead' | 'AssetsPost'

export interface RoleGrants {
  storekeeper: StorekeeperAssetGrant[]
  grantable: { storekeeper: StorekeeperAssetGrant[] }
}

export const roleGrantsApi = {
  get: () => client.get<RoleGrants>('/api/v1/tenant/role-grants'),
  putStorekeeper: (storekeeper: StorekeeperAssetGrant[]) =>
    client.put<RoleGrants>('/api/v1/tenant/role-grants', { storekeeper }),
}
