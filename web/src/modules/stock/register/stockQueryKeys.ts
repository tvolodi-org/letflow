/** Query keys of the stock register screens (GH 3767 / REQ-724). The tenant id is only part of the cache key,
 *  never sent in a request. */
export const stockQueryKeys = {
  balances: (tenantId: string, params: string) => ['stock', tenantId, 'balances', params] as const,
  movements: (tenantId: string, params: string) => ['stock', tenantId, 'movements', params] as const,
  names: (tenantId: string, type: string, ids: string) => ['stock', tenantId, 'names', type, ids] as const,
  options: (tenantId: string, type: string, scope: string) => ['stock', tenantId, 'options', type, scope] as const,
}
