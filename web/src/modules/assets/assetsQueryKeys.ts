/** Query keys of the assets module screens (T-1333 / C13, T-1334 / C14). Tenant-scoped; the tenant id is only part of
 *  the cache key, never sent in a request. Every key starts `['assets', tenantId, ...]`, so the card writes'
 *  `invalidateQueries(all)` reloads the register screens too. */
export const assetsQueryKeys = {
  all: (tenantId: string) => ['assets', tenantId] as const,
  list: (tenantId: string, type: string, scope: string) => ['assets', tenantId, type, scope] as const,
  documents: (tenantId: string, params: string) => ['assets', tenantId, 'documents', params] as const,
  documentsAll: (tenantId: string) => ['assets', tenantId, 'documents'] as const,
  document: (tenantId: string, id: string) => ['assets', tenantId, 'document', id] as const,
  balances: (tenantId: string, params: string) => ['assets', tenantId, 'balances', params] as const,
  balanceHistory: (tenantId: string, params: string) => ['assets', tenantId, 'balance-history', params] as const,
  movements: (tenantId: string, params: string) => ['assets', tenantId, 'movements', params] as const,
  cardLock: (tenantId: string, id: string) => ['assets', tenantId, 'card-lock', id] as const,
  options: (tenantId: string, type: string, scope: string) => ['assets', tenantId, 'options', type, scope] as const,
}
