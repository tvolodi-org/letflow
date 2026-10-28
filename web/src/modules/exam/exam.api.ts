/** exam session API client — REQ-338
 *
 *  Follows web/src/api/definitions.ts's own shape: a plain object of named
 *  functions wrapping client.get/post/put, typed against exam.types.ts.
 *  Wraps REQ-335's ACTUAL route table
 *  (lib/letflow/routers/exam_sessions.ex's own moduledoc "Route table"),
 *  re-verified directly against that router's source, not the speculative
 *  paths this requirement's own description guessed at before REQ-335 landed.
 *  REQ-410 moved the router to /api/v1/modules/exam/exam-sessions:
 *
 *    | Handler             | Method/path                                               |
 *    |---------------------|-----------------------------------------------------------|
 *    | start_session        | POST   /modules/exam/exam-sessions                       |
 *    | get_session_state    | GET    /modules/exam/exam-sessions/:id                    |
 *    | autosave_answer      | PUT    /modules/exam/exam-sessions/:id/answers/:q_id      |
 *    | submit_session       | POST   /modules/exam/exam-sessions/:id/submit             |
 *    | report_event         | POST   /modules/exam/exam-sessions/:id/events             |
 *
 *  Mounted at `/modules/exam/exam-sessions` under the authenticated `/api/v1`
 *  forward (REQ-410's naming), so every path below is
 *  `/api/v1/modules/exam/exam-sessions...`.
 *
 *  Five named operations, matching this requirement's own description
 *  exactly (startSession, saveAnswer, submitSession, getSessionState,
 *  reportEvent) — REQ-335's real shapes did NOT differ from that description
 *  once its real routes were read (only the description's OWN speculative
 *  path guesses were wrong; the operation list held).
 *
 *  ISS-0718: `listAvailableExams` below replaces this requirement's original
 *  `queryExamRecords` call onto the generic `POST /entities/query` route.
 *  candidate role cannot reach that route — `:EntitiesQuery` is outside
 *  candidate role's ISS-0646 closed permission set, so every candidate role call was a
 *  guaranteed 403. `listAvailableExams` instead calls the new, dedicated
 *  `GET /modules/exam/exam-sessions/available` route (added by ISS-0718's fix, gated on
 *  candidate role's existing `:ExamSessionStart` permission — no new grant), which
 *  hardcodes `entity_type: "exam"` and `status: active` server-side rather
 *  than accepting caller-supplied filters. See
 *  `lib/letflow/design/iss0718-candidate-exam-list-route.md` for the full
 *  design. `ExamRecord`/`ExamRecordsPage` below are unchanged — the new
 *  route returns the identical response shape the old one did.
 */

import { client } from '@/api/client'
import { entitiesApi } from '@/api/entities'
import type { EntityQueryFilterClause, EntityQuerySortClause, EntityRecord } from '@/types/api'
import type {
  AntiCheatSignalOutcome,
  AntiCheatSignalType,
  ExamAutosaveResponse,
  ExamSessionStateResponse,
  ExamSubmissionOutcome,
  SaveAnswerBody,
} from './exam.types'

const BASE = '/api/v1/modules/exam/exam-sessions'

/** One `exam` record as returned by `GET /modules/exam/exam-sessions/available`
 *  (identical shape to the old `POST /entities/query` route's
 *  `entity_row_map/1`-style rendering — ISS-0718 §1.4). */
export interface ExamRecord {
  record_id: string
  field_values: Record<string, unknown>
  deleted: boolean
  entity_def_version: string
  last_event_global_seq: number
}

/** `GET /modules/exam/exam-sessions/available`'s response body. */
export interface ExamRecordsPage {
  items: ExamRecord[]
  next_cursor: string | null
}

export const examApi = {
  /** `POST /modules/exam/exam-sessions` — `candidate_id` is always the caller's own
   *  identity server-side; only `exam_id` is supplied here. */
  startSession: (examId: string) =>
    client.post<ExamSessionStateResponse>(BASE, { exam_id: examId }),

  /** `GET /modules/exam/exam-sessions/:id`. */
  getSessionState: (sessionId: string) =>
    client.get<ExamSessionStateResponse>(`${BASE}/${encodeURIComponent(sessionId)}`),

  /** `PUT /modules/exam/exam-sessions/:id/answers/:question_id` — `question_id` is a PATH
   *  segment, never a body field, matching the router's own shape. */
  saveAnswer: (sessionId: string, questionId: string, answer: SaveAnswerBody) =>
    client.put<ExamAutosaveResponse>(
      `${BASE}/${encodeURIComponent(sessionId)}/answers/${encodeURIComponent(questionId)}`,
      answer,
    ),

  /** `POST /modules/exam/exam-sessions/:id/submit`. */
  submitSession: (sessionId: string) =>
    client.post<ExamSubmissionOutcome>(`${BASE}/${encodeURIComponent(sessionId)}/submit`),

  /** `POST /modules/exam/exam-sessions/:id/events` — `type` is one of
   *  tab_switch | blur | fullscreen_exit (REQ-333's three accepted signal
   *  types); `action_taken` is never sent by the caller (the router has no
   *  such field in its own request schema). */
  reportEvent: (sessionId: string, type: AntiCheatSignalType) =>
    client.post<AntiCheatSignalOutcome>(`${BASE}/${encodeURIComponent(sessionId)}/events`, { type }),

  /** `GET /modules/exam/exam-sessions/available` — lists exams a candidate role may currently
   *  start a session against (status=active, exam_id filtering is
   *  server-side and NOT caller-controlled — see
   *  lib/letflow/design/iss0718-candidate-exam-list-route.md §1). Replaces
   *  this file's prior `queryExamRecords`/`POST /entities/query` call, which
   *  candidate role cannot reach (ISS-0718 — `:EntitiesQuery` is outside
   *  candidate role's ISS-0646 closed set). */
  listAvailableExams: (opts: { cursor?: string; page_size?: number } = {}) =>
    client.get<ExamRecordsPage>(`${BASE}/available`, opts),
}

