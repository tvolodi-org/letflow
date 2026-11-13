/** ReportsIndexPage — T-1874. The "Reports" entry of the left menu (WORK): every saved report the caller may see,
 *  grouped by module, each linking to the report screen (`/entities/<type>/reports?open=<id>`).
 *  Presentation only: it shows what `GET /entity-views` returned; the server decides what the caller may see. */
import React, { useMemo } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { reportViewsApi } from '@/api/entityViews'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { getReportGroupFor } from '@/modules/registry'
import { PageLayout } from '@/components/ui/PageLayout'
import { EmptyState } from '@/components/ui/EmptyState'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError } from '@/utils/classifyError'
import type { ReportView } from '@/types/api'
import { reportDisplayName } from './reportDisplayName'

interface Group {
  key: string
  label: string
  other: boolean
  items: { report: ReportView; name: string }[]
}

function ReportsIndexPageInner(): React.ReactElement {
  const intl = useIntl()
  const locale = useUiLocale()
  const tenantKeys = useTenantScopedQueryKeys()
  const modules = useInstalledModules()
  const query = useQuery({
    queryKey: tenantKeys.entities.reportsAll(),
    queryFn: () => reportViewsApi.listAll(),
    retry: false,
  })
  const installed = modules.data

  const groups = useMemo<Group[]>(() => {
    const byKey = new Map<string, Group>()
    for (const report of query.data?.items ?? []) {
      const claim = getReportGroupFor(installed ?? [], report.entity_type)
      const key = claim ? claim.moduleId : '\u0000other'
      let group = byKey.get(key)
      if (!group) {
        group = {
          key,
          label: claim ? claim.labels[locale] ?? claim.labels.en : intl.formatMessage({ id: 'reports.index.other' }),
          other: !claim,
          items: [],
        }
        byKey.set(key, group)
      }
      group.items.push({ report, name: reportDisplayName(report.name, intl) })
    }
    const list = [...byKey.values()]
    for (const g of list) g.items.sort((a, b) => a.name.localeCompare(b.name, locale))
    // module groups by label, "Other reports" last
    return list.sort((a, b) => (a.other === b.other ? a.label.localeCompare(b.label, locale) : a.other ? 1 : -1))
  }, [query.data, installed, intl, locale])

  return (
    <PageLayout title={intl.formatMessage({ id: 'reports.index.title' })}>
      <p>{intl.formatMessage({ id: 'reports.index.lede' })}</p>
      <div
        data-testid={query.isLoading ? 'reports-index-loading' : undefined}
        aria-label={query.isLoading ? intl.formatMessage({ id: 'reports.index.loading' }) : undefined}
      >
        <QueryStateBoundary
          state={query.isLoading ? 'loading' : query.isError ? classifyError(query.error) : 'success'}
          onRetry={() => void query.refetch()}
        >
          {groups.length === 0 ? (
            <EmptyState
              data-testid="reports-index-empty"
              title={intl.formatMessage({ id: 'reports.index.empty' })}
            />
          ) : (
            groups.map((g) => (
              <section key={g.key} className="lf-reports-index__group" data-testid="reports-index-group" aria-label={g.label}>
                <h2>{g.label}</h2>
                <ul className="lf-reports-index__list">
                  {g.items.map(({ report, name }) => (
                    <li key={report.id}>
                      <Link
                        to={`/entities/${encodeURIComponent(report.entity_type)}/reports?open=${encodeURIComponent(report.id)}`}
                        data-testid={`reports-index-link-${report.id}`}
                      >
                        {name}
                      </Link>
                    </li>
                  ))}
                </ul>
              </section>
            ))
          )}
        </QueryStateBoundary>
      </div>
    </PageLayout>
  )
}

export function ReportsIndexPage(): React.ReactElement {
  return (
    <EntitiesIntlProvider>
      <ReportsIndexPageInner />
    </EntitiesIntlProvider>
  )
}

export default ReportsIndexPage
