/** ExamBuilderListPage — GH 3355 / REQ-602
 *
 *  Entry of the exam builder: the first page of the tenant's exams (each a link to the builder) and
 *  a "Create exam" action that posts an exam with default values and opens it in the builder.
 *  Paging and search are not built (see the REQ-602 design, "left out").
 */

import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl, type IntlShape } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { entitiesApi } from '@/api/entities'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { examAuthoringApi } from './exam.api'
import { ExamIntlProvider } from './ExamIntlProvider'
import { builderQueryKeys } from './builderQueryKeys'
import { newExamDefaults } from './examBuilderModel'

const PAGE_SIZE = 50

function titleOf(intl: IntlShape, value: unknown): string {
  if (value && typeof value === 'object') {
    const map = value as Record<string, unknown>
    const text = [intl.locale, 'en', 'ru', 'kk'].map((l) => map[l]).find((v) => typeof v === 'string' && v !== '')
    if (typeof text === 'string') return text
  }
  return intl.formatMessage({ id: 'exam.builder.list.untitled' })
}

function ExamBuilderListPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [creating, setCreating] = useState(false)
  const [createFailed, setCreateFailed] = useState(false)

  const examsQuery = useQuery({
    queryKey: builderQueryKeys.list(tenantId),
    queryFn: () => entitiesApi.queryRecords('exam', { page_size: PAGE_SIZE }),
    retry: false,
  })
  const items = examsQuery.data?.items ?? []

  async function create() {
    if (creating) return
    setCreating(true)
    setCreateFailed(false)
    try {
      const created = await examAuthoringApi.createRecord('exam', newExamDefaults())
      navigate(`/admin/bilimbaga/exam-builder/${encodeURIComponent(created.record_id)}`)
    } catch {
      setCreateFailed(true)
      setCreating(false)
    }
  }

  return (
    <div data-testid="exam-builder-list-page">
      <PageLayout
        title={intl.formatMessage({ id: 'exam.builder.list.title' })}
        actions={
          <Button variant="primary" size="md" loading={creating} disabled={creating} data-testid="exam-builder-create" onClick={() => void create()}>
            {intl.formatMessage({ id: 'exam.builder.list.create' })}
          </Button>
        }
      >
        {createFailed && (
          <p role="alert" data-testid="exam-builder-create-error">
            {intl.formatMessage({ id: 'exam.builder.list.createError' })}
          </p>
        )}
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
        >
          {items.length === 0 ? (
            <p data-testid="exam-builder-list-empty">{intl.formatMessage({ id: 'exam.builder.list.empty' })}</p>
          ) : (
            <ul data-testid="exam-builder-list">
              {items.map((item) => (
                <li key={item.record_id}>
                  <Link to={`/admin/bilimbaga/exam-builder/${encodeURIComponent(item.record_id)}`}>
                    {titleOf(intl, item.field_values['title'])}
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

export default function ExamBuilderListPage() {
  return (
    <ExamIntlProvider>
      <ExamBuilderListPageInner />
    </ExamIntlProvider>
  )
}
