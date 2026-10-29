/** web/src/modules/exam/examRoutes.tsx — ISS-0844
 *
 *  The exam module's route objects. Imported by exam/index.ts and registered
 *  via registry.ts. Lives inside web/src/modules/exam/ so it counts as module
 *  code (0039 D3), not core code.
 *
 *  No guard wrapper here — registry.ts wraps these in ModuleGuard when
 *  building REGISTERED_MODULE_ROUTE_OBJECTS.
 */
import type { ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import ExamListPage from './ExamListPage'
import ExamSessionPage from './ExamSessionPage'
import ExamSessionResultPage from './ExamSessionResultPage'
import ExamMyResultsPage from './ExamMyResultsPage'
import BilimBagaAdminPage from './BilimBagaAdminPage'
import BilimBagaEntityRoute from './BilimBagaEntityRoute'
import ExamGradingListPage from './ExamGradingListPage'
import ExamGradingAnswerPage from './ExamGradingAnswerPage'
import ExamBuilderPage from './ExamBuilderPage'
import ExamBuilderListPage from './ExamBuilderListPage'
import QuestionBankPage from './QuestionBankPage'
import QuestionEditorPage from './QuestionEditorPage'
import { EXAM_AUTHORING_WRITE } from './bilimbagaWrites'
import { RequirePermission } from '@/auth/access'

/** REQ-589: the examiner screens need ExamGradingRead (the shell's forbidden page otherwise). */
function gradingGuard(page: ReactNode) {
  return <RequirePermission permission="ExamGradingRead">{page}</RequirePermission>
}

/** GH 3355 / REQ-602: the exam builder needs ExamAuthoringWrite (the shell's forbidden page otherwise). */
function builderGuard(page: ReactNode) {
  return <RequirePermission permission={EXAM_AUTHORING_WRITE}>{page}</RequirePermission>
}

export const examRouteObjects: RouteObject[] = [
  {
    // GH 3423 / REQ-612: the question bank and editor. No permission wrapper: a user without
    // ExamAuthoringWrite sees the pages with the write actions hidden.
    path: 'admin/questions',
    children: [
      { index: true, element: <QuestionBankPage /> },
      { path: 'new', element: <QuestionEditorPage /> },
      { path: ':recordId/edit', element: <QuestionEditorPage /> },
    ],
  },
  {
    path: 'exam',
    children: [
      { index: true, element: <ExamListPage /> },
      { path: ':examId/session', element: <ExamSessionPage /> },
      { path: 'results', element: <ExamMyResultsPage /> },
      { path: 'sessions/:sessionId/result', element: <ExamSessionResultPage /> },
      { path: 'grading', element: gradingGuard(<ExamGradingListPage />) },
      { path: 'grading/:sessionId/:questionId', element: gradingGuard(<ExamGradingAnswerPage />) },
    ],
  },
  {
    path: 'admin/bilimbaga',
    children: [
      { index: true, element: <BilimBagaAdminPage /> },
      { path: 'exam-builder', element: builderGuard(<ExamBuilderListPage />) },
      { path: 'exam-builder/:examId', element: builderGuard(<ExamBuilderPage />) },
      { path: ':entityType', element: <BilimBagaEntityRoute /> },
    ],
  },
]
