/** Query keys of the assets module screens (T-1333 / C13). Tenant-scoped; the tenant id is only part of the cache
 *  key, never sent in a request. */
export const assetsQueryKeys = {
  all: (tenantId: string) => ['assets', tenantId] as const,
  list: (tenantId: string, type: string, scope: string) => ['assets', tenantId, type, scope] as const,
}
