/** Query keys of the exam builder screens (GH 3355 / REQ-602). Tenant-scoped, like gradingQueryKeys. */
export const builderQueryKeys = {
  list: (tenantId: string) => ['exam', 'builder', tenantId, 'list'] as const,
  exam: (tenantId: string, examId: string) => ['exam', 'builder', tenantId, 'exam', examId] as const,
}

/** Query keys of the question bank and editor (GH 3423 / REQ-612). Tenant-scoped. */
export const questionQueryKeys = {
  bank: (tenantId: string, locale: string, term: string, cursor: string) =>
    ['exam', 'questions', tenantId, 'bank', locale, term, cursor] as const,
  categories: (tenantId: string) => ['exam', 'questions', tenantId, 'categories'] as const,
  edit: (tenantId: string, recordId: string) => ['exam', 'questions', tenantId, 'edit', recordId] as const,
}
