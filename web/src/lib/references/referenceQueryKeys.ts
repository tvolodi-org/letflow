/** Query keys of the shared reference labels (T-1378). The tenant id is only part of the cache key. */
export const referenceQueryKeys = {
  labels: (tenantId: string, type: string, ids: string) => ['reference', tenantId, 'labels', type, ids] as const,
  taskSubject: (tenantId: string, instanceId: string) => ['reference', tenantId, 'task-subject', instanceId] as const,
}
