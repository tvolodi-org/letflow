/** Harness fixtures of master-detail slice 7 (T-1893): the real AppShell around the DLQ and the webhook
 *  subscriptions screens on ListDetail. `*-shell` has no record open (empty state, collapse and reload);
 *  `dlq-shell-open` has the first record open (narrow Back). The webhooks record is chosen by `?subscription=`; the harness pins the location, so
 *  Back cannot clear it here (the unit test WebhooksPage.listDetail covers that). */
import { lazy, Suspense, useEffect, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import DlqPage from '@/pages/dlq/DlqPage'
import WebhooksPage from '@/pages/dlq/WebhooksPage'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import type { FixtureRoute, HarnessScreen } from '../types'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

const access: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['DlqOperate', 'WebhooksManage'] },
}

function inShell(page: ReactElement): HarnessScreen['render'] {
  return () => (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={access}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>
                  <Route path="/*" element={page} />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

/** Clicks the first list row once it appears (the -shell-open fixture of the DLQ). */
function AutoSelectFirst({ selector }: { selector: string }) {
  useEffect(() => {
    let tries = 0
    const timer = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>(selector)
      tries += 1
      if (el) el.click()
      if (el || tries > 120) window.clearInterval(timer)
    }, 50)
    return () => window.clearInterval(timer)
  }, [selector])
  return null
}

const dlqRows = [
  { id: 'dlq-0001', entry_type: 'event', reason: 'Handler timed out after 30 s', retry_count: 2, retry_limit: 5, status: 'pending', instance_id: 'inst-0001', created_at: '2026-11-10T09:00:00Z' },
  { id: 'dlq-0002', entry_type: 'webhook', reason: 'Target answered 502', retry_count: 5, retry_limit: 5, status: 'retrying', instance_id: null, created_at: '2026-11-10T09:30:00Z' },
]
const hooks = [
  { id: 'wh-0001', subscription_id: 'wh-0001', target_url: 'https://example.com/webhooks/bpm', event_types: ['task.completed', 'instance.started'], status: 'ACTIVE', created_at: '2026-11-09T08:00:00Z' },
  { id: 'wh-0002', subscription_id: 'wh-0002', target_url: 'https://example.org/hooks/in', event_types: ['instance.errored'], status: 'PAUSED', created_at: '2026-11-09T09:00:00Z' },
]

const routes: FixtureRoute[] = [
  { match: (p, m) => p === '/api/v1/dlq' && m === 'GET', reply: (s) => ({ status: 200, body: { items: s === 'empty' ? [] : dlqRows, next_cursor: null, count: dlqRows.length } }) },
  { match: (p, m) => /^\/api\/v1\/dlq\/[^/]+$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: dlqRows[0] }) },
  { match: (p, m) => p === '/api/v1/webhooks/subscriptions' && m === 'GET', reply: (s) => ({ status: 200, body: { items: s === 'empty' ? [] : hooks } }) },
  {
    match: (p, m) => /^\/api\/v1\/webhooks\/subscriptions\/[^/]+\/deliveries$/.test(p) && m === 'GET',
    reply: () => ({ status: 200, body: { items: [{ delivery_id: 'd1', subscription_id: 'wh-0001', event_type: 'task.completed', status: 'SUCCESS', http_status_code: 200, attempted_at: '2026-11-10T10:00:00Z', attempt_count: 1, max_attempts: 5, last_error: null }] } }),
  },
]

export const listDetailSlice7Screens: HarnessScreen[] = [
  { name: 'dlq-shell', routes: [...makeRoutes(null), ...routes], initialPath: '/dlq', render: inShell(<DlqPage />) },
  {
    name: 'dlq-shell-open',
    routes: [...makeRoutes(null), ...routes],
    initialPath: '/dlq',
    render: inShell(
      <>
        <DlqPage />
        <AutoSelectFirst selector="[data-testid='datatable-row']" />
      </>,
    ),
  },
  { name: 'webhooks-shell', routes: [...makeRoutes(null), ...routes], initialPath: '/webhooks', render: inShell(<WebhooksPage />) },
  {
    name: 'webhooks-shell-open',
    routes: [...makeRoutes(null), ...routes],
    initialPath: '/webhooks?subscription=wh-0001',
    render: inShell(<WebhooksPage />),
  },
]
