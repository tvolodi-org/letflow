/** Harness fixtures of the Metrics page (T-1501). The endpoint answers Prometheus text, which the shared JSON fixture
 *  seam cannot send, so a small wrapper answers GET /metrics itself (installed after the harness seam, before the page
 *  mounts). `metrics`: default = families, empty = no families, loading = never answers, error = 500.
 *  `metrics-unavailable`: the origin answers 200 HTML (the SPA fallback), the page shows "not available". */
import { useEffect, useState, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import HealthDashboardPage from '@/pages/admin/HealthDashboardPage'
import MetricsPage from '@/pages/admin/MetricsPage'
import { MetricsSummaryPanel } from '@/pages/admin/MetricsSummaryPanel'
import { parsePrometheusText } from '@/api/metrics'
import type { UserSession } from '@/types/api'
import type { HarnessScreen, HarnessState } from '../types'

const promText = (errors: number, requests = 1204): string => [
  '# HELP letflow_http_requests_total Requests served',
  '# TYPE letflow_http_requests_total counter',
  `letflow_http_requests_total{method="GET",route_template="/api/instances",status="200"} ${requests}`,
  'letflow_http_requests_total{method="POST",route_template="/api/records",status="500"} 87',
  '# TYPE letflow_http_errors_total counter',
  `letflow_http_errors_total{route_template="/api/records"} ${errors}`,
  'letflow_http_errors_total{route_template="/api/instances"} 3',
  '# TYPE letflow_db_query_duration_seconds histogram',
  'letflow_db_query_duration_seconds_bucket{query_type="read",le="0.5"} 900',
  'letflow_db_query_duration_seconds_bucket{query_type="read",le="1.0"} 940',
  'letflow_db_query_duration_seconds_bucket{query_type="read",le="+Inf"} 1000',
  '# TYPE letflow_event_append_duration_seconds histogram',
  'letflow_event_append_duration_seconds_bucket{le="0.5"} 500',
  'letflow_event_append_duration_seconds_bucket{le="1.0"} 500',
  'letflow_event_append_duration_seconds_bucket{le="+Inf"} 500',
  '# TYPE letflow_active_instances_last_refresh_timestamp_seconds gauge',
  `letflow_active_instances_last_refresh_timestamp_seconds ${Math.floor(Date.now() / 1000) - 30}`,
  '# HELP letflow_engine_active_instances Running instances',
  '# TYPE letflow_engine_active_instances gauge',
  'letflow_engine_active_instances 14',
].join('\n')
const PROM_NOW = (): string => promText(87)
const HTML = '<!doctype html><html><head><title>Letflow</title></head><body><div id="root"></div></body></html>'

const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: 'u1' })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: 'u1', permissions: ['MetricsRead'] },
}

function MetricsSeam({ state, html }: { state: HarnessState; html: boolean }) {
  const [ready, setReady] = useState(false)
  useEffect(() => {
    const original = window.fetch
    window.fetch = (input, init) => {
      const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      if (new URL(raw, 'http://harness.invalid').pathname !== '/metrics') return original(input, init)
      if (state === 'loading') return new Promise<Response>(() => {})
      if (state === 'error') return Promise.resolve(new Response('boom', { status: 500 }))
      const body = html ? HTML : state === 'empty' ? '' : PROM_NOW()
      return Promise.resolve(new Response(body, { status: 200, headers: { 'Content-Type': html ? 'text/html' : 'text/plain' } }))
    }
    setReady(true)
    return () => {
      window.fetch = original
    }
  }, [state, html])
  return ready ? <MetricsPage /> : <></>
}

const HEALTH_ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: true, user_id: 'u1', permissions: ['TenantsManage'] },
}

