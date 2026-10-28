/** ExamSessionResultPage — REQ-351
 *
 *  Opens an EXISTING exam session by id and renders its result phase,
 *  WITHOUT starting anything. This is a deliberate SIBLING of
 *  `ExamSessionPage.tsx` (REQ-338), not a branch folded into it -- see
 *  REQ-351's own description for why: `ExamSessionPage.tsx`'s mount effect
 *  (:112-127) unconditionally calls `examApi.startSession`, and this
 *  screen's own acceptance criteria forbid the by-id path from ever reaching
 *  `startSession` under any code path. This file therefore imports
 *  `examApi.getSessionState` ONLY -- grep confirms no `startSession` call
 *  anywhere below.
 *
 *  Reuses `ExamSessionPage.tsx`'s result-phase rendering via the shared
 *  `ExamResultView` component (extracted for exactly this reuse) rather than
 *  duplicating its JSX/testids.
 *
 *  URL SHAPE. The cross-session results list now exists (GH #3321, REQ-587:
 *  `ExamMyResultsPage` at `/exam/results`, backed by `GET /exam-sessions/mine`),
 *  and its rows link here, so `/exam/sessions/:sessionId/result` is the list's
 *  detail view and no longer provisional.
 *
 *  SCORE RENDERING (ISS-0674, closed). `GET /modules/exam/exam-sessions/:id`
 *  (`Letflow.Exam.Session.get_session_state_for_user/3`, wrapped by
 *  `examApi.getSessionState`) now returns `score_pct`/`passed` on the
 *  `session` object (`session_view/1`, lib/letflow/exam/session.ex, and
 *  `session_view_json/1`, lib/letflow/routers/exam_sessions.ex -- see
 *  `lib/letflow/design/iss0674-session-view-score-fields.md` for the full
 *  field semantics this was gated on). `score_pct`/`passed` are `null` for
 *  an `in_progress` session, `passed` is additionally `null` for a
 *  `grading_pending` session (score_pct is present but pass/fail is not yet
 *  a decided fact), and both carry real values for `submitted`/
 *  `auto_submitted`. This screen reads those fields directly off
 *  `response.session` and renders `exam-result-score` via `ExamResultView`
 *  for `submitted`/`auto_submitted` sessions -- no shim, no client-side
 *  recomputation of the score itself.
 */

import { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useIntl } from 'react-intl'
import { examApi } from './exam.api'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { ExamIntlProvider } from './ExamIntlProvider'
import { ExamResultView } from './ExamResultView'
import type { ExamSessionStateResponse, ExamSubmissionOutcome } from './exam.types'

type LoadState =
  | { kind: 'loading' }
  | { kind: 'not_found' }
  | { kind: 'pending'; outcome: ExamSubmissionOutcome }
  | { kind: 'score'; outcome: ExamSubmissionOutcome }
  | { kind: 'score_unavailable' }

function ExamSessionResultPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const { sessionId } = useParams<{ sessionId: string }>()

  const [state, setState] = useState<LoadState>({ kind: 'loading' })

  useEffect(() => {
    if (!sessionId) return

    let cancelled = false

    // NOTE, load-bearing for REQ-351's own acceptance criteria: the ONLY
    // exam-session API call this file makes is getSessionState. There is no
    // startSession call anywhere in this component, under any branch.
    examApi
      .getSessionState(sessionId)
      .then((response: ExamSessionStateResponse) => {
        if (cancelled) return
        if (response.session.status === 'grading_pending') {
          setState({
            kind: 'pending',
            outcome: {
              status: 'grading_pending',
              total_score: 0,
              total_max_score: 0,
              percentage: 0,
              passed: null,
            },
          })
        } else if (
          (response.session.status === 'submitted' || response.session.status === 'auto_submitted') &&
          response.session.score_pct !== null &&
          response.session.passed !== null
        ) {
          setState({
            kind: 'score',
            outcome: {
              status: response.session.status,
              total_score: response.session.score_pct,
              total_max_score: 100.0,
              percentage: response.session.score_pct,
              passed: response.session.passed,
            },
          })
        } else {
          // 'in_progress', or a 'submitted'/'auto_submitted' session whose
          // score fields are unexpectedly still null (should not happen per
          // ISS-0674's persisted-write guarantee, but this screen never
          // fabricates a score it cannot honestly construct).
          setState({ kind: 'score_unavailable' })
        }
      })
      .catch(() => {
        if (cancelled) return
        // get_session_state_for_user/3's {:error, :session_not_found} and
        // {:error, :not_owner} both render through the same
        // Response.not_found/1 call (lib/letflow/routers/exam_sessions.ex's
        // own "Ownership and tenant isolation" doc comment) -- a candidate
        // probing another candidate's session id observes the exact same
        // 404 as a genuinely-missing session, by design. Any other error
        // status is treated the same way here: this screen never renders
        // another candidate's content under any response shape.
        setState({ kind: 'not_found' })
      })

    return () => {
      cancelled = true
    }
  }, [sessionId])

  if (state.kind === 'loading') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
        <p data-testid="exam-result-byid-loading">{intl.formatMessage({ id: 'exam.result.byId.loading' })}</p>
      </PageLayout>
    )
  }

  if (state.kind === 'not_found') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
        <p data-testid="exam-result-byid-not-found" style={{ color: 'var(--color-error-dark)' }}>
          {intl.formatMessage({ id: 'exam.result.byId.notFound' })}
        </p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    )
  }

  if (state.kind === 'score_unavailable') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
        <p data-testid="exam-result-scoreUnavailable">{intl.formatMessage({ id: 'exam.result.byId.scoreUnavailable' })}</p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    )
  }

  // state.kind === 'pending' | 'score'
  return <ExamResultView outcome={state.outcome} onBackToList={() => navigate('/exam')} />
}

export default function ExamSessionResultPage() {
  return (
    <ExamIntlProvider>
      <ExamSessionResultPageInner />
    </ExamIntlProvider>
  )
}
