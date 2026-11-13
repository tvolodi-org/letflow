/** Harness fixtures for master-detail slice 5 (T-1891): the real AppShell around the task inbox and the
 *  module rollouts screen, both on ListDetail. `*-shell` has no record open (empty state, collapse and
 *  reload); `*-shell-open` has one open (narrow Back). */
import { lazy, Suspense, useEffect, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import ModuleRolloutsPage from '@/pages/admin/module-rollouts/ModuleRolloutsPage'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import type { FixtureRoute, HarnessScreen } from '../types'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

function inShell(state: AccessState, page: ReactElement): HarnessScreen['render'] {
  return () => (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={state}>
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

/** Opens the first list row once it appears (used for the -shell-open fixture). */
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

const ME = '11111111-2222-4333-8444-555555555555'
const T1 = 'cccccccc-0000-4000-8000-000000000001'
const I1 = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001'

const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString()
const taskRows = [
  { id: T1, instance_id: I1, token_id: 't1', node_id: 'post', node_name: 'post', status: 'PENDING', assignee_type: 'USER', assignee_ref: ME, definition_name: 'Stock flow', created_at: ago(5) },
]

const taskRoutes: FixtureRoute[] = [
  { match: (p, m) => p === '/api/v1/tasks/inbox' && m === 'GET', reply: (s) => ({ status: 200, body: { items: s === 'empty' ? [] : taskRows, next_cursor: null, count: taskRows.length } }) },
  { match: (p, m) => p.startsWith('/api/v1/tasks/') && m === 'GET', reply: () => ({ status: 200, body: taskRows[0] }) },
  { match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/history$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: [{ actor_id: ME }] }) },
  { match: (p, m) => /^\/api\/v1\/instances\/[^/]+$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: { id: I1, variables: {} } }) },
  { match: (p, m) => p === '/api/v1/entities/query' && m === 'POST', reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
]
const taskAccess: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, user_id: ME, permissions: ['TasksRead', 'TasksComplete'] },
}

const rolloutRow = { rollout: { id: 'r-run', module_id: 'assets', to_version: '1.4.0', status: 'running', halt_after: 3, consecutive_failures: 0, started_at: '2026-11-10T09:00:00Z', completed_at: null, halted_at: null }, counts: { succeeded: 1, pending: 1 } }
const rolloutDetail = { rollout: rolloutRow.rollout, outcomes: [{ tenant_id: 'ten-1', status: 'succeeded', error_code: null, plan_hash: null, attempted_at: '2026-11-10T09:05:00Z', completed_at: '2026-11-10T09:06:00Z' }] }

const rolloutRoutes: FixtureRoute[] = [
  { match: (p, m) => m === 'GET' && p === '/api/v1/platform-module-rollouts', reply: (s) => ({ status: 200, body: { rollouts: s === 'empty' ? [] : [rolloutRow] } }) },
  { match: (p, m) => m === 'GET' && p.startsWith('/api/v1/platform-module-rollouts/'), reply: () => ({ status: 200, body: rolloutDetail }) },
  { match: (p, m) => m === 'GET' && p === '/api/v1/tenants', reply: () => ({ status: 200, body: { items: [{ tenant_id: 'ten-1', slug: 'logistics-co', display_name: 'Acme Logistics' }], next_cursor: null } }) },
]
const rolloutAccess: AccessState = { status: 'ready', info: { roles: [], platform_tenant: true, permissions: ['ModuleRolloutsManage', 'TenantsManage'] } }

export function listDetailSlice5Screens(taskInboxRoutes: FixtureRoute[], moduleRolloutsRoutes: FixtureRoute[]): HarnessScreen[] {
  return [
    {
      name: 'tasks-inbox-shell',
      routes: [...makeRoutes(null), ...taskInboxRoutes],
      initialPath: '/tasks',
      render: inShell(taskAccess, <TaskInboxPage />),
    },
    {
      name: 'tasks-inbox-shell-open',
      routes: [...makeRoutes(null), ...taskInboxRoutes],
      initialPath: '/tasks',
      render: inShell(
        taskAccess,
        <>
          <TaskInboxPage />
          <AutoSelectFirst selector="[data-testid='task-row']" />
        </>,
      ),
    },
    {
      name: 'module-rollouts-shell',
      routes: [...makeRoutes(null), ...moduleRolloutsRoutes],
      initialPath: '/admin/module-rollouts',
      render: inShell(rolloutAccess, <ModuleRolloutsPage />),
    },
    {
      name: 'module-rollouts-shell-open',
      routes: [...makeRoutes(null), ...moduleRolloutsRoutes],
      initialPath: '/admin/module-rollouts?rollout=r-run',
      render: inShell(rolloutAccess, <ModuleRolloutsPage />),
    },
  ]
}

/** Default routes used by the slice 5 layout fixtures (re-exported for the registry). */
export { taskRoutes as slice5TaskRoutes, rolloutRoutes as slice5RolloutRoutes }
