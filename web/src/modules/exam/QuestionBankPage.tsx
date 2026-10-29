/** QuestionBankPage — GH 3423 / REQ-612
 *
 *  The question bank (route `/admin/questions`): the tenant's questions in a table with the stem in
 *  the viewer's locale, type, status and a difficulty badge, plus a stem search that fires on an
 *  explicit Search press (button or Enter), not on every keystroke. New Question and Edit show only
 *  for a holder of ExamAuthoringWrite. No AI or Import action (REQ-600 precondition is unmet).
 *  50 rows per page; "Next page" follows the cursor, there is no total count.
 */

import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { entitiesApi } from '@/api/entities'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { ExamIntlProvider } from './ExamIntlProvider'
import { DifficultyBadge } from './DifficultyBadge'
import { questionQueryKeys } from './builderQueryKeys'
import { EXAM_AUTHORING_WRITE } from './bilimbagaWrites'
import { localizedText, searchFilters } from './questionEditorModel'
import type { ExamUiLocale } from './examMessages'

const PAGE_SIZE = 50

const cellStyle = { textAlign: 'left', padding: 'var(--space-1) var(--space-2)' } as const

function QuestionBankPageInner() {
  const intl = useIntl()
  const locale = intl.locale as ExamUiLocale
  const navigate = useNavigate()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const canWrite = useAccess().can(EXAM_AUTHORING_WRITE)
  const [input, setInput] = useState('')
  const [term, setTerm] = useState('')
  const [cursor, setCursor] = useState<string | undefined>(undefined)

  const query = useQuery({
    queryKey: questionQueryKeys.bank(tenantId, locale, term, cursor ?? ''),
    queryFn: () =>
      entitiesApi.queryRecords('question', {
        filters: searchFilters(term, locale),
        page_size: PAGE_SIZE,
        ...(cursor ? { cursor } : {}),
      }),
    retry: false,
  })
  const items = query.data?.items ?? []
  const nextCursor = query.data?.next_cursor ?? null

  function submit(event: FormEvent) {
    event.preventDefault()
    setCursor(undefined)
    setTerm(input)
  }

  return (
    <div data-testid="question-bank-page">
      <PageLayout
        title={intl.formatMessage({ id: 'exam.question.bank.title' })}
        actions={
          canWrite ? (
            <Button
              variant="primary"
              size="md"
              data-testid="question-new"
              onClick={() => navigate('/admin/questions/new')}
            >
              {intl.formatMessage({ id: 'exam.question.new' })}
            </Button>
          ) : undefined
        }
      >
        <form onSubmit={submit} role="search" data-testid="question-search-form">
          <label htmlFor="question-search-input">{intl.formatMessage({ id: 'exam.question.search.label' })}</label>{' '}
          <input
            id="question-search-input"
            type="search"
            value={input}
            placeholder={intl.formatMessage({ id: 'exam.question.search.placeholder' })}
            onChange={(event) => setInput(event.target.value)}
          />{' '}
          <button type="submit" data-testid="question-search-submit">
            {intl.formatMessage({ id: 'exam.question.search.button' })}
          </button>
        </form>
        <QueryStateBoundary
          state={
            (query.isLoading ? 'loading' : query.isError ? classifyError(query.error) : 'success') as RendererState
          }
          onRetry={() => {
            void query.refetch()
          }}
        >
          {items.length === 0 ? (
            <p data-testid="question-bank-empty">{intl.formatMessage({ id: 'exam.question.empty' })}</p>
          ) : (
            <table data-testid="question-bank-table">
              <thead>
                <tr>
                  <th style={cellStyle}>{intl.formatMessage({ id: 'exam.question.col.stem' })}</th>
                  <th style={cellStyle}>{intl.formatMessage({ id: 'exam.question.col.type' })}</th>
                  <th style={cellStyle}>{intl.formatMessage({ id: 'exam.question.col.status' })}</th>
                  <th style={cellStyle}>{intl.formatMessage({ id: 'exam.question.col.difficulty' })}</th>
                  {canWrite && <th style={cellStyle}>{intl.formatMessage({ id: 'exam.question.col.actions' })}</th>}
                </tr>
              </thead>
              <tbody>
                {items.map((item) => {
                  const type = item.field_values['type']
                  const status = item.field_values['status']
                  return (
                    <tr key={item.record_id} data-testid={`question-row-${item.record_id}`}>
                      <td style={cellStyle}>{localizedText(item.field_values['stem'], locale)}</td>
                      <td style={cellStyle}>
                        {typeof type === 'string'
                          ? intl.formatMessage({ id: `exam.question.type.${type}`, defaultMessage: type })
                          : ''}
                      </td>
                      <td style={cellStyle}>
                        {typeof status === 'string'
                          ? intl.formatMessage({ id: `exam.question.status.${status}`, defaultMessage: status })
                          : ''}
                      </td>
                      <td style={cellStyle}>
                        <DifficultyBadge value={item.field_values['difficulty']} />
                      </td>
                      {canWrite && (
                        <td style={cellStyle}>
                          <Button
                            variant="ghost"
                            size="sm"
                            data-testid={`question-edit-${item.record_id}`}
                            onClick={() => navigate(`/admin/questions/${encodeURIComponent(item.record_id)}/edit`)}
                          >
                            {intl.formatMessage({ id: 'exam.question.edit' })}
                          </Button>
                        </td>
                      )}
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
          {nextCursor && (
            <Button variant="secondary" size="md" data-testid="question-next-page" onClick={() => setCursor(nextCursor)}>
              {intl.formatMessage({ id: 'exam.question.nextPage' })}
            </Button>
          )}
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

export default function QuestionBankPage() {
  return (
    <ExamIntlProvider>
      <QuestionBankPageInner />
    </ExamIntlProvider>
  )
}
