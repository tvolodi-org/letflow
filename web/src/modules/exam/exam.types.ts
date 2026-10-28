/** Exam-session client types — REQ-338
 *
 *  Mirrors `lib/letflow/routers/exam_sessions.ex`'s own JSON-shaping functions
 *  (`session_state_json/1`, `question_state_json/1`, `answer_json/1`,
 *  `submission_outcome_json/1`, `signal_outcome_json/1`) field-for-field. Kept
 *  in its own file rather than appended to `web/src/types/api.ts` because that
 *  file already carries uncommitted, in-flight changes from a concurrent
 *  session (REQ-336) at the time this requirement was implemented — a
 *  separate file avoids a collision on a shared file neither requirement
 *  needs the other's content from.
 */

export type ExamSessionStatus = 'in_progress' | 'submitted' | 'auto_submitted' | 'grading_pending'

export interface ExamSessionView {
  id: string
  exam_id: string
  candidate_id: string
  status: ExamSessionStatus
  seed: number
  started_at: string
  expires_at: string
  /** ISS-0674: `null` while `in_progress`; a persisted `float` for
   *  `submitted`/`auto_submitted`/`grading_pending` once
   *  `update_session_after_submit/4` has run. */
  score_pct: number | null
  /** ISS-0674: `null` while `in_progress` or `grading_pending` (pass/fail is
   *  not yet a decided fact until manual grading completes); the persisted
   *  boolean for `submitted`/`auto_submitted`. */
  passed: boolean | null
}

/** A `:localized_text` field's raw wire value -- a map of locale code to
 *  string, e.g. `{ "en": "...", "ru": "...", "kk": "..." }`. Never a plain
 *  string on the wire (see `lib/letflow/exam/session.ex`'s `fv/2`). */
export type LocalizedText = Record<string, string>

export interface ExamQuestionOption {
  id: string
  text: LocalizedText
}

export type ExamQuestionType = 'single' | 'multiple' | 'true_false' | 'likert' | 'short_text'

export interface ExamQuestionState {
  question_id: string
  sort_order: number
  type: ExamQuestionType
  stem: LocalizedText
  options: ExamQuestionOption[]
}

export interface ExamAnswerState {
  selected_option_ids: string[]
  text_answer: string | null
  time_spent_seconds: number
  saved_at: string | null
}

/** `GET /modules/exam/exam-sessions/:id` and the 201 body of `POST /modules/exam/exam-sessions`. */
export interface ExamSessionStateResponse {
  session: ExamSessionView
  remaining_seconds: number
  questions: ExamQuestionState[]
  answers: Record<string, ExamAnswerState>
}

/** `PUT /modules/exam/exam-sessions/:id/answers/:question_id`'s 200 body. */
export interface ExamAutosaveResponse {
  remaining_seconds: number
}

/** `POST /modules/exam/exam-sessions/:id/submit`'s 200 body, and the `submission` field of
 *  a `submit`-branch anti-cheat outcome. */
export interface ExamSubmissionOutcome {
  status: 'submitted' | 'grading_pending' | 'auto_submitted'
  total_score: number
  total_max_score: number
  percentage: number
  passed: boolean | null
}

export type AntiCheatSignalType = 'tab_switch' | 'blur' | 'fullscreen_exit'
export type AntiCheatActionTaken = 'log' | 'warn' | 'submit'

/** `POST /modules/exam/exam-sessions/:id/events`'s 200 body. */
export interface AntiCheatSignalOutcome {
  action_taken: AntiCheatActionTaken
  event_count: number
  warning: boolean
  submission: ExamSubmissionOutcome | null
}

export interface SaveAnswerBody {
  selected_option_ids?: string[]
  time_spent_seconds: number
  /** ISS-0650: a `short_text` question's free-text answer. Optional --
   *  absent for every other question type's autosave; the backend
   *  (`Letflow.Exam.Session.check_answer_shape/3`) rejects a non-nil value
   *  sent for any of them, so callers must only set this when
   *  `question.type === 'short_text'`. */
  text_answer?: string
}

/** One item of `GET /modules/exam/exam-sessions/mine` (GH #3321, REQ-587): the caller's own
 *  finished session. `exam_title` is null when the exam record is gone; `passed` is null while
 *  grading is pending. */
export interface ExamMySessionItem {
  session_id: string
  exam_id: string
  exam_title: string | null
  status: string
  started_at: string | null
  submitted_at: string | null
  score_pct: number | null
  passed: boolean | null
  certificate_issued: boolean
  certificate_id: string | null
}

export interface ExamMySessionsPage {
  items: ExamMySessionItem[]
  next_cursor: string | null
}
