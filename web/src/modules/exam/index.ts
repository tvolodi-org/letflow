/** web/src/modules/exam/index.ts — REQ-412 / ISS-0844
 *
 *  Exports the exam module's ModuleDefinition for registration in
 *  web/src/modules/registry.ts. The definition provides:
 *
 *  - Route objects (actual React Router RouteObjects, no guard wrapper —
 *    registry.ts wraps them in ModuleGuard when building the router's list)
 *  - Three nav items: /exam for whoever may start an exam session, /exam/grading for
 *    whoever holds ExamGradingRead (REQ-589), /admin/bilimbaga for
 *    whoever may write entity records (the question bank is an entity CRUD page; REQ-343 AC5)
 *
 *  SPA paths (unchanged per ISS-0844 / REQ-412):
 *    exam
 *    exam/:examId/session
 *    exam/sessions/:sessionId/result
 *    exam/grading (REQ-589)
 *    exam/grading/:sessionId/:questionId (REQ-589)
 *    admin/bilimbaga
 *    admin/bilimbaga/:entityType
 */
import type { ModuleDefinition } from '@/modules/types'
import { P } from '@/auth/access/types'
import { examRouteObjects } from './examRoutes'

export const examModuleDefinition: ModuleDefinition = {
  id: 'exam',
  depends_on: [],
  routeObjects: examRouteObjects,
  navItems: [
    { to: '/exam', label: 'Exams', permission: 'ExamSessionStart' },
    { to: '/admin/bilimbaga', label: 'Question Bank', permission: P.EntitiesRecordsWrite },
    { to: '/exam/grading', label: 'Grading', permission: 'ExamGradingRead' },
  ],
}
