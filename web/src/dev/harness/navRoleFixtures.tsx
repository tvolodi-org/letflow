/** Harness screens of the role-based sidebar (T-1522): nav-role-admin | storekeeper | worker | scoped. Each renders the real
 *  AppShell + route tree for that role's access set (navRoleAccess.ts, pinned to the permission matrix). Unmatched /api/ reads
 *  answer an empty 200 list, so a denied page can only come from a guard. Lazy: the shell's import chain reads `window`. */
import { lazy, Suspense } from 'react'
import type { FixtureRoute, HarnessScreen } from './types'
import { ALL_MODULE_IDS, type NavRole } from './navRoleAccess'

const Shell = lazy(() => import('./navRoleShell'))

const routes: FixtureRoute[] = [
  { match: (p) => p === '/health', reply: () => ({ status: 200, body: { status: 'ok' } }) },
  { match: (p) => p === '/api/v1/me/modules', reply: () => ({ status: 200, body: { installed_modules: ALL_MODULE_IDS.map((m) => ({ module_id: m, version: '1' })) } }) },
  { match: (p) => p.startsWith('/api/'), reply: () => ({ status: 200, body: { items: [], rows: [], next_cursor: null, count: 0 } }) },
]

const screen = (role: NavRole): HarnessScreen => {
  const name = `nav-role-${role}`
  return { name, routes, render: ({ state }) => <Suspense fallback={null}><Shell screen={name} role={role} state={state} /></Suspense> }
}

export const navRoleScreens: HarnessScreen[] = (['admin', 'storekeeper', 'worker', 'scoped'] as const).map(screen)
