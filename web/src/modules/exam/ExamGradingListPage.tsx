/** ExamGradingListPage — REQ-589
 *
 *  The examiner's queue of short-text answers waiting for a mark (REQ-588's
 *  `GET /modules/exam/grading-queue`). The API is blind: a row carries the exam title, the
 *  question stem and the submission time, never the candidate. Paging is cursor based, so the
 *  screen keeps the cursors of the pages it has left (page N is read with cursor N-1) and the
 *  next page exists only when the API returned `next_cursor`.
 */

import { useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { examGradingApi, type GradingQueueRow } from './exam.api'
import { ExamIntlProvider } from './ExamIntlProvider'
import { gradingQueryKeys, type GradingListNavState } from './gradingQueryKeys'

const PAGE_SIZE = 25

function formatSubmitted(intl: ReturnType<typeof useIntl>, value: string | null): string {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return intl.formatDate(date, { dateStyle: 'medium', timeStyle: 'short' })
}

function ExamGradingListPageInner() {
  const intl = useIntl()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const location = useLocation()
  const notice = (location.state as GradingListNavState | null)?.notice

  const [filterInput, setFilterInput] = useState('')
  const [examId, setExamId] = useState('')
  // cursors[i] is the cursor that reads page i + 1; the first page has none.
  const [cursors, setCursors] = useState<(string | undefined)[]>([undefined])
  const page = cursors.length
  const cursor = cursors[page - 1]

  const queueQuery = useQuery({
    queryKey: gradingQueryKeys.list(tenantId, { exam_id: examId || undefined, cursor }),
    queryFn: () =>
      examGradingApi.listQueue({
        page_size: PAGE_SIZE,
        locale: intl.locale,
        exam_id: examId || undefined,
        cursor,
      }),
  })

  const items = queueQuery.data?.items ?? []
  const nextCursor = queueQuery.data?.next_cursor ?? null

  function applyFilter(next: string) {
    setExamId(next)
    setCursors([undefined])
  }

  return (
    <div data-testid="exam-grading-list-page">
      <PageLayout title={intl.formatMessage({ id: 'exam.grading.list.title' })}>
        {notice === 'saved' && (
          <p role="status" data-testid="exam-grading-notice">
            {intl.formatMessage({ id: 'exam.grading.saved' })}
          </p>
        )}
        {notice === 'alreadyGraded' && (
          <p role="status" data-testid="exam-grading-notice">
            {intl.formatMessage({ id: 'exam.grading.alreadyGraded' })}
          </p>
        )}

        <form
          data-testid="exam-grading-filter"
          onSubmit={(event) => {
            event.preventDefault()
            applyFilter(filterInput.trim())
          }}
          style={{ display: 'flex', gap: 'var(--space-2)', alignItems: 'center', marginBottom: 'var(--space-4)' }}
        >
          <label htmlFor="exam-grading-filter-input">
            {intl.formatMessage({ id: 'exam.grading.filter.label' })}
          </label>
          <input
            id="exam-grading-filter-input"
            data-testid="exam-grading-filter-input"
            value={filterInput}
            onChange={(event) => setFilterInput(event.target.value)}
          />
          <button type="submit" data-testid="exam-grading-filter-apply">
            {intl.formatMessage({ id: 'exam.grading.filter.apply' })}
          </button>
          <button
            type="button"
            data-testid="exam-grading-filter-clear"
            onClick={() => {
              setFilterInput('')
              applyFilter('')
            }}
          >
            {intl.formatMessage({ id: 'exam.grading.filter.clear' })}
          </button>
        </form>

        <QueryStateBoundary
          state={
            (queueQuery.isLoading
              ? 'loading'
              : queueQuery.isError
                ? classifyError(queueQuery.error)
                : 'success') as RendererState
          }
          onRetry={() => {
            void queueQuery.refetch()
          }}
          columns={[{ widthPercent: 30 }, { widthPercent: 40 }, { widthPercent: 20 }, { widthPercent: 10 }]}
        >
        {items.length === 0 && (
          <p data-testid="exam-grading-empty">{intl.formatMessage({ id: 'exam.grading.list.empty' })}</p>
        )}

        {items.length > 0 && (
          <table data-testid="exam-grading-table" style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr>
                <th align="left">{intl.formatMessage({ id: 'exam.grading.col.exam' })}</th>
                <th align="left">{intl.formatMessage({ id: 'exam.grading.col.question' })}</th>
                <th align="left">{intl.formatMessage({ id: 'exam.grading.col.submitted' })}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {items.map((row: GradingQueueRow) => (
                <tr key={`${row.session_id}:${row.question_id}`} data-testid="exam-grading-row">
                  <td>{row.exam_title}</td>
                  <td>{row.stem}</td>
                  <td>{formatSubmitted(intl, row.submitted_at)}</td>
                  <td>
                    <Link
                      to={`/exam/grading/${encodeURIComponent(row.session_id)}/${encodeURIComponent(row.question_id)}`}
                    >
                      {intl.formatMessage({ id: 'exam.grading.open' })}
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {(items.length > 0 || page > 1) && (
          <PaginationControls
            page={page}
            pageSize={PAGE_SIZE}
            totalItems={null}
            hasNextPage={nextCursor !== null}
            onPageChange={(next) => {
              if (next > page && nextCursor !== null) setCursors([...cursors, nextCursor])
              else if (next < page) setCursors(cursors.slice(0, next))
            }}
          />
        )}
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

export default function ExamGradingListPage() {
  return (
    <ExamIntlProvider>
      <ExamGradingListPageInner />
    </ExamIntlProvider>
  )
}

