/** ExamGradingAnswerPage — REQ-589
 *
 *  One waiting short-text answer with the mark form. The candidate's text is rendered as a React
 *  text child, never as HTML, and the screen shows no candidate identity (the API sends none).
 *  Save posts exactly `{ score }`. Outcomes: 200 -> back to the list with a confirmation (the list
 *  re-fetches on mount); 409 -> back to the list with the already-graded text; 422 -> field error;
 *  404 (also on load) -> the shell's not-found page.
 */

import { useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { NotFoundPage } from '@/pages/NotFoundPage'
import { examGradingApi } from './exam.api'
import { ExamIntlProvider } from './ExamIntlProvider'
import { gradingQueryKeys, type GradingListNavState } from './gradingQueryKeys'

function statusOf(error: unknown): number | undefined {
  const status = (error as { status?: unknown } | null)?.status
  return typeof status === 'number' ? status : undefined
}

function parseMark(raw: string, max: number): number | null {
  if (raw.trim() === '') return null
  const value = Number(raw)
  if (!Number.isFinite(value) || value < 0 || value > max) return null
  return value
}

function ExamGradingAnswerPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const { sessionId = '', questionId = '' } = useParams()

  const [rawScore, setRawScore] = useState('')
  const [fieldError, setFieldError] = useState(false)
  const [saveFailed, setSaveFailed] = useState(false)
  const inFlight = useRef(false)

  const answerQuery = useQuery({
    queryKey: gradingQueryKeys.answer(tenantId, sessionId, questionId),
    queryFn: () => examGradingApi.getAnswer(sessionId, questionId, intl.locale),
    retry: false,
    refetchOnWindowFocus: false,
  })

  const gradeMutation = useMutation({
    mutationFn: (score: number) => examGradingApi.grade(sessionId, questionId, score),
  })

  if (statusOf(answerQuery.error) === 404 || statusOf(gradeMutation.error) === 404) {
    return <NotFoundPage />
  }

  const answer = answerQuery.data
  const max = answer?.max_score ?? 0
  const mark = answer ? parseMark(rawScore, max) : null

  async function save() {
    if (mark === null || inFlight.current) return
    inFlight.current = true
    setFieldError(false)
    setSaveFailed(false)
    try {
      await gradeMutation.mutateAsync(mark)
      await queryClient.invalidateQueries({ queryKey: gradingQueryKeys.all(tenantId) })
      const state: GradingListNavState = { notice: 'saved' }
      navigate('/exam/grading', { state })
    } catch (error) {
      const status = statusOf(error)
      if (status === 409) {
        await queryClient.invalidateQueries({ queryKey: gradingQueryKeys.all(tenantId) })
        const state: GradingListNavState = { notice: 'alreadyGraded' }
        navigate('/exam/grading', { state })
        return
      }
      if (status === 422) setFieldError(true)
      else if (status !== 404) setSaveFailed(true)
    } finally {
      inFlight.current = false
    }
  }

  return (
    <div data-testid="exam-grading-answer-page">
      <PageLayout title={intl.formatMessage({ id: 'exam.grading.answer.title' })}>
        <QueryStateBoundary
          state={
            (answerQuery.isLoading
              ? 'loading'
              : answerQuery.isError
                ? classifyError(answerQuery.error)
                : 'success') as RendererState
          }
          onRetry={() => {
            void answerQuery.refetch()
          }}
          columns={[{ widthPercent: 100 }]}
        >
        {answer && (
          <>
            <h2>{answer.exam_title}</h2>
            <h3>{intl.formatMessage({ id: 'exam.grading.answer.stem' })}</h3>
            <p data-testid="exam-grading-stem">{answer.stem}</p>
            <h3>{intl.formatMessage({ id: 'exam.grading.answer.text' })}</h3>
            <p data-testid="exam-grading-text" style={{ whiteSpace: 'pre-wrap' }}>
              {answer.text_answer ?? ''}
            </p>
            <p data-testid="exam-grading-max">
              {intl.formatMessage({ id: 'exam.grading.answer.maxScore' }, { maxScore: answer.max_score })}
            </p>

            <form
              onSubmit={(event) => {
                event.preventDefault()
                void save()
              }}
            >
              <label htmlFor="exam-grading-score">
                {intl.formatMessage({ id: 'exam.grading.answer.scoreLabel' })}
              </label>{' '}
              <input
                id="exam-grading-score"
                data-testid="exam-grading-score"
                type="number"
                inputMode="decimal"
                step="any"
                min={0}
                max={answer.max_score}
                value={rawScore}
                aria-invalid={fieldError}
                aria-describedby="exam-grading-score-hint"
                onChange={(event) => {
                  setRawScore(event.target.value)
                  setFieldError(false)
                }}
              />
              <span id="exam-grading-score-hint" style={{ marginLeft: 'var(--space-2)' }}>
                {intl.formatMessage({ id: 'exam.grading.answer.scoreHint' }, { maxScore: answer.max_score })}
              </span>
              {fieldError && (
                <p role="alert" data-testid="exam-grading-field-error" style={{ color: 'var(--color-error-dark)' }}>
                  {intl.formatMessage({ id: 'exam.grading.answer.scoreInvalid' })}
                </p>
              )}
              {saveFailed && (
                <p role="alert" data-testid="exam-grading-save-error" style={{ color: 'var(--color-error-dark)' }}>
                  {intl.formatMessage({ id: 'exam.grading.answer.saveError' })}
                </p>
              )}
              <div style={{ display: 'flex', gap: 'var(--space-2)', marginTop: 'var(--space-4)' }}>
                <Button
                  variant="primary"
                  size="md"
                  data-testid="exam-grading-save"
                  disabled={mark === null || gradeMutation.isPending}
                  onClick={() => void save()}
                >
                  {intl.formatMessage({ id: 'exam.grading.answer.save' })}
                </Button>
                <Button
                  variant="secondary"
                  size="md"
                  data-testid="exam-grading-back"
                  onClick={() => navigate('/exam/grading')}
                >
                  {intl.formatMessage({ id: 'exam.grading.answer.back' })}
                </Button>
              </div>
            </form>
          </>
        )}
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

export default function ExamGradingAnswerPage() {
  return (
    <ExamIntlProvider>
      <ExamGradingAnswerPageInner />
    </ExamIntlProvider>
  )
}
