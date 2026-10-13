/** ExamSessionPage — REQ-338
 *
 *  The candidate exam-taking flow: start/eligibility, in-progress (one
 *  question at a time, autosave, server-re-anchored countdown), and
 *  submit/result -- as one page component sharing one `phase` state machine,
 *  because all three screens share the same session identity and the
 *  anti-cheat listeners must be torn down exactly when the flow leaves the
 *  in-progress phase (REQ-333 wiring below).
 *
 *  SCREEN 1 -- start/eligibility. On mount, calls `examApi.startSession`.
 *  A failure renders one of REQ-332's six eligibility errors as a distinct
 *  translated message (`utils/examErrors.ts`'s `classifyStartError`), never
 *  one generic string.
 *
 *  SCREEN 2 -- in-progress. One question at a time. Selecting an answer
 *  autosaves immediately via `examApi.saveAnswer`; the countdown
 *  (`remainingSeconds` state) is SET DIRECTLY from every save response's
 *  `remaining_seconds` field -- never left to free-run from a client-only
 *  timer, per REQ-332's server-authoritative-clock property. A local
 *  `setInterval` only ticks the DISPLAYED value down by one second between
 *  saves; it never overrides a value the server has not itself sent. An
 *  autosave rejected because the session's server-side deadline has passed
 *  (`isDeadlinePassedError`) moves the whole flow to phase 'expired' -- a
 *  terminal state, not a retry loop.
 *
 *  SCREEN 3 -- submit/result. A `grading_pending` outcome
 *  (`Session.submission_outcome`'s own `status`) renders the pending copy
 *  and NEVER a numeric score; any other status renders the real
 *  score/percentage/passed.
 *
 *  ANTI-CHEAT. `useAntiCheatSignals` is enabled only while `phase ===
 *  'in_progress'`; its `warn` outcome surfaces a visible warning with the
 *  running `event_count`, and its `submit` outcome moves `phase` to
 *  'result' using the SERVER's own `submission` payload (never by
 *  continuing to show the in-progress screen) -- which also flips `enabled`
 *  to false, tearing the listeners down (see the hook's own doc comment).
 *
 *  SHORT-TEXT QUESTIONS (ISS-0650). `@autosave_schema`
 *  (lib/letflow/routers/exam_sessions.ex) and
 *  `Letflow.Exam.Session.answer_attrs()` now carry an optional `text_answer`
 *  field, so this screen renders a real controlled textarea for a
 *  `short_text` question instead of the earlier placeholder note. It
 *  restores any previously-saved `text_answer` on load/question-change, and
 *  autosaves through the SAME `saveAnswer` call every other question type
 *  uses -- fired on blur (not on every keystroke, unlike the
 *  immediate-on-click option types, to avoid a network round-trip per
 *  character) with `selected_option_ids: []` and `text_answer` set, which
 *  `Session.check_answer_shape/3` validates is only ever sent for a
 *  `short_text` question.
 *
 *  FLUSH-BEFORE-FORCED-SUBMIT (ISS-0654). A `short_text` textarea's
 *  uncommitted keystrokes only reach the server on `onBlur`, but
 *  `useAntiCheatSignals`' `submit`-outcome can flip `phase` to 'result' from
 *  a browser-event callback (e.g. `on_tab_switch: 'submit'`) with no blur in
 *  between, which would otherwise silently drop the draft. `maybeSaveDraft`
 *  below holds the one save-if-changed check shared by both call sites:
 *  `handleTextAnswerBlur` (the normal blur path) and the `flushBeforeReport`
 *  callback passed into `useAntiCheatSignals` (the forced-submit path,
 *  invoked once per browser signal). The hook AWAITS that callback's promise
 *  before calling `examApi.reportEvent`, so the flush's `saveAnswer` always
 *  resolves on the server strictly before the anti-cheat report that may
 *  trigger the forced submit -- no race between the two network calls.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useIntl } from 'react-intl'
import { examApi } from './exam.api'
import { createDwellClock, recordSaveTotal, switchQuestion } from './dwellTime'
import { classifyStartError, isDeadlinePassedError, type ExamEligibilityErrorKind } from '@/utils/examErrors'
import { useAntiCheatSignals } from './useAntiCheatSignals'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { ExamIntlProvider } from './ExamIntlProvider'
import { resolveUiLocale } from '@/i18n/entitiesMessages'
import { ExamResultView } from './ExamResultView'
import type {
  AntiCheatSignalOutcome,
  ExamAnswerState,
  ExamQuestionState,
  ExamSessionStateResponse,
  ExamSubmissionOutcome,
  LocalizedText,
} from './exam.types'

type Phase =
  | { kind: 'starting' }
  | { kind: 'error'; error: ExamEligibilityErrorKind }
  | { kind: 'in_progress' }
  | { kind: 'expired' }
  | { kind: 'result'; outcome: ExamSubmissionOutcome }

/** Resolves a `:localized_text` wire value to a single display string.
 *  Fallback order: current UI locale -> 'en' -> first non-empty value -> ''.
 *  Mirrors `EntityCrudPage.tsx`'s `formatCellValue`, with an explicit `en`
 *  step named ahead of the "first non-empty value" step (see
 *  docs/frontend/exam-session-localized-fields-fix.md). */
