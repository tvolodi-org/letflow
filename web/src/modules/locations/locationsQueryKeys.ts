/** Query keys of the locations module screens (GH 3607 / REQ-671). Tenant-scoped; the tenant id is only part of
 *  the cache key, never sent in a request. */
export const locationsQueryKeys = {
  all: (tenantId: string) => ['locations', tenantId] as const,
  list: (tenantId: string, type: string, scope: string) => ['locations', tenantId, type, scope] as const,
}
