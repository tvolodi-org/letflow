/** examErrors — REQ-338
 *
 *  Classifies the RFC 9457 problem-detail bodies
 *  `lib/letflow/routers/exam_sessions.ex`'s `render_start_session/4` and
 *  `render_autosave/2` send, so the UI can show a distinct translated
 *  message per eligibility/autosave error rather than one generic string.
 *
 *  web/src/api/client.ts's `request()` builds `ApiError.details` from the
 *  full response body when no `errors` key is present (see its `!response.ok`
 *  branch) — RFC 9457's `detail` field (NOT `title`, which is just the HTTP
 *  status phrase, e.g. "Forbidden"/"Unprocessable Entity") is where
 *  `lib/letflow/api/error.ex`'s per-branch distinguishing text lives, so
 *  classification below reads `err.details.detail`, matched against the
 *  router's own literal strings (`render_start_session/4`'s six
 *  `Response.forbidden/conflict/unprocessable` calls,
 *  `render_autosave/2`'s `Response.unprocessable` calls).
 */

import type { ApiError } from '@/types/api'

export type ExamEligibilityErrorKind =
  | 'not_assigned'
  | 'exam_archived'
  | 'exam_not_active'
  | 'outside_availability_window'
  | 'attempts_exhausted'
  | 'session_already_open'
  | 'unknown'

// Verbatim strings from lib/letflow/routers/exam_sessions.ex's render_start_session/4.
const START_ERROR_DETAIL_MAP: Record<string, ExamEligibilityErrorKind> = {
  'you are not assigned to this exam': 'not_assigned',
  'this exam has been archived and is no longer available': 'exam_archived',
  'this exam is not currently active': 'exam_not_active',
  'this exam is not available at this time': 'outside_availability_window',
  'you have used all allowed attempts for this exam': 'attempts_exhausted',
  'you already have an active session for this exam': 'session_already_open',
}

// Verbatim string from render_autosave/2's :deadline_passed branch.
const DEADLINE_PASSED_DETAIL = 'your exam session has expired'

export function isApiError(err: unknown): err is ApiError {
  return typeof err === 'object' && err !== null && 'status' in err
}

function extractDetail(err: unknown): string | null {
  if (!isApiError(err)) return null
  const details = err.details as Record<string, unknown> | undefined
  const detail = details?.['detail']
  return typeof detail === 'string' ? detail : null
}

/** Classifies a failed `startSession` call into one of REQ-332's six
 *  eligibility errors, or 'unknown' for anything else (network error,
 *  internal_error, etc.). */
export function classifyStartError(err: unknown): ExamEligibilityErrorKind {
  const detail = extractDetail(err)
  if (detail && detail in START_ERROR_DETAIL_MAP) {
    return START_ERROR_DETAIL_MAP[detail]
  }
  return 'unknown'
}

/** The candidate's own open session id, which a refused start call's 409 body names (Q-1076 /
 *  GH 2433) so a reloaded page can resume it. Null for every other failure, and for a server
 *  that does not send the id. */
export function openSessionIdFromStartError(err: unknown): string | null {
  if (classifyStartError(err) !== 'session_already_open' || !isApiError(err)) return null
  const details = err.details as Record<string, unknown> | undefined
  const sessionId = details?.['session_id']
  return typeof sessionId === 'string' && sessionId.length > 0 ? sessionId : null
}

/** True when a `saveAnswer` (or `submitSession`) call failed because the
 *  session's server-side deadline has passed (REQ-332's
 *  server-authoritative-clock enforcement) — a terminal state, not something
 *  to retry. */
export function isDeadlinePassedError(err: unknown): boolean {
  return extractDetail(err) === DEADLINE_PASSED_DETAIL
}
