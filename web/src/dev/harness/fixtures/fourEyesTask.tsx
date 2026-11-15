/** Harness screens of T-1987: the approve task of the issuer with the four-eyes rule ON (hint shown) and OFF (no hint). */
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import type { AccessState } from '@/auth/access/types'
import type { FixtureRoute, HarnessScreen } from '../types'
import { makeRoutes } from './layoutBase'
import { inShell, AutoSelectFirst } from './listDetailSlice5'

const ME = '11111111-2222-4333-8444-555555555555'
const T1 = 'cccccccc-0000-4000-8000-000000000001'
const I1 = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001'
const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString()

const access: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, user_id: ME, permissions: ['TasksRead', 'TasksComplete'] },
}

function routes(selfApprovalAllowed: boolean): FixtureRoute[] {
  const task = {
    id: T1, instance_id: I1, token_id: 't1', node_id: 'approve', node_name: 'approve', status: 'PENDING',
    assignee_type: 'ROLE', assignee_ref: 'TENANT_ADMIN', definition_name: 'assets_opening', created_at: ago(5),
  }
  return [
    ...makeRoutes(null),
    { match: (p, m) => p === '/api/v1/tasks/inbox' && m === 'GET', reply: () => ({ status: 200, body: { items: [task], next_cursor: null, count: 1 } }) },
    { match: (p, m) => p.startsWith('/api/v1/tasks/') && m === 'GET', reply: () => ({ status: 200, body: { ...task, self_approval_allowed: selfApprovalAllowed } }) },
    { match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/history$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: [{ actor_id: ME }] }) },
    { match: (p, m) => /^\/api\/v1\/instances\/[^/]+$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: { id: I1, variables: {} } }) },
    { match: (p, m) => p === '/api/v1/entities/query' && m === 'POST', reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
  ]
}

function screen(name: string, allowed: boolean): HarnessScreen {
  return {
    name,
    routes: routes(allowed),
    initialPath: '/tasks',
    render: inShell(
      access,
      <>
        <TaskInboxPage />
        <AutoSelectFirst selector="[data-testid='task-row']" />
      </>,
    ),
  }
}

export const fourEyesTaskScreens: HarnessScreen[] = [
  screen('tasks-approve-four-eyes-on', false),
  screen('tasks-approve-four-eyes-off', true),
]
