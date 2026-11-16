/** Harness fixtures of "My reports" (REQ-872). Invented data only. The REAL AppShell (with the top-bar My reports link)
 *  around the real page, signed in as a warehouse-only user. `my-reports-list` has one report in each status,
 *  `my-reports-has-more` adds the "newest 50" line, `my-reports-empty` an empty list, `my-reports-unavailable` answers 503. */
import { lazy, Suspense, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import MyProblemReportsPage from '@/pages/me/MyProblemReportsPage'
import { AUTH, makeRoutes } from './layoutBase'
import type { FixtureRoute, HarnessScreen } from '../types'

const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

const TEXTS = [
  'The commission screen froze when I pressed Save.',
  'The count sheet does not show the new warehouse zone.',
  'I cannot print the receipt form.',
  'The balances screen is empty after the import.',
  'Please add a second unit to the item card.',
]
const row = (n: number, status: string, extra: Record<string, unknown> = {}) => ({
  id: `r${n}`,
  number: `SR-${40 + n}`,
  status,
  question: false,
  reply_text: null,
  text: TEXTS[n - 1],
  received_at: `2026-11-${10 + n}T10:00:00Z`,
  decided_at: null,
  ...extra,
})
const LIST = [
  row(1, 'received'),
  row(2, 'in_work', { question: true, reply_text: 'Which warehouse zone is missing?' }),
  row(3, 'answered', { reply_text: 'Use Print, then Official form.' }),
  row(4, 'fixed', { reply_text: 'Fixed in the latest version.' }),
  row(5, 'not_done', { reply_text: 'The card keeps one base unit by design.' }),
]

const notifications: FixtureRoute = {
  match: (path, method) => path === '/api/v1/me/notifications' && method === 'GET',
  reply: () => ({ status: 200, body: { notifications: [], unread_count: 0 } }),
}
const listRoute = (status: number, body: unknown): FixtureRoute => ({
  match: (path, method) => path === '/api/v1/me/problem-reports' && method === 'GET',
  reply: () => ({ status, body }),
})
const routes = (r: FixtureRoute): FixtureRoute[] => [...makeRoutes(null), notifications, r]

function page(): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('storekeeper')}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell />}>
                  <Route path="*" element={<MyProblemReportsPage />} />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

export const myProblemReportsScreens: HarnessScreen[] = [
  { name: 'my-reports-list', routes: routes(listRoute(200, { reports: LIST, has_more: false })), render: page },
  { name: 'my-reports-has-more', routes: routes(listRoute(200, { reports: LIST, has_more: true })), render: page },
  { name: 'my-reports-empty', routes: routes(listRoute(200, { reports: [], has_more: false })), render: page },
  { name: 'my-reports-unavailable', routes: routes(listRoute(503, { title: 'unavailable' })), render: page },
]