function resolveLocalizedText(value: LocalizedText | null | undefined, uiLocale: string): string {
  if (!value) return ''
  const own = value[uiLocale]
  if (own) return own
  const en = value['en']
  if (en) return en
  for (const v of Object.values(value)) {
    if (v) return v
  }
  return ''
}

function formatRemaining(totalSeconds: number): { minutes: string; seconds: string } {
  const clamped = Math.max(0, totalSeconds)
  const minutes = Math.floor(clamped / 60)
  const seconds = clamped % 60
  return { minutes: String(minutes).padStart(2, '0'), seconds: String(seconds).padStart(2, '0') }
}

function ExamSessionPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const { examId } = useParams<{ examId: string }>()
  const uiLocale = resolveUiLocale([intl.locale])

  const [phase, setPhase] = useState<Phase>({ kind: 'starting' })
  const [session, setSession] = useState<ExamSessionStateResponse | null>(null)
  const [answers, setAnswers] = useState<Record<string, ExamAnswerState>>({})
  const [remainingSeconds, setRemainingSeconds] = useState<number>(0)
  const [saveStatus, setSaveStatus] = useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [warning, setWarning] = useState<{ eventCount: number } | null>(null)
  const [questionIndex, setQuestionIndex] = useState(0)

  const startedRef = useRef(false)

  // ── Screen 1: start ──────────────────────────────────────────────────
  useEffect(() => {
    if (!examId || startedRef.current) return
    startedRef.current = true

    examApi
      .startSession(examId)
      .then((state) => {
        setSession(state)
        setAnswers(state.answers)
        setRemainingSeconds(state.remaining_seconds)
        setPhase({ kind: 'in_progress' })
      })
      .catch((err: unknown) => {
        setPhase({ kind: 'error', error: classifyStartError(err) })
      })
  }, [examId])

  // Local between-saves ticking only -- never authoritative on its own.
  useEffect(() => {
    if (phase.kind !== 'in_progress') return undefined
    const id = window.setInterval(() => {
      setRemainingSeconds((prev) => Math.max(0, prev - 1))
    }, 1000)
    return () => window.clearInterval(id)
  }, [phase.kind])

  const currentQuestion: ExamQuestionState | undefined = session?.questions[questionIndex]

  // Q-1075 / GH #2432: time on a question is measured here (client-reported; the server
  // bounds it). The clock is charged to whichever question is on screen, and survives
  // revisits within this page mount.
  const [dwell] = useState(() => createDwellClock(Date.now()))
  useEffect(() => {
    switchQuestion(dwell, currentQuestion?.question_id, Date.now())
  }, [currentQuestion?.question_id, dwell])

  // Local, uncommitted draft of the current short_text question's textarea
  // value -- keystrokes update this only; `saveAnswer` (on blur) is what
  // actually autosaves. Re-synced from the restored `answers` state whenever
  // the visible question changes, so navigating away and back shows the
  // last-saved text, not a stale draft from a previous question.
  //
  // ISS-0696: derived during render (React's "adjusting state during render"
  // pattern) rather than in a useEffect, so there is no intermediate commit
  // where the textarea is on-screen with a stale/empty textDraft one render
  // behind the question it belongs to -- see
  // lib/letflow/design/iss-0696-examsessionpage-race-fix.md.
  const [textDraft, setTextDraft] = useState<string>('')
  const [textDraftQuestionId, setTextDraftQuestionId] = useState<string | undefined>(undefined)
  if (currentQuestion?.question_id !== textDraftQuestionId) {
    setTextDraftQuestionId(currentQuestion?.question_id)
    if (currentQuestion?.type === 'short_text') {
      setTextDraft(answers[currentQuestion.question_id]?.text_answer ?? '')
    }
  }

  const saveAnswer = useCallback(
    (question: ExamQuestionState, selectedOptionIds: string[], textAnswer?: string): Promise<void> => {
      if (!session) return Promise.resolve()
      setSaveStatus('saving')
      // Q-1075 / GH #2432: the running total for this question, not a 0 default.
      const timeSpentSeconds = recordSaveTotal(
        dwell,
        question.question_id,
        answers[question.question_id]?.time_spent_seconds ?? 0,
        Date.now(),
      )
      return examApi
        .saveAnswer(session.session.id, question.question_id, {
          selected_option_ids: selectedOptionIds,
          time_spent_seconds: timeSpentSeconds,
          ...(question.type === 'short_text' ? { text_answer: textAnswer ?? '' } : {}),
        })
        .then((response) => {
          // Re-anchor to the server's value directly -- not asymptotically.
          setRemainingSeconds(response.remaining_seconds)
          setAnswers((prev) => ({
            ...prev,
            [question.question_id]: {
              selected_option_ids: selectedOptionIds,
              text_answer:
                question.type === 'short_text' ? (textAnswer ?? '') : (prev[question.question_id]?.text_answer ?? null),
              time_spent_seconds: timeSpentSeconds,
              saved_at: new Date().toISOString(),
            },
          }))
          setSaveStatus('saved')
        })
        .catch((err: unknown) => {
          if (isDeadlinePassedError(err)) {
            setPhase({ kind: 'expired' })
            return
          }
          setSaveStatus('error')
        })
    },
    [session, answers, dwell],
  )

  // Shared save-if-changed check (ISS-0654): the one thing both
  // `handleTextAnswerBlur` (normal blur path) and the anti-cheat
  // `flushBeforeReport` callback (forced-submit path) need -- skip the
  // network call when the draft matches what is already saved, otherwise
  // fire the SAME `saveAnswer` both paths already use and return its promise
  // so the caller can await completion.
  const maybeSaveDraft = useCallback(
    (question: ExamQuestionState, draft: string): Promise<void> => {
      const previouslySaved = answers[question.question_id]?.text_answer ?? ''
      if (draft === previouslySaved) return Promise.resolve()
      return saveAnswer(question, [], draft)
    },
    [answers, saveAnswer],
  )

  const handleOptionToggle = (question: ExamQuestionState, optionId: string) => {
    const isMulti = question.type === 'multiple'
    const current = answers[question.question_id]?.selected_option_ids ?? []
    const next = isMulti
      ? current.includes(optionId)
        ? current.filter((id) => id !== optionId)
        : [...current, optionId]
      : [optionId]
    saveAnswer(question, next)
  }

  const handleTextAnswerBlur = (question: ExamQuestionState) => {
    void maybeSaveDraft(question, textDraft)
  }

  const handleAntiCheatOutcome = useCallback(
    (outcome: AntiCheatSignalOutcome) => {
      if (outcome.action_taken === 'warn') {
        setWarning({ eventCount: outcome.event_count })
        return
      }
      if (outcome.action_taken === 'submit' && outcome.submission) {
        setPhase({ kind: 'result', outcome: outcome.submission })
      }
      // 'log' -> no visible UI change, per this requirement's own spec.
    },
    [],
  )

  // ISS-0654: flush any uncommitted short_text draft BEFORE the anti-cheat
  // hook's `reportEvent` call fires -- see this hook's own doc comment for
  // why it is read through a ref rather than a dependency, and this file's
  // top-of-file "FLUSH-BEFORE-FORCED-SUBMIT" comment for why this must be
  // awaited rather than fired-and-forgotten.
  const flushTextDraftBeforeAntiCheatReport = useCallback((): Promise<void> => {
    if (!currentQuestion || currentQuestion.type !== 'short_text') return Promise.resolve()
    return maybeSaveDraft(currentQuestion, textDraft)
  }, [currentQuestion, textDraft, maybeSaveDraft])

  useAntiCheatSignals(
    session?.session.id ?? null,
    phase.kind === 'in_progress',
    handleAntiCheatOutcome,
    flushTextDraftBeforeAntiCheatReport,
  )

  const handleSubmit = () => {
    if (!session) return
    examApi.submitSession(session.session.id).then((outcome) => {
      setPhase({ kind: 'result', outcome })
    })
  }

  // ── Render ───────────────────────────────────────────────────────────

  if (phase.kind === 'starting') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.session.remainingTime' }, { minutes: '--', seconds: '--' })}>
        <p data-testid="exam-starting">{intl.formatMessage({ id: 'exam.start.starting' })}</p>
      </PageLayout>
    )
  }

  if (phase.kind === 'error') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.list.title' })}>
        <p data-testid="exam-start-error" style={{ color: 'var(--color-error-dark)' }}>
          {intl.formatMessage({ id: `exam.start.error.${phase.error}` })}
        </p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.start.retryAction' })}
        </Button>
      </PageLayout>
    )
  }

  if (phase.kind === 'expired') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.session.expired.title' })}>
        <p data-testid="exam-expired">{intl.formatMessage({ id: 'exam.session.expired.body' })}</p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    )
  }

  if (phase.kind === 'result') {
    // REQ-351: extracted into ExamResultView so this live-flow render and
    // ExamSessionResultPage.tsx's by-id render share one implementation.
    return <ExamResultView outcome={phase.outcome} onBackToList={() => navigate('/exam')} />
  }

  // phase.kind === 'in_progress'
  const { minutes, seconds } = formatRemaining(remainingSeconds)

  return (
    <div data-testid="exam-session-page">
      <PageLayout
        title={intl.formatMessage({ id: 'exam.session.remainingTime' }, { minutes, seconds })}
        actions={
          <Button variant="primary" size="md" data-testid="exam-submit-action" onClick={handleSubmit}>
            {intl.formatMessage({ id: 'exam.session.submitAction' })}
          </Button>
        }
      >
        {warning && (
          <div
            data-testid="exam-anticheat-warning"
            role="alert"
            style={{
              background: 'var(--color-warning-tint)',
              border: '1px solid var(--color-warning-border)',
              color: 'var(--color-warning-text)',
              borderRadius: 'var(--radius-md)',
              padding: 'var(--space-4)',
              marginBottom: 'var(--space-4)',
            }}
          >
            {intl.formatMessage({ id: 'exam.anticheat.warning' }, { count: warning.eventCount })}
          </div>
        )}

        {session && currentQuestion && (
          <div data-testid={`exam-question-${currentQuestion.question_id}`}>
            <p>
              {intl.formatMessage(
                { id: 'exam.session.questionOf' },
                { current: questionIndex + 1, total: session.questions.length },
              )}
            </p>
            <h3>{resolveLocalizedText(currentQuestion.stem, uiLocale)}</h3>

            {currentQuestion.type === 'short_text' ? (
              <div>
                <label htmlFor={`exam-short-text-${currentQuestion.question_id}`} style={{ display: 'block', marginBottom: 'var(--space-2)' }}>
                  {intl.formatMessage({ id: 'exam.session.shortTextLabel' })}
                </label>
                <textarea
                  id={`exam-short-text-${currentQuestion.question_id}`}
                  data-testid="exam-short-text-input"
                  value={textDraft}
                  placeholder={intl.formatMessage({ id: 'exam.session.shortTextPlaceholder' })}
                  onChange={(e) => setTextDraft(e.target.value)}
                  onBlur={() => handleTextAnswerBlur(currentQuestion)}
                  rows={5}
                  style={{
                    width: '100%',
                    padding: 'var(--space-2) var(--space-3)',
                    border: '1px solid var(--color-neutral-400)',
                    borderRadius: 'var(--radius-md)',
                    fontSize: '.9rem',
                    fontFamily: 'inherit',
                    boxSizing: 'border-box',
                  }}
                />
              </div>
            ) : (
              <div>
                {currentQuestion.options.map((option) => {
                  const selected = (answers[currentQuestion.question_id]?.selected_option_ids ?? []).includes(
                    option.id,
                  )
                  return (
                    <label key={option.id} style={{ display: 'block', marginBottom: 'var(--space-2)' }}>
                      <input
                        type={currentQuestion.type === 'multiple' ? 'checkbox' : 'radio'}
                        name={currentQuestion.question_id}
                        checked={selected}
                        data-testid={`exam-option-${option.id}`}
                        onChange={() => handleOptionToggle(currentQuestion, option.id)}
                      />{' '}
                      {resolveLocalizedText(option.text, uiLocale)}
                    </label>
                  )
                })}
              </div>
            )}

            <p data-testid="exam-save-status">
              {saveStatus === 'saving' && intl.formatMessage({ id: 'exam.session.saveStatus.saving' })}
              {saveStatus === 'saved' && intl.formatMessage({ id: 'exam.session.saveStatus.saved' })}
              {saveStatus === 'error' && intl.formatMessage({ id: 'exam.session.saveStatus.error' })}
            </p>

            <div style={{ display: 'flex', gap: 'var(--space-2)' }}>
              <Button
                variant="secondary"
                size="sm"
                disabled={questionIndex === 0}
                onClick={() => setQuestionIndex((i) => Math.max(0, i - 1))}
              >
                {intl.formatMessage({ id: 'exam.session.prevQuestion' })}
              </Button>
              <Button
                variant="secondary"
                size="sm"
                disabled={!session || questionIndex >= session.questions.length - 1}
                onClick={() => setQuestionIndex((i) => Math.min((session?.questions.length ?? 1) - 1, i + 1))}
              >
                {intl.formatMessage({ id: 'exam.session.nextQuestion' })}
              </Button>
            </div>
          </div>
        )}
      </PageLayout>
    </div>
  )
}

export default function ExamSessionPage() {
  return (
    <ExamIntlProvider>
      <ExamSessionPageInner />
    </ExamIntlProvider>
  )
}
