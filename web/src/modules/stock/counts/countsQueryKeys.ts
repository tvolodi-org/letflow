/** Query keys of the count screens (GH 3735 / REQ-702). The tenant id is only part of the cache key. */
export const countsQueryKeys = {
  all: (tenantId: string) => ['stock', tenantId, 'counts'] as const,
  list: (tenantId: string, params: string) => ['stock', tenantId, 'counts', 'list', params] as const,
  detail: (tenantId: string, id: string) => ['stock', tenantId, 'counts', 'detail', id] as const,
  lines: (tenantId: string, id: string) => ['stock', tenantId, 'counts', 'lines', id] as const,
  entries: (tenantId: string, id: string) => ['stock', tenantId, 'counts', 'entries', id] as const,
  differences: (tenantId: string, id: string) => ['stock', tenantId, 'counts', 'differences', id] as const,
  signatures: (tenantId: string, id: string) => ['stock', tenantId, 'counts', 'signatures', id] as const,
}
