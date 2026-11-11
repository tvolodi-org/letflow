/** Harness fixtures of T-1753: the Instance detail page (ru/kk completeness sweep), through the real page and hooks
 *  with fixture answers. Screens: instance-detail (history tab), instance-detail-graph, instance-detail-timeline.
 *  The tab is entered by clicking its button (matched by the catalogue label of the harness language). Invented data. */
import { useEffect, useRef, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'
import { instanceDetailMessages } from '@/pages/instances/instanceDetailMessages'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessLang, HarnessScreen } from '../types'

const GRAPH = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'submit', node_type: 'HUMAN_TASK', label: 'Submit purchase request', attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'submit' },
    { id: 'e2', source: 'submit', target: 'end' },
  ],
}

const EMPTY = { items: [], next_cursor: null, count: 0 }

const routes: FixtureRoute[] = [
  {
    match: (p, m) => /^\/api\/v1\/instances\/[^/]+$/.test(p) && m === 'GET',
    reply: (state) =>
      state === 'empty'
        ? { status: 200, body: { instance_id: 'inst-detail', id: 'inst-detail', definition_id: 'def-detail', status: 'COMPLETED', current_nodes: [], definition_snapshot: null, variables: {}, correlation_key: null, started_at: '2026-11-09T09:00:00Z', completed_at: '2026-11-09T12:10:00Z' } }
        : {
            status: 200,
            body: {
              id: 'inst-detail',
              instance_id: 'inst-detail',
              definition_id: 'def-detail',
              status: 'ACTIVE',
              current_nodes: ['submit'],
              definition_snapshot: GRAPH,
              variables: { amount: 120000, requester: 'A. Example' },
              correlation_key: 'PR-2026-0042',
              started_at: '2026-11-09T09:00:00Z',
              updated_at: '2026-11-09T09:30:00Z',
              completed_at: null,
            },
          },
  },
  {
    match: (p, m) => p.startsWith('/api/v1/definitions/') && m === 'GET',
    reply: () => ({ status: 200, body: { id: 'def-detail', name: 'Purchase request', version: '3', status: 'ACTIVE', graph: GRAPH } }),
  },
  {
    match: (p, m) => p === '/api/v1/tasks' && m === 'GET',
    reply: (state) => ({
      status: 200,
      body:
        state === 'empty'
          ? EMPTY
          : { items: [{ id: 'task-0001-aaaa', instance_id: 'inst-detail', token_id: 't1', node_id: 'submit', node_name: 'Submit purchase request', status: 'PENDING', assignee_ref: 'u-requester', created_at: '2026-11-09T09:00:00Z' }], next_cursor: null, count: 1 },
    }),
  },
  {
    match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/(history|timeline)$/.test(p) && m === 'GET',
    reply: () => ({ status: 200, body: EMPTY }),
  },
  {
    match: (p, m) => p.startsWith('/api/v1/') && m === 'GET',
    reply: () => ({ status: 200, body: EMPTY }),
  },
]

const AUTH = {
  session: { token: 'h.e30.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: 'u-harness', permissions: ['InstancesRead', 'InstancesCancel', 'DefinitionsRead'] },
}

type Tab = 'tabGraph' | 'tabTimeline' | null

function TabEntry({ tab, lang, children }: { tab: Tab; lang: HarnessLang; children: ReactElement }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!tab) return
    const label = instanceDetailMessages[lang][tab]
    const id = window.setInterval(() => {
      const btn = Array.from(ref.current?.querySelectorAll('button') ?? []).find((b) => b.textContent?.trim() === label)
      if (btn) {
        btn.click()
        window.clearInterval(id)
      }
    }, 100)
    return () => window.clearInterval(id)
  }, [tab, lang])
  return <div ref={ref}>{children}</div>
}

function screen(name: string, tab: Tab): HarnessScreen {
  return {
    name,
    initialPath: '/instances/inst-detail',
    routePattern: '/instances/:id',
    routes,
    render: ({ lang }) => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <TabEntry tab={tab} lang={lang}>
            <InstanceDetailPage />
          </TabEntry>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

export const instanceDetailScreens: HarnessScreen[] = [
  screen('instance-detail', null),
  screen('instance-detail-graph', 'tabGraph'),
  screen('instance-detail-timeline', 'tabTimeline'),
]