const READY_OK = { status: 'ready', checks: { database: 'ok', migrations: 'ok', secrets_key: 'ok', identity: 'ok' } }
const READY_IDENTITY_FAIL = {
  status: 'not_ready',
  failing: ['identity'],
  checks: { database: 'ok', migrations: 'ok', secrets_key: 'ok', identity: 'fail' },
}
const hoursAgo = (h: number): string => new Date(Date.now() - h * 3_600_000).toISOString()
const BACKUP_OK = {
  configured: true,
  jobs: [
    { job: 'dump', state: 'ok', ts: hoursAgo(6), age_seconds: 6 * 3600 },
    { job: 'base', state: 'ok', ts: hoursAgo(48), age_seconds: 48 * 3600 },
    { job: 'prune', state: 'ok', ts: hoursAgo(6), age_seconds: 6 * 3600 },
    { job: 'restore_test', state: 'ok', ts: hoursAgo(72), age_seconds: 72 * 3600 },
  ],
}
const BACKUP_BAD = {
  configured: true,
  jobs: [
    { job: 'dump', state: 'stale', ts: hoursAgo(50), age_seconds: 50 * 3600 },
    { job: 'base', state: 'missing', ts: null, age_seconds: null },
    { job: 'prune', state: 'ok', ts: hoursAgo(6), age_seconds: 6 * 3600 },
    { job: 'restore_test', state: 'failed', ts: hoursAgo(72), age_seconds: 72 * 3600 },
  ],
}

/**
 * `health`: default = the server answers, every part ready, backups fresh; empty = backup status not
 * configured here; error = the server does not answer (/health 500, /ready 503 with every part failing,
 * backup 500). `degraded`: identity failing, one backup stale and one failed.
 */
function HealthSeam({ state, degraded = false }: { state: HarnessState; degraded?: boolean }) {
  const [ready, setReady] = useState(false)
  useEffect(() => {
    const original = window.fetch
    const json = (status: number, body: unknown) =>
      Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
    window.fetch = (input, init) => {
      const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      const path = new URL(raw, 'http://harness.invalid').pathname
      const isHealth = path.endsWith('/health')
      const isReady = path === '/ready'
      const isBackup = path.endsWith('/platform-status/backup')
      if (!isHealth && !isReady && !isBackup) return original(input, init)
      if (state === 'loading' && !isHealth) return new Promise<Response>(() => {})
      if (state === 'error') {
        if (isReady) return json(503, { status: 'not_ready', failing: ['database', 'migrations', 'secrets_key', 'identity'], checks: { database: 'fail', migrations: 'fail', secrets_key: 'fail', identity: 'fail' } })
        return Promise.resolve(new Response('boom', { status: 500 }))
      }
      if (isHealth) return json(200, {})
      if (isReady) return degraded ? json(503, READY_IDENTITY_FAIL) : json(200, READY_OK)
      if (state === 'empty') return json(200, { configured: false, jobs: [] })
      return json(200, degraded ? BACKUP_BAD : BACKUP_OK)
    }
    setReady(true)
    return () => {
      window.fetch = original
    }
  }, [state, degraded])
  return ready ? <HealthDashboardPage /> : <></>
}

function screen(name: string, html: boolean): HarnessScreen {
  return {
    name,
    routes: [],
    render: ({ state }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <MetricsSeam state={state} html={html} />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

/** Two readings a minute apart, so the rate cards show real figures: errors rising fast = red errors-per-minute card. */
function RisingPanel() {
  const [t0] = useState(() => Date.now() - 60_000)
  const [reading, setReading] = useState({ errors: 87, requests: 1204, at: t0 })
  useEffect(() => {
    setReading({ errors: 387, requests: 4204, at: Date.now() })
  }, [])
  return <MetricsSummaryPanel families={parsePrometheusText(promText(reading.errors, reading.requests))} dataUpdatedAt={reading.at} />
}

export const metricsScreens: HarnessScreen[] = [
  screen('metrics', false),
  screen('metrics-unavailable', true),
  {
    name: 'health',
    routes: [],
    render: ({ state }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={HEALTH_ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <HealthSeam state={state} />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'health-degraded',
    routes: [],
    render: ({ state }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={HEALTH_ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <HealthSeam state={state} degraded />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'metrics-red',
    routes: [],
    render: (): ReactElement => (
      <div className="lf-main">
        <main className="lf-content">
          <RisingPanel />
        </main>
      </div>
    ),
  },
]
