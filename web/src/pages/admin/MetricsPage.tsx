import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { queryKeys } from '@/api/queryKeys'
import { metricsApi, parsePrometheusText, type PrometheusMetricFamily, type PrometheusMetricSample } from '@/api/metrics'
import { P, useAccess, AccessPending } from '@/auth/access'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { classifyError, type RendererState } from '@/utils/classifyError'

const MESSAGES = {
  en: {
    title: 'Metrics',
    refreshing: 'Refreshing…',
    unavailable: 'Metrics are not available on this deployment: the /metrics endpoint did not return Prometheus text.',
    unavailableTag: 'Not available',
    none: 'No metrics are currently exposed.',
  },
  ru: {
    title: 'Метрики',
    refreshing: 'Обновление…',
    unavailable: 'Метрики недоступны в этой установке: endpoint /metrics вернул не текст Prometheus.',
    unavailableTag: 'Недоступно',
    none: 'Сейчас метрики не публикуются.',
  },
  kk: {
    title: 'Метрикалар',
    refreshing: 'Жаңартылуда…',
    unavailable: 'Бұл орнатуда метрикалар қолжетімсіз: /metrics endpoint Prometheus мәтінін қайтармады.',
    unavailableTag: 'Қолжетімсіз',
    none: 'Қазір метрикалар жарияланбаған.',
  },
} as const

const SAMPLE_COLUMNS: DataTableColumn<PrometheusMetricSample>[] = [
  { id: 'name', header: 'Sample', accessor: (sample) => <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-sm)' }}>{sample.name}</span> },
  {
    id: 'labels',
    header: 'Labels',
    accessor: (sample) => (
      <span style={{ color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)' }}>
        {Object.entries(sample.labels).length > 0
          ? Object.entries(sample.labels).map(([k, v]) => `${k}=${v}`).join(', ')
          : '—'}
      </span>
    ),
  },
  { id: 'value', header: 'Value', accessor: (sample) => <span style={{ fontFamily: 'var(--font-mono)', fontWeight: 600 }}>{sample.value}</span> },
]

export function usePrometheusMetrics(): UseQueryResult<PrometheusMetricFamily[]> {
  return useQuery({
    queryKey: queryKeys.admin.metrics(),
    queryFn: async () => {
      const text = await metricsApi.prometheusText()
      return parsePrometheusText(text)
    },
    refetchInterval: 30_000,
  })
}

export default function MetricsPage() {
  const access = useAccess()
  const m = MESSAGES[useUiLocale()]
  const isAllowed = access.can(P.MetricsRead)
  const { data, isLoading, isError, error, isFetching, refetch } = usePrometheusMetrics()

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  // A 200 that is not Prometheus text (for example the SPA fallback page) means this origin does not serve
  // /metrics: show a "not available" state instead of the generic failure with a useless Retry.
  const showParseError = isError && (error as Error | null)?.message === 'PROM_PARSE_ERROR'
  const rendererState: RendererState = isLoading ? 'loading' : isError && !showParseError ? classifyError(error) : 'success'

  return (
    <div style={{ padding: '1.5rem', minWidth: 0, maxWidth: '100%' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>{m.title}</h2>
        {isFetching && <span style={{ fontSize: 'var(--text-xs)', color: 'var(--color-info-dark)' }}>{m.refreshing}</span>}
      </div>

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 40 }, { widthPercent: 40 }, { widthPercent: 20 }]}
      >
      {showParseError && (
        <div role="status" style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: 'var(--radius-sm)', border: '1px solid var(--border-default)', background: 'var(--surface-card)', color: 'var(--text-primary)' }}>
          <strong>{m.unavailableTag}.</strong> {m.unavailable}
        </div>
      )}

      {data && data.length === 0 && (
        <div style={{ marginTop: '.5rem', color: 'var(--text-secondary)' }}>{m.none}</div>
      )}

      {(data ?? []).map((family) => (
        <section key={family.name} style={{ marginBottom: '1.25rem', background: 'var(--surface-card)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', overflow: 'hidden', minWidth: 0, maxWidth: '100%' }}>
          <header style={{ padding: '.65rem .8rem', background: 'var(--surface-page)', borderBottom: '1px solid var(--border-default)' }}>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '.3rem .6rem', alignItems: 'center', minWidth: 0 }}>
              <strong style={{ fontFamily: 'var(--font-mono)', overflowWrap: 'anywhere', minWidth: 0 }}>{family.name}</strong>
              <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', textTransform: 'uppercase' }}>{family.type}</span>
            </div>
            {family.help && <div style={{ marginTop: '.2rem', color: 'var(--text-secondary)', fontSize: 'var(--text-xs)' }}>{family.help}</div>}
          </header>

          <div style={{ overflowX: 'auto', maxWidth: '100%' }}>
            <DataTable
              columns={SAMPLE_COLUMNS}
              data={family.samples}
              emptyMessage="No samples for this metric family."
            />
          </div>
        </section>
      ))}      </QueryStateBoundary>    </div>
  )
}
