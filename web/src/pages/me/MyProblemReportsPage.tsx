/** MyProblemReportsPage — REQ-872. The signed-in user's own problem reports and their status (route `/me/problem-reports`,
 *  open to every signed-in user: no permission wrapper). Reads only `GET /api/v1/me/problem-reports`, which the server
 *  filters by tenant and user; reply text arrives only for rows the server chose to show it. Report text and replies are
 *  data: rendered as React text only. States: loading, load error with retry, unavailable (503), empty, list, has_more. */
import { useQuery } from '@tanstack/react-query'
import { problemReportsApi } from '@/api/problemReports'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { EmptyState } from '@/components/ui/EmptyState'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { StatusPill } from '@/components/ui/StatusPill'
import { classifyError } from '@/utils/classifyError'
import { formatDateTime } from '@/i18n/format'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { problemReportsMessages } from '@/pages/admin/problem-reports/problemReportsMessages'
import { STATUS_LOOK, UNKNOWN_LOOK } from '@/pages/admin/problem-reports/problemReportsModel'
import { ReportProblemButton } from '@/components/layout/ReportProblemButton'
import { myProblemReportsMessages } from './myProblemReportsMessages'

export default function MyProblemReportsPage() {
  const locale = useUiLocale()
  const m = myProblemReportsMessages[locale]
  const { isAuthenticated } = useAuth()
  const keys = useTenantScopedQueryKeys().me
  const q = useQuery({
    queryKey: keys.problemReports(),
    queryFn: () => problemReportsApi.listMine(),
    enabled: isAuthenticated,
    retry: false,
    refetchOnWindowFocus: false,
  })
  const unavailable = q.isError && (q.error as { status?: unknown } | null)?.status === 503
  const statusLabel = (s: string) => problemReportsMessages[locale][`problemReports.status.${s}`] ?? s

  return (
    <>
      <PageHeader eyebrow={m.eyebrow} title={m.title} lede={m.lede} />
      {unavailable ? (
        <div data-testid="my-reports-unavailable">
          <Banner tone="warning">{m.unavailable}</Banner>
        </div>
      ) : (
        <QueryStateBoundary
          state={q.isPending ? 'loading' : q.isError ? classifyError(q.error) : 'success'}
          onRetry={() => void q.refetch()}
        >
          {q.data && q.data.reports.length === 0 ? (
            <EmptyState
              data-testid="my-reports-empty"
              title={m.emptyTitle}
              text={m.emptyText}
              action={<ReportProblemButton variant="labelled" testId="my-reports-empty-report" />}
            />
          ) : (
            <>
              <ul className="lf-myreports" data-testid="my-reports-list">
                {q.data?.reports.map((r) => {
                  const look = STATUS_LOOK[r.status] ?? UNKNOWN_LOOK
                  return (
                    <li key={r.id} className="lf-card lf-myreports__row" data-testid="my-report-row" data-report-number={r.number}>
                      <p className="lf-myreports__head">
                        <code data-testid="my-report-number">{r.number}</code>{' '}
                        <span className="lf-muted" data-testid="my-report-received">
                          {m.colReceived}: {formatDateTime(r.received_at, undefined, locale)}
                        </span>{' '}
                        <StatusPill tone={look.tone} glyph={look.glyph} data-testid="my-report-status">
                          {statusLabel(r.status)}
                        </StatusPill>
                      </p>
                      <p data-testid="my-report-text">{r.text}</p>
                      {r.reply_text != null && r.reply_text !== '' && (
                        <p data-testid="my-report-reply">
                          <strong>{r.question ? m.question : m.reply}:</strong> {r.reply_text}
                        </p>
                      )}
                    </li>
                  )
                })}
              </ul>
              {q.data?.has_more && (
                <p className="lf-hint" data-testid="my-reports-has-more">
                  {m.hasMore}
                </p>
              )}
            </>
          )}
        </QueryStateBoundary>
      )}
    </>
  )
}
