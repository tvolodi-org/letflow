/** Query keys of the catalog_items module screen (GH 3605 / REQ-673). Tenant-scoped; the tenant id is only part of
 *  the cache key, never sent in a request. */
export const catalogItemsQueryKeys = {
  all: (tenantId: string) => ['catalog_items', tenantId] as const,
  list: (tenantId: string, type: string, scope: string) => ['catalog_items', tenantId, type, scope] as const,
}
