/** Query keys of the maintenance module screens (GH 4802 / REQ-898). Tenant-scoped; the tenant id is only part of
 *  the cache key, never sent in a request. */
export const maintenanceQueryKeys = {
  all: (tenantId: string) => ['maintenance', tenantId] as const,
  list: (tenantId: string, status: string) => ['maintenance', tenantId, 'requests', status] as const,
  request: (tenantId: string, id: string) => ['maintenance', tenantId, 'request', id] as const,
  orders: (tenantId: string, status: string, card: string) => ['maintenance', tenantId, 'orders', status, card] as const,
  order: (tenantId: string, id: string) => ['maintenance', tenantId, 'order', id] as const,
  users: (tenantId: string) => ['maintenance', tenantId, 'users'] as const,
  myOrders: (tenantId: string) => ['maintenance', tenantId, 'my-orders'] as const,
  photos: (tenantId: string, id: string) => ['maintenance', tenantId, 'photos', id] as const,
}
