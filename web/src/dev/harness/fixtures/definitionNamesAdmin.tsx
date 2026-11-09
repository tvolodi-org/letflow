/** Harness fixtures of T-1529: friendly definition names in the definition editor header, the promote
 *  confirmation and the task detail. Invented data only. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import { ConfirmPromoteModal } from '@/components/ui/ConfirmPromoteModal'
import { definitionDisplayText } from '@/components/ui/DefinitionName'
import { TaskDetail } from '@/pages/tasks/TaskDetail'
import { TASK_MESSAGES } from '@/pages/tasks/taskMessages'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const DEF = {
  id: 'd-wo',
  name: 'assets_writeoff',
  version: '1.0.0',
  status: 'ACTIVE',
  description: '',
  graph: { nodes: [], edges: [] },
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-01T09:00:00Z',
}
const TASK = {
  id: 'task-1',
  instance_id: 'inst-0001-aaaa',
  token_id: 'tok-1',
  node_id: 'n2',
  node_name: 'Approve write-off',
  status: 'PENDING',
  assignee_ref: null,
  assignee_type: null,
  definition_name: 'assets_writeoff',
  created_at: '2026-11-08T09:00:00Z',
}

const routes: FixtureRoute[] = [
  { match: (p, m) => m === 'GET' && p === '/api/v1/definitions/d-wo', reply: () => ({ status: 200, body: DEF }) },
  { match: (p, m) => m === 'GET' && p === '/api/v1/tasks/task-1', reply: () => ({ status: 200, body: TASK }) },
  { match: (p, m) => m === 'GET' && p.startsWith('/api/v1/'), reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function PromoteModal() {
  const locale = useUiLocale()
  return (
    <ConfirmPromoteModal
      definitionName="assets_writeoff"
      displayName={definitionDisplayText('assets_writeoff', undefined, locale)}
      onConfirm={() => {}}
      onCancel={() => {}}
      isLoading={false}
    />
  )
}

function Task() {
  const locale = useUiLocale()
  return <TaskDetail taskId="task-1" onClose={() => {}} m={TASK_MESSAGES[locale]} locale={locale} userId="u1" />
}

export const definitionNameAdminScreens: HarnessScreen[] = [
  {
    name: 'definition-names-editor',
    initialPath: '/definitions/d-wo',
    routePattern: '/definitions/:id',
    routes,
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <DefinitionEditorPage />
      </AuthContext.Provider>
    ),
  },
  { name: 'definition-names-promote', routes, render: () => <PromoteModal /> },
  {
    name: 'definition-names-task',
    routes,
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <div className="lf-main">
          <main className="lf-content">
            <Task />
          </main>
        </div>
      </AuthContext.Provider>
    ),
  },
]
