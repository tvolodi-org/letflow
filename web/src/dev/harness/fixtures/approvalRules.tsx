/** Harness fixtures for the Approval rules admin screen (T-1989, four-eyes switch slice 4).
 *  One screen name per state, because the screenshot tool names files without the state. The draft, the
 *  pre-selected row and the on-mount submit are HARNESS-ONLY props of the page (the tool cannot click). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import ApprovalRulesPage, { type ApprovalRulesPageProps } from '@/pages/admin/approval-rules/ApprovalRulesPage'
import { ruleKey } from '@/pages/admin/approval-rules/approvalRulesModel'
import type { ApprovalRule } from '@/api/approvalRules'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH: AuthContextValue = {
  session: {
    token: 'harness.' + btoa(JSON.stringify({ sub: 'harness-id' })) + '.sig',
    tenant_id: 'harness-tenant',
    display_name: 'Harness Admin',
    loginSource: 'oidc',
    tenant_slug: 'harness',
    tenant_display_name: 'Harness Co',
    tenant_type: 'production',
  } as UserSession,
  isAuthenticated: true,
  isLoading: false,
  login: () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
} as unknown as AuthContextValue

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['ApprovalRulesManage', 'MyAccessRead'] },
}

const BASE = {
  node_id: 'approve',
  node_label: null,
  in_active_definition: true,
  changed_by: null,
  changed_by_name: null,
  changed_at: null,
  reason: null,
}
const ON: ApprovalRule = { ...BASE, definition_name: 'assets_opening', four_eyes: true }
const DEFAULT_OFF: ApprovalRule = { ...BASE, definition_name: 'stock_quick_count', four_eyes: false }
const OFF: ApprovalRule = {
  ...BASE,
  definition_name: 'stock_opening',
  four_eyes: false,
  changed_by: '5c1f4b0e-0000-4000-8000-000000000001',
  changed_by_name: 'Aigerim Sadykova',
  changed_at: '2026-11-10T09:30:00Z',
  reason: 'One-person company: the director issues and approves',
}
const ORPHAN_OFF: ApprovalRule = { ...BASE, definition_name: 'assets_opening_v0', four_eyes: false, in_active_definition: false, changed_by_name: 'Aigerim Sadykova', changed_at: '2026-10-02T11:00:00Z', reason: 'Old version' }
const ORPHAN_ON: ApprovalRule = { ...BASE, definition_name: 'stock_opening_v0', four_eyes: true, in_active_definition: false, changed_by_name: 'Aigerim Sadykova', changed_at: '2026-10-03T11:00:00Z', reason: 'Old version' }
const ITEMS = [ON, OFF, ORPHAN_OFF, ORPHAN_ON]

interface Spec {
  items?: ApprovalRule[]
  get?: { status: number; body?: unknown } | 'pending'
  put?: { status: number; body: unknown }
  props?: ApprovalRulesPageProps
}

function routesOf(spec: Spec): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/approval-rules' && method === 'GET',
      pending: spec.get === 'pending',
      reply: () =>
        spec.get && spec.get !== 'pending'
          ? { status: spec.get.status, body: spec.get.body ?? { status: spec.get.status, message: 'error' } }
          : { status: 200, body: { items: spec.items ?? ITEMS } },
    },
    {
      match: (path, method) => path.startsWith('/api/v1/approval-rules/') && method === 'PUT',
      reply: () => spec.put ?? { status: 200, body: ON },
    },
  ]
}

function mkScreen(name: string, spec: Spec = {}): HarnessScreen {
  return {
    name,
    routes: routesOf(spec),
    render: ({ lang }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <ApprovalRulesPage locale={lang} {...spec.props} />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

const key = (r: ApprovalRule) => ruleKey(r)

export const approvalRulesScreens: HarnessScreen[] = [
  mkScreen('approval-rules-list'),
  mkScreen('approval-rules-off', { props: { initialSelectedKey: key(OFF) } }),
  mkScreen('approval-rules-switching-off', { props: { initialSelectedKey: key(ON), initialDraft: { fourEyes: false, reason: '' } } }),
  mkScreen('approval-rules-reason-error', {
    put: { status: 422, body: { status: 422, detail: 'invalid_reason' } },
    props: { initialSelectedKey: key(ON), initialDraft: { fourEyes: false, reason: 'x' }, submitOnMount: true },
  }),
  mkScreen('approval-rules-conflict', {
    put: { status: 409, body: { status: 409, detail: 'concurrent_change' } },
    props: { initialSelectedKey: key(ON), initialDraft: { fourEyes: false, reason: 'x' }, submitOnMount: true },
  }),
  mkScreen('approval-rules-orphan', { props: { initialSelectedKey: key(ORPHAN_OFF) } }),
  mkScreen('approval-rules-orphan-on', { props: { initialSelectedKey: key(ORPHAN_ON) } }),
  mkScreen('approval-rules-empty', { items: [] }),
  mkScreen('approval-rules-loading', { get: 'pending' }),
  mkScreen('approval-rules-error', { get: { status: 500 } }),
  mkScreen('approval-rules-denied', { get: { status: 403, body: { status: 403, detail: 'insufficient permissions' } } }),
  mkScreen('approval-rules-default-off', {
    items: [DEFAULT_OFF, ON],
    props: { initialSelectedKey: key(DEFAULT_OFF) },
  }),
  mkScreen('approval-rules-default-on', {
    items: [ON],
    props: { initialSelectedKey: key(ON) },
  }),
]
