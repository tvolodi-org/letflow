/** ExamMyResultsPage — GH #3321, REQ-587 part B
 *
 *  The candidate's own finished sessions, read from `GET /modules/exam/exam-sessions/mine`
 *  (`examApi.listMySessions`). Each row links to the existing by-id result screen and, when the
 *  session passed, offers the certificate PDF through `examApi.downloadCertificate`
 *  (`client.getBlob`, so the bearer header is attached; never a raw link to the backend).
 *  A failed download shows a message under that row only; the list stays and the action can be
 *  retried.
 */

import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { examApi } from './exam.api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { ExamIntlProvider } from './ExamIntlProvider'
import type { ExamMySessionItem } from './exam.types'

const PAGE_SIZE = 20

function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

function ExamMyResultsPageInner() {
  const intl = useIntl()
  const tenantKeys = useTenantScopedQueryKeys()
  const [cursor, setCursor] = useState<string | undefined>(undefined)
  const [downloading, setDownloading] = useState<string | null>(null)
  const [failedDownloads, setFailedDownloads] = useState<ReadonlySet<string>>(new Set())

  const query = useQuery({
    queryKey: tenantKeys.exam.mine({ cursor: cursor ?? null, page_size: PAGE_SIZE }),
    queryFn: () => examApi.listMySessions({ cursor, page_size: PAGE_SIZE }),
  })

  async function handleDownload(sessionId: string) {
    setDownloading(sessionId)
    setFailedDownloads((prev) => {
      const next = new Set(prev)
      next.delete(sessionId)
      return next
    })
    try {
      const { blob } = await examApi.downloadCertificate(sessionId)
      saveBlob(blob, `certificate-${sessionId}.pdf`)
    } catch {
      setFailedDownloads((prev) => new Set(prev).add(sessionId))
    } finally {
      setDownloading(null)
    }
  }

  function renderOutcome(item: ExamMySessionItem) {
    if (item.passed === true) return intl.formatMessage({ id: 'exam.myResults.passed' })
    if (item.passed === false) return intl.formatMessage({ id: 'exam.myResults.failed' })
    return intl.formatMessage({ id: 'exam.myResults.pending' })
  }

  const items = query.data?.items ?? []
  const nextCursor = query.data?.next_cursor ?? null

  let body
  if (query.isError) {
    body = (
      <div data-testid="exam-my-results-error">
        <p style={{ color: 'var(--color-error-dark)' }}>{intl.formatMessage({ id: 'exam.myResults.loadError' })}</p>
        <Button
          variant="secondary"
          size="sm"
          data-testid="exam-my-results-retry"
          onClick={() => {
            void query.refetch()
          }}
        >
          {intl.formatMessage({ id: 'exam.myResults.retry' })}
        </Button>
      </div>
    )
  } else if (items.length === 0) {
    body = <p data-testid="exam-my-results-empty">{intl.formatMessage({ id: 'exam.myResults.empty' })}</p>
  } else {
    body = (
      <ul data-testid="exam-my-results-list" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
        {items.map((item) => (
          <li
            key={item.session_id}
            data-testid={`exam-my-results-row-${item.session_id}`}
            style={{
              background: 'var(--surface-card)',
              border: '1px solid var(--border-default)',
              borderRadius: 'var(--radius-md)',
              padding: 'var(--space-4)',
              marginBottom: 'var(--space-2)',
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--space-4)' }}>
              <div>
                <strong>{item.exam_title || intl.formatMessage({ id: 'exam.myResults.untitled' })}</strong>
                <div>
                  {intl.formatMessage({ id: 'exam.myResults.status' })}: {item.status}
                </div>
                <div>
                  {intl.formatMessage({ id: 'exam.myResults.score' })}:{' '}
                  {item.score_pct === null ? '—' : `${item.score_pct.toFixed(1)}%`}
                </div>
                <div data-testid={`exam-my-results-outcome-${item.session_id}`}>{renderOutcome(item)}</div>
              </div>
              <div style={{ display: 'flex', gap: 'var(--space-2)', alignItems: 'center' }}>
                <Link
                  to={`/exam/sessions/${encodeURIComponent(item.session_id)}/result`}
                  data-testid={`exam-my-results-link-${item.session_id}`}
                >
                  {intl.formatMessage({ id: 'exam.myResults.viewResult' })}
                </Link>
                {item.passed === true && (
                  <Button
                    variant="primary"
                    size="sm"
                    data-testid={`exam-my-results-download-${item.session_id}`}
                    disabled={downloading === item.session_id}
                    onClick={() => {
                      void handleDownload(item.session_id)
                    }}
                  >
                    {intl.formatMessage({ id: 'exam.myResults.downloadCertificate' })}
                  </Button>
                )}
              </div>
            </div>
            {failedDownloads.has(item.session_id) && (
              <p
                role="alert"
                data-testid={`exam-my-results-download-error-${item.session_id}`}
                style={{ color: 'var(--color-error-dark)' }}
              >
                {intl.formatMessage({ id: 'exam.myResults.downloadFailed' })}
              </p>
            )}
          </li>
        ))}
      </ul>
    )
  }

  return (
    <div data-testid="exam-my-results-page">
      <PageLayout title={intl.formatMessage({ id: 'exam.myResults.title' })}>
        <QueryStateBoundary
          state={
            (query.isLoading
              ? 'loading'
              : query.isError && classifyError(query.error) === 'permission-denied'
                ? 'permission-denied'
                : 'success') as RendererState
          }
          columns={[{ widthPercent: 60 }, { widthPercent: 40 }]}
        >
          {body}
        </QueryStateBoundary>
        {cursor !== undefined && (
          <Button
            variant="secondary"
            size="sm"
            data-testid="exam-my-results-first-page"
            onClick={() => setCursor(undefined)}
          >
            {intl.formatMessage({ id: 'exam.myResults.firstPage' })}
          </Button>
        )}
        {nextCursor !== null && (
          <Button
            variant="secondary"
            size="sm"
            data-testid="exam-my-results-next-page"
            onClick={() => setCursor(nextCursor)}
          >
            {intl.formatMessage({ id: 'exam.myResults.nextPage' })}
          </Button>
        )}
      </PageLayout>
    </div>
  )
}

export default function ExamMyResultsPage() {
  return (
    <ExamIntlProvider>
      <ExamMyResultsPageInner />
    </ExamIntlProvider>
  )
}
