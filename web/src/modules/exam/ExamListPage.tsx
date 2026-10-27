/** ExamListPage — REQ-338
 *
 *  THE ASSIGNMENT-QUESTION AMBIGUITY ESCAPE — OPTION (a) CHOSEN.
 *
 *  History: when this screen was written, Session.check_assigned/3 was a
 *  documented no-op (every candidate treated as assigned), so listing every
 *  exam whose status is `active` was honest. Since REQ-582 part B the check
 *  is enforced (an exam without an active assignment for the candidate gives
 *  403 on start), but the list is still unfiltered by assignment (open
 *  question 6 of REQ-582, out of scope there). This screen therefore renders
 *  `exam.list.provisionalNotice`
 *  PROMINENTLY so a later fix to `check_assigned/3` does not silently strand
 *  a stale "shows everything" list screen. Option (b) (report this
 *  requirement BLOCKED) was rejected: the requirement's own text frames (a)
 *  and (b) as "two consistent options" and this requirement's other ten
 *  acceptance criteria (start/in-progress/result screens, anti-cheat wiring)
 *  are all independently buildable and required regardless of how the list
 *  screen is resolved -- reporting the whole requirement BLOCKED over one
 *  screen's data source, when a truthful provisional list is buildable,
 *  would leave nine other acceptance criteria undone unnecessarily.
 *
 *  ISS-0718: this screen now reads via the dedicated
 *  `GET /modules/exam/exam-sessions/available` route (`examApi.listAvailableExams`),
 *  gated by candidate role's existing `:ExamSessionStart`
 *  permission. Added specifically because the generic `POST /entities/query`
 *  route this screen previously called (via `examApi.queryExamRecords`) is
 *  outside candidate role's ISS-0646 closed permission set — every candidate role call
 *  onto it was a guaranteed 403. See
 *  `lib/letflow/design/iss0718-candidate-exam-list-route.md` for the full
 *  design; status=active filtering is now hardcoded server-side rather than
 *  a caller-supplied filter clause.
 *
 *  REQ-366 addendum: this screen's `PageLayout` `actions` slot now also
 *  carries `<HelpTrigger screenId="exam-list" />` — this run's real,
 *  tenant-scoped `screen_id` used to exercise the full help
 *  fetch -> resolve -> sanitize -> render mechanism end-to-end (design
 *  §6.1's substitute for AC3's still-blocked login-routing screen; see
 *  `lib/letflow/design/req366-help-display-panel.md` §6). Chosen because
 *  this page already used `PageLayout`'s `actions` slot cleanly and needed
 *  no structural change beyond adding the trigger.
 */

import { useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { examApi, type ExamRecord } from './exam.api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { ExamIntlProvider } from './ExamIntlProvider'
import { HelpTrigger } from '@/components/help/HelpTrigger'
import { resolveUiLocale } from '@/i18n/entitiesMessages'
import type { LocalizedText } from './exam.types'

/** ISS-0728: `field_values.title`/`.name` come back from
 *  `GET /modules/exam/exam-sessions/available` as the raw entity field value -- a
 *  `:localized_text` field renders as a `LocalizedText` object (e.g.
 *  `{en, kk, ru}`), NOT a plain string, so `String(value)` on it produced
 *  the literal text "[object Object]" for every real exam. Mirrors
 *  `ExamSessionPage.tsx`'s own `resolveLocalizedText` (used there for
 *  question stems/option text): a plain string field value passes through
 *  unchanged; a `LocalizedText` object resolves via current UI locale ->
 *  'en' -> first non-empty value -> ''. */
function resolveExamFieldText(value: unknown, uiLocale: string): string {
  if (value == null) return ''
  if (typeof value === 'string') return value
  if (typeof value === 'object') {
    const localized = value as LocalizedText
    const own = localized[uiLocale]
    if (own) return own
    const en = localized['en']
    if (en) return en
    for (const v of Object.values(localized)) {
      if (v) return v
    }
    return ''
  }
  return String(value)
}

function ExamListPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const uiLocale = resolveUiLocale([intl.locale])
  const tenantKeys = useTenantScopedQueryKeys()

  const examsQuery = useQuery({
    queryKey: tenantKeys.exam.list({ page_size: 100 }),
    queryFn: () => examApi.listAvailableExams({ page_size: 100 }),
  })

  const exams = useMemo(() => examsQuery.data?.items ?? [], [examsQuery.data])

  return (
    <div data-testid="exam-list-page">
      <PageLayout
        title={intl.formatMessage({ id: 'exam.list.title' })}
        actions={<HelpTrigger screenId="exam-list" />}
      >
        <div
          data-testid="exam-list-provisional-notice"
          role="note"
          style={{
            background: 'var(--color-warning-tint)',
            border: '1px solid var(--color-warning-border)',
            color: 'var(--color-warning-text)',
            borderRadius: 'var(--radius-md)',
            padding: 'var(--space-4)',
            marginBottom: 'var(--space-4)',
          }}
        >
          {intl.formatMessage({ id: 'exam.list.provisionalNotice' })}
        </div>

        <QueryStateBoundary
          state={
            (examsQuery.isLoading
              ? 'loading'
              : examsQuery.isError
                ? classifyError(examsQuery.error)
                : 'success') as RendererState
          }
          onRetry={() => {
            void examsQuery.refetch()
          }}
          columns={[{ widthPercent: 70 }, { widthPercent: 30 }]}
        >
          {examsQuery.isError && (
            <p style={{ color: 'var(--color-error-dark)' }}>
              {intl.formatMessage({ id: 'exam.list.loadError' })}
            </p>
          )}

          {exams.length === 0 && (
            <p data-testid="exam-list-empty">{intl.formatMessage({ id: 'exam.list.emptyMessage' })}</p>
          )}

          <ul data-testid="exam-list" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
            {exams.map((exam: ExamRecord) => (
              <li
                key={exam.record_id}
                data-testid={`exam-list-item-${exam.record_id}`}
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--surface-card)',
                  border: '1px solid var(--border-default)',
                  borderRadius: 'var(--radius-md)',
                  padding: 'var(--space-4)',
                  marginBottom: 'var(--space-2)',
                }}
              >
                <span>
                  {resolveExamFieldText(exam.field_values.title, uiLocale) ||
                    resolveExamFieldText(exam.field_values.name, uiLocale) ||
                    exam.record_id}
                </span>
                <Button
                  variant="primary"
                  size="sm"
                  data-testid={`exam-list-start-${exam.record_id}`}
                  onClick={() => navigate(`/exam/${exam.record_id}/session`)}
                >
                  {intl.formatMessage({ id: 'exam.list.startAction' })}
                </Button>
              </li>
            ))}
          </ul>
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

export default function ExamListPage() {
  return (
    <ExamIntlProvider>
      <ExamListPageInner />
    </ExamIntlProvider>
  )
}
