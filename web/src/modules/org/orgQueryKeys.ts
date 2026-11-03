/** Query keys of the org module screens (GH 3609 / REQ-669). Tenant-scoped; the tenant id is only part of
 *  the cache key, never sent in a request. */
export const orgQueryKeys = {
  all: (tenantId: string) => ['org', tenantId] as const,
  list: (tenantId: string, type: string, includeRetired: boolean) =>
    ['org', tenantId, type, includeRetired ? 'all' : 'active'] as const,
}
