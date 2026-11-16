/** Harness fixtures of the owner inbox of problem reports (T-2007). Dev only, invented data.
 *  `problem-reports-shell`: SR-14 open in the Row layout (the real AppShell); `-shell-list`: no record chosen;
 *  `-closed`: a closed report on its Decision tab; `-question`: SR-13 (question sent); `-dialog`: the Answer dialog open;
 *  `-dialog-error`: the decision dialog with a field error; `-tabs`: the Tabs layout; `-xss`: customer text with markup;
 *  `-notfound`; `-forbidden`. The list answers `empty` and `error` states; a decision POST answers the new status. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { RequirePermission } from '@/auth/access'
import type { AccessState } from '@/auth/access/types'
import ProblemReportsPage from '@/pages/admin/problem-reports/ProblemReportsPage'
import { DecisionDialog } from '@/pages/admin/problem-reports/DecisionDialog'
import { ProblemReportsIntlProvider } from '@/pages/admin/problem-reports/ProblemReportsIntlProvider'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { AutoSelectFirst, inShell } from './listDetailSlice5'

const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: true, permissions: ['ProblemReportsManage', 'TenantsManage'] } }
const DENIED: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['InstancesRead'] } }
const AUTH = {
  session: { token: 'fixture', display_name: 'Platform Owner', tenant_id: 'platform-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

const TEXT_14 =
  'I pressed Save on the asset card and nothing happened. The button only spins.\n\nThis is the third time today. I am working from the warehouse tablet, the signal is weak there, but the same card saved fine yesterday. VeryLongUnbrokenTokenForTheNarrowScreenCheck_0123456789_abcdefghijklmnopqrstuvwxyz_0123456789'
const EVIL = '<img src=x onerror="window.__pwned=1"><script>window.__pwned=2</script> **bold** <b>not bold</b>'

const reporter = { tenant_id: 'tenant-1', tenant_name: 'Steppe Foods', user_id: 'user-1', name: 'Aida Nurova', roles: ['Storekeeper'], permissions: Array.from({ length: 40 }, (_, i) => `ExamplePermission${i + 1}`) }
const CONTEXT = {
  route: '/admin/assets/documents/opening',
  ui_language: 'ru',
  browser: { user_agent: 'Mozilla/5.0 (Linux; Android 13) Chrome/120.0', viewport: '1280x800', language: 'ru-RU' },
  actions: Array.from({ length: 8 }, (_, i) => ({ at: `2026-11-15T08:5${i}:00Z`, kind: i % 3 === 0 ? 'click' : i % 3 === 1 ? 'input' : 'navigate', name: ['Open card', 'Edit price', 'Save', 'Save', 'Save', 'Back', 'Open card', 'Save'][i] })),
  requests: [
    { at: '2026-11-15T08:55:00Z', method: 'GET', path: '/api/v1/assets/cards/1', status: 200, trace_id: 'tr-100' },
    { at: '2026-11-15T08:56:10Z', method: 'POST', path: '/api/v1/assets/cards/1/save', status: 500, error_code: 'internal_error', trace_id: 'tr-101' },
    { at: '2026-11-15T08:57:00Z', method: 'POST', path: '/api/v1/assets/cards/1/save', status: 504, error_code: 'timeout', trace_id: 'tr-102' },
  ],
  crash: { name: 'TypeError', message: "Cannot read properties of undefined (reading 'id')" },
  entity_ids: { asset_card: 'AC-000123', document: 'DOC-000044' },
}

type Det = Record<string, unknown>
const report = (id: string, number: string, status: string, over: Det = {}): Det => ({
  id, number, class: 'problem', status, last_action: null, received_at: '2026-11-15T09:00:00Z', decided_at: null,
  decided_by_user_id: null, reporter, text: TEXT_14, context: CONTEXT, server_version: '1.8.3', trace_id: 'tr-101',
  reply_text: null, dev_summary: null, ...over,
})
const REPORTS: Record<string, Det> = {
  r14: report('r14', 'SR-14', 'received'),
  r13: report('r13', 'SR-13', 'in_work', { last_action: 'ask', decided_at: '2026-11-15T09:30:00Z', received_at: '2026-11-14T16:20:00Z', text: 'The stock count shows a wrong total.', reply_text: 'Which count document do you mean?' }),
  r12: report('r12', 'SR-12', 'answered', {
    last_action: 'answer', received_at: '2026-11-13T10:00:00Z', decided_at: '2026-11-13T12:00:00Z', text: 'How do I print the card?',
    reply_text: 'Open the card and press Print, then pick Official form.', dev_summary: 'Question about printing; no defect.',
  }),
  rxss: report('rxss', 'SR-99', 'received', { text: EVIL, context: { actions: [{ at: 't', kind: 'click', name: '<b>x</b>' }] } }),
}
const summary = (r: Det) => ({
  id: r.id, number: r.number, class: 'problem', status: r.status, last_action: r.last_action, received_at: r.received_at, decided_at: r.decided_at,
  reporter: { tenant_name: reporter.tenant_name, name: reporter.name }, text_preview: String(r.text).slice(0, 140),
})
const NEXT: Record<string, string> = { develop: 'in_work', ask: 'in_work', fixed: 'fixed', reject: 'not_done', answer: 'answered' }

const preferences = (layout: 'row' | 'tabs'): FixtureRoute => ({
  match: (p, m) => m === 'GET' && p === '/api/v1/me/preferences',
  reply: () => ({ status: 200, body: { effective: { 'ui.document_layout': layout }, own: {}, tenant_defaults: {} } }),
})

const routes = (layout: 'row' | 'tabs', ids: string[]): FixtureRoute[] => [
  preferences(layout),
  {
    match: (p, m) => m === 'GET' && p === '/api/v1/platform-problem-reports',
    reply: (s) => {
      if (s === 'error') return { status: 500, body: { title: 'internal_error', status: 500 } }
      if (s === 'empty') return { status: 200, body: { reports: [], next_before: null } }
      return { status: 200, body: { reports: ids.map((id) => summary(REPORTS[id])), next_before: null } }
    },
  },
  {
    match: (p, m) => m === 'POST' && /^\/api\/v1\/platform-problem-reports\/[^/]+\/decision$/.test(p),
    reply: (_s, p, body) => {
      const r = REPORTS[p.split('/')[4] ?? '']
      const b = (body ?? {}) as { action?: string; text?: string }
      if (!r) return { status: 404, body: { title: 'not_found', status: 404 } }
      return { status: 200, body: { ...r, status: NEXT[b.action ?? ''] ?? r.status, last_action: b.action ?? null, decided_at: '2026-11-15T10:00:00Z', reply_text: b.text ?? null } }
    },
  },
  {
    match: (p, m) => m === 'GET' && p.startsWith('/api/v1/platform-problem-reports/'),
    reply: (_s, p) => {
      const r = REPORTS[p.split('/').pop() ?? '']
      return r ? { status: 200, body: r } : { status: 404, body: { title: 'not_found', status: 404 } }
    },
  },
]

const OPEN = ['r14', 'r13']
const page = <ProblemReportsPage />

function screen(name: string, path: string, over: { layout?: 'row' | 'tabs'; ids?: string[]; click?: string } = {}): HarnessScreen {
  const body = (
    <>
      {page}
      {over.click ? <AutoSelectFirst selector={over.click} /> : null}
    </>
  )
  return { name, initialPath: path, routes: routes(over.layout ?? 'row', over.ids ?? OPEN), render: inShell(ACCESS, body) }
}

const dialogError: HarnessScreen = {
  name: 'problem-reports-dialog-error',
  initialPath: '/admin/problem-reports',
  routes: [],
  render: () => (
    <ProblemReportsIntlProvider>
      <DecisionDialog
        action="develop"
        text="Save does nothing on the asset card for Aida Nurova"
        onText={() => undefined}
        fieldError="Write the summary in your own words: it copies the report text or a name."
        busy={false}
        onConfirm={() => undefined}
        onCancel={() => undefined}
      />
    </ProblemReportsIntlProvider>
  ),
}

const forbidden: HarnessScreen = {
  name: 'problem-reports-forbidden',
  initialPath: '/admin/problem-reports',
  routes: [],
  render: () => (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={DENIED}>
        <main className="lf-content">
          <RequirePermission permission="ProblemReportsManage" platformOnly>
            {page}
          </RequirePermission>
        </main>
      </AccessStateProvider>
    </AuthContext.Provider>
  ),
}

export const problemReportsScreens: HarnessScreen[] = [
  screen('problem-reports-shell', '/admin/problem-reports?report=r14'),
  screen('problem-reports-shell-list', '/admin/problem-reports'),
  screen('problem-reports-closed', '/admin/problem-reports?report=r12&status=closed', { ids: ['r12'], click: '#pr-tab-decision' }),
  screen('problem-reports-question', '/admin/problem-reports?report=r13', { ids: ['r13', 'r14'] }),
  screen('problem-reports-dialog', '/admin/problem-reports?report=r14', { click: '[data-testid="pr-action-answer"]' }),
  dialogError,
  screen('problem-reports-tabs', '/admin/problem-reports?report=r14', { layout: 'tabs' }),
  screen('problem-reports-xss', '/admin/problem-reports?report=rxss', { ids: ['rxss'] }),
  screen('problem-reports-notfound', '/admin/problem-reports?report=gone', { ids: ['r14'] }),
  forbidden,
]
