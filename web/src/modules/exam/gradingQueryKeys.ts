/** Query keys of the examiner grading screens (REQ-589). Tenant-scoped like the shared keys, so a
 *  tenant switch never serves another tenant's queue from the cache. */
export const gradingQueryKeys = {
  all: (tenantId: string) => ['exam', 'grading', tenantId] as const,
  list: (tenantId: string, params: { exam_id?: string; cursor?: string }) =>
    ['exam', 'grading', tenantId, 'list', params] as const,
  answer: (tenantId: string, sessionId: string, questionId: string) =>
    ['exam', 'grading', tenantId, 'answer', sessionId, questionId] as const,
}

/** The router state the answer screen leaves for the list screen. */
export interface GradingListNavState {
  notice?: 'saved' | 'alreadyGraded'
}
