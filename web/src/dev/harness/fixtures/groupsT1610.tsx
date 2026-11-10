/** Harness fixtures of the Groups page (T-1610). `groups` = table with the Roles column; `groups-members` = the
 *  members dialog with search results; `groups-bulk` = three users ticked and added, one of them refused;
 *  `groups-lastadmin` = Remove on the only administrator. `empty` = no groups, `error` = 500. */
import { useEffect, useRef, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import GroupsPage from '@/pages/admin/GroupsPage'
import type { UserSession } from '@/types/api'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: 'u1' })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: 'u1', permissions: ['UsersGroupsRolesManage'] },
}

const GROUPS = [
  { id: 'g-admin', name: 'org-admins', display_name: 'Administrators', description: 'Run the company account' },
  { id: 'g-ops', name: 'dispatchers', display_name: 'Dispatchers', description: 'Daily work' },
]
const ROLES = [
  { id: 'r1', name: 'TENANT_ADMIN', kind: 'platform_role', group_id: 'g-admin', is_system: true, permissions: [] },
  { id: 'r2', name: 'dispatcher', kind: 'process_routing_role', group_id: null, is_system: false, permissions: [] },
]
const user = (n: number, name: string, status = 'active') => ({
  id: `u-${n}`,
  username: `u${n}`,
  display_name: name,
  email: `${name.split(' ')[0].toLowerCase()}@example.test`,
  status,
  auth_source: 'internal',
  inserted_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
})
const FOUND = [user(1, 'Anna Ivanova'), user(2, 'Anar Sadykov'), user(3, 'Anton Petrov'), user(4, 'Anel Bekova', 'inactive')]
const ADMIN_ONLY = [user(9, 'Aigerim Nurova')]
const page = (items: unknown[]) => ({ items, next_cursor: null, count: items.length })

const get = (suffix: string) => (p: string, m: string) => m === 'GET' && p.endsWith(suffix)
const base = (members: unknown[]): FixtureRoute[] => [
  { match: get('/identity/groups'), reply: (s) => ({ status: 200, body: { items: s === 'empty' ? [] : GROUPS, total: 2 } }) },
  { match: get('/identity/roles'), reply: () => ({ status: 200, body: { items: ROLES } }) },
  { match: get('/identity/users'), reply: () => ({ status: 200, body: page(FOUND) }) },
  { match: (p, m) => m === 'GET' && p.includes('/identity/groups/') && p.endsWith('/members'), reply: () => ({ status: 200, body: page(members) }) },
]

/** Clicks through the page after it has drawn, one step per tick; `steps` receive the page root. */
function Driver({ steps }: { steps: Array<(root: HTMLElement) => boolean> }): ReactElement {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    let i = 0
    const release = holdHarnessReady()
    const t = window.setInterval(() => {
      const root = ref.current
      if (!root) return
      if (i >= steps.length) {
        window.clearInterval(t)
        window.setTimeout(release, 600)
        return
      }
      if (steps[i](root)) i += 1
    }, 150)
    return () => {
      window.clearInterval(t)
      release()
    }
  }, [steps])
  return (
    <div ref={ref}>
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <GroupsPage />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    </div>
  )
}

const buttonByText = (root: HTMLElement | Document, re: RegExp, nth = 0): HTMLButtonElement | undefined =>
  Array.from(root.querySelectorAll<HTMLButtonElement>('button')).filter((b) => re.test(b.textContent ?? ''))[nth]
// The label of the tick-box is matched by the user's name in any language.
const tick = (name: string) => () => {
  const box = Array.from(document.querySelectorAll<HTMLLabelElement>('[role=dialog] label')).find((l) => (l.textContent ?? '').includes(name))
  box?.querySelector<HTMLInputElement>('input')?.click()
  return Boolean(box)
}
// Opens the members dialog of the nth group by its "Manage members" button (en) or the primary button of the row.
const openDialog = (row: number) => (root: HTMLElement) => {
  const b = root.querySelectorAll<HTMLButtonElement>('tbody tr')[row]?.querySelector<HTMLButtonElement>('button')
  b?.click()
  return Boolean(b)
}
const dialogReady = () => document.querySelector('[role=dialog] input[type=checkbox], [role=dialog] h4') != null

const members = base

export const groupsT1610Screens: HarnessScreen[] = [
  {
    name: 'groups',
    routes: members([]),
    render: () => <Driver steps={[]} />,
  },
  {
    name: 'groups-members',
    routes: members([user(7, 'Dmitry Petrov')]),
    render: () => <Driver steps={[openDialog(1)]} />,
  },
  {
    name: 'groups-bulk',
    routes: [
      ...members([user(7, 'Dmitry Petrov')]),
      {
        match: (p, m) => m === 'POST' && p.endsWith('/members'),
        reply: (_s, _p, req) =>
          (req as { user_id?: string } | undefined)?.user_id === 'u-2'
            ? { status: 500, body: { title: 'Error', status: 500 } }
            : { status: 201, body: { created: true } },
      },
    ],
    render: () => (
      <Driver
        steps={[
          openDialog(1),
          () => dialogReady(),
          tick('Anna'),
          tick('Anar'),
          tick('Anton'),
          () => {
            const b = Array.from(document.querySelectorAll<HTMLButtonElement>('[role=dialog] button')).find((x) => /\(3\)/.test(x.textContent ?? ''))
            b?.click()
            return Boolean(b)
          },
        ]}
      />
    ),
  },
  {
    name: 'groups-lastadmin',
    routes: members(ADMIN_ONLY),
    render: () => (
      <Driver
        steps={[
          openDialog(0),
          () => {
            const b = buttonByText(document.querySelector('[role=dialog]') ?? document, /^(Remove|Удалить|Алып тастау)$/i)
            b?.click()
            return Boolean(b)
          },
        ]}
      />
    ),
  },
]
