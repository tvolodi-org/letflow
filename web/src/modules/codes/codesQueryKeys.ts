/** Query keys of the codes module screen (GH 3606 / REQ-672). Tenant-scoped; the tenant id is only part of
 *  the cache key, never sent in a request. */
export const codesQueryKeys = {
  all: (tenantId: string) => ['codes', tenantId] as const,
  list: (tenantId: string, type: string, scope: string) => ['codes', tenantId, type, scope] as const,
}
