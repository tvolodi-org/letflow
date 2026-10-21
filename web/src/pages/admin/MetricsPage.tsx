import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { queryKeys } from '@/api/queryKeys'
import { metricsApi, parsePrometheusText, type PrometheusMetricFamily, type PrometheusMetricSample } from '@/api/metrics'
import { P, useAccess, AccessPending } from '@/auth/access'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'

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
  const isAllowed = access.can(P.MetricsRead)
  const { data, isLoading, isError, error, isFetching, refetch } = usePrometheusMetrics()

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'
  const showParseError = (error as Error | null)?.message === 'PROM_PARSE_ERROR'

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Metrics</h2>
        {isFetching && <span style={{ fontSize: 'var(--text-xs)', color: 'var(--color-info-dark)' }}>Refreshing…</span>}
      </div>

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        columns={[{ widthPercent: 40 }, { widthPercent: 40 }, { widthPercent: 20 }]}
      >
      {showParseError && (
        <div style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: 'var(--radius-sm)', border: '1px solid var(--color-error-border)', background: 'var(--color-error-tint)', color: 'var(--color-error-dark)' }}>
          Metrics payload could not be parsed as Prometheus exposition text.
        </div>
      )}

      {data && data.length === 0 && (
        <div style={{ marginTop: '.5rem', color: 'var(--text-secondary)' }}>No metrics are currently exposed.</div>
      )}

      {(data ?? []).map((family) => (
        <section key={family.name} style={{ marginBottom: '1.25rem', background: 'var(--surface-card)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', overflow: 'hidden' }}>
          <header style={{ padding: '.65rem .8rem', background: 'var(--surface-page)', borderBottom: '1px solid var(--border-default)' }}>
            <div style={{ display: 'flex', gap: '.6rem', alignItems: 'center' }}>
              <strong style={{ fontFamily: 'var(--font-mono)' }}>{family.name}</strong>
              <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', textTransform: 'uppercase' }}>{family.type}</span>
            </div>
            {family.help && <div style={{ marginTop: '.2rem', color: 'var(--text-secondary)', fontSize: 'var(--text-xs)' }}>{family.help}</div>}
          </header>

          <DataTable
            columns={SAMPLE_COLUMNS}
            data={family.samples}
            emptyMessage="No samples for this metric family."
          />
        </section>
      ))}      </QueryStateBoundary>    </div>
  )
}
