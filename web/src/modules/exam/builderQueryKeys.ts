/** Query keys of the exam builder screens (GH 3355 / REQ-602). Tenant-scoped, like gradingQueryKeys. */
export const builderQueryKeys = {
  list: (tenantId: string) => ['exam', 'builder', tenantId, 'list'] as const,
  exam: (tenantId: string, examId: string) => ['exam', 'builder', tenantId, 'exam', examId] as const,
}