const AUTHORING_BASE = '/api/v1/modules/exam/authoring'

/** GH 2680 / REQ-510 slice 1: the exam module's write surface for the ten authoring types
 *  (`POST/PUT/DELETE /modules/exam/authoring/:entity_type[/:record_id]`, gated by
 *  `ExamAuthoringWrite`). Same three operations and argument shapes as `entitiesApi`'s
 *  writes, so `EntityCrudPage` takes either one as its write API. Bodies and responses are
 *  the generic record routes' own, so only the path changes. */
export const examAuthoringApi = {
  /** `POST /modules/exam/authoring/:entity_type`. */
  createRecord: (entityType: string, fieldValues: Record<string, unknown>) =>
    client.post<EntityRecord>(`${AUTHORING_BASE}/${encodeURIComponent(entityType)}`, {
      field_values: fieldValues,
    }),

  /** `PUT /modules/exam/authoring/:entity_type/:record_id`. Whole-document replacement, as the
   *  generic route. `ifMatch` is sent as `If-Match`, as `entitiesApi.updateRecord` does. */
  updateRecord: (
    entityType: string,
    recordId: string,
    fieldValues: Record<string, unknown>,
    ifMatch?: string,
  ) =>
    client.putWithHeaders<EntityRecord>(
      `${AUTHORING_BASE}/${encodeURIComponent(entityType)}/${encodeURIComponent(recordId)}`,
      { field_values: fieldValues },
      ifMatch ? { 'If-Match': ifMatch } : {},
    ),

  /** `DELETE /modules/exam/authoring/:entity_type/:record_id`. Bodyless. */
  deleteRecord: (entityType: string, recordId: string) =>
    client.delete<EntityRecord>(
      `${AUTHORING_BASE}/${encodeURIComponent(entityType)}/${encodeURIComponent(recordId)}`,
    ),
}

const GRADING_BASE = '/api/v1/modules/exam/grading-queue'

/** One waiting short-text answer, as `GET /modules/exam/grading-queue` carries it (REQ-588). The
 *  candidate is only the session id; the server sends no name, e-mail or user id. */
export interface GradingQueueRow {
  session_id: string
  question_id: string
  exam_title: string
  stem: string
  max_score: number
  submitted_at: string | null
}

export interface GradingQueuePage {
  items: GradingQueueRow[]
  next_cursor: string | null
}

/** `GET /modules/exam/grading-queue/:session_id/:question_id`: the row plus the candidate's text. */
export interface GradingAnswer extends GradingQueueRow {
  text_answer: string | null
}

export interface GradeResult {
  session_id: string
  question_id: string
  score: number
  max_score: number
  grading_status: string
  session_status: string
}

/** REQ-589: the examiner's grading queue (REQ-588 routes, `ExamGradingRead` / `ExamGradingWrite`). */
export const examGradingApi = {
  listQueue: (opts: { cursor?: string; page_size?: number; exam_id?: string; locale?: string } = {}) =>
    client.get<GradingQueuePage>(GRADING_BASE, opts),

  getAnswer: (sessionId: string, questionId: string, locale?: string) =>
    client.get<GradingAnswer>(
      `${GRADING_BASE}/${encodeURIComponent(sessionId)}/${encodeURIComponent(questionId)}`,
      locale ? { locale } : {},
    ),

  /** The body carries the mark only; the grader is the token's user. */
  grade: (sessionId: string, questionId: string, score: number) =>
    client.post<GradeResult>(
      `${GRADING_BASE}/${encodeURIComponent(sessionId)}/${encodeURIComponent(questionId)}/grade`,
      { score },
    ),
}

const BUILDER_PAGE_SIZE = 200

async function queryAll(
  entityType: string,
  filters: EntityQueryFilterClause[],
  sort?: EntityQuerySortClause[],
): Promise<EntityRecord[]> {
  const items: EntityRecord[] = []
  let cursor: string | undefined
  do {
    const page = await entitiesApi.queryRecords(entityType, {
      filters,
      ...(sort ? { sort } : {}),
      page_size: BUILDER_PAGE_SIZE,
      ...(cursor ? { cursor } : {}),
    })
    items.push(...page.items)
    cursor = page.next_cursor ?? undefined
  } while (cursor)
  return items
}

/** GH 3355 / REQ-602: the reads of the exam builder, one query per entity type
 *  (`POST /entities/query`). An exam has few sections and rules, so the cursor loop normally ends
 *  after the first page. Writes go through `examAuthoringApi`. */
export const examBuilderApi = {
  loadExam: (examId: string) => queryAll('exam', [{ field: 'record_id', op: 'eq', value: examId }]),

  loadSections: (examId: string) =>
    queryAll('exam_section', [{ field: 'exam_id', op: 'eq', value: examId }], [{ field: 'sort_order', dir: 'asc' }]),

  loadRules: (examId: string) =>
    queryAll(
      'exam_question_rule',
      [{ field: 'exam_id', op: 'eq', value: examId }],
      [{ field: 'sort_order', dir: 'asc' }],
    ),
}
