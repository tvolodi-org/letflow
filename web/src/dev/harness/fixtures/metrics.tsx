/** Harness fixtures of the Metrics page (T-1501). The endpoint answers Prometheus text, which the shared JSON fixture
 *  seam cannot send, so a small wrapper answers GET /metrics itself (installed after the harness seam, before the page
 *  mounts). `metrics`: default = families, empty = no families, loading = never answers, error = 500.
 *  `metrics-unavailable`: the origin answers 200 HTML (the SPA fallback), the page shows "not available". */
import { useEffect, useState, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import MetricsPage from '@/pages/admin/MetricsPage'
import type { UserSession } from '@/types/api'
import type { HarnessScreen, HarnessState } from '../types'

const PROM = [
  '# HELP letflow_http_requests_total Requests served',
  '# TYPE letflow_http_requests_total counter',
  'letflow_http_requests_total{method="GET",route_template="/api/instances",status="200"} 1204',
  'letflow_http_requests_total{method="POST",route_template="/api/records",status="500"} 87',
  '# TYPE letflow_http_errors_total counter',
  'letflow_http_errors_total{route_template="/api/records"} 87',
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
  'letflow_active_instances_last_refresh_timestamp_seconds 1000000000',
  '# HELP letflow_engine_active_instances Running instances',
  '# TYPE letflow_engine_active_instances gauge',
  'letflow_engine_active_instances 14',
].join('\n')
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
      const body = html ? HTML : state === 'empty' ? '' : PROM
      return Promise.resolve(new Response(body, { status: 200, headers: { 'Content-Type': html ? 'text/html' : 'text/plain' } }))
    }
    setReady(true)
    return () => {
      window.fetch = original
    }
  }, [state, html])
  return ready ? <MetricsPage /> : <></>
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

export const metricsScreens: HarnessScreen[] = [screen('metrics', false), screen('metrics-unavailable', true)]
