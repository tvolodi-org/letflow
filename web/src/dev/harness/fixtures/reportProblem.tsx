/** Harness fixtures of "Report a problem" (T-1950). Invented data only. The REAL AppShell shows the top-bar button; a
 *  `Driver` waits for the shell, seeds the capture rings (the shell resets them on mount) and walks the dialog through
 *  the real DOM (matching by data-testid, never by label, so ru and kk work). `report-problem-error` answers 503.
 *  The crash screens render `ShellCrashPanel` directly (the boundary above AppShell is not part of the harness). */
import { lazy, Suspense, useEffect, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import { PageHeader } from '@/components/ui/PageHeader'
import { ToastContainer } from '@/components/ui/Toast'
import { ShellCrashPanel } from '@/components/layout/ShellCrashPanel'
import { recordAction, recordRequest, resetCapture } from '@/lib/problemReport/capture'
import { AUTH, makeRoutes } from './layoutBase'
import type { FixtureRoute, HarnessScreen } from '../types'

const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

type Step = 'none' | 'open' | 'ready' | 'send'

const REPORT_TEXT = 'Commission fails, mail me at ivan.petrov@example.kz'

const reportRoute = (status: number): FixtureRoute => ({
  match: (path, method) => path === '/api/v1/me/problem-reports' && method === 'POST',
  reply: () =>
    status === 201
      ? { status, body: { id: 'r1', number: 'SR-42', received_at: '2026-11-14T10:00:00Z' } }
      : { status, body: { title: 'not available' } },
})
const notificationsRoute: FixtureRoute = {
  match: (path, method) => path === '/api/v1/me/notifications' && method === 'GET',
  reply: () => ({ status: 200, body: { notifications: [], unread_count: 0 } }),
}

function seed(): void {
  resetCapture()
  recordAction('nav', '/admin/assets/documents')
  recordAction('click', 'assets-commission-btn')
  recordAction('click', 'dialog-confirm')
  recordRequest(null, 'GET', '/api/v1/assets/documents/123456', 500, 'trace-abc')
  recordRequest(null, 'GET', '/api/v1/me/notifications', 200, null)
}

const q = (id: string) => document.querySelector<HTMLElement>(`[data-testid="${id}"]`)

function type(el: HTMLTextAreaElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(el, value)
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

/** Waits for a testid, then runs `then`; one animation frame per try, bounded (no endless loop). */
function whenPresent(id: string, then: (el: HTMLElement) => void, onCancel: { current: boolean }, tries = 600): void {
  const tick = (n: number): void => {
    if (onCancel.current) return
    const el = q(id)
    if (el) return then(el)
    if (n > 0) requestAnimationFrame(() => tick(n - 1))
  }
  // First try one frame later: the shell resets the rings in its own mount effect, which runs after this one.
  requestAnimationFrame(() => tick(tries))
}

/** Seeds the rings once the shell is up, then opens the dialog and goes as far as `step` says. */
function Driver({ step, openOnPanel = false }: { step: Step; openOnPanel?: boolean }) {
  useEffect(() => {
    const cancelled = { current: false }
    const fromButton = openOnPanel ? 'error-boundary-report' : 'topbar-report-problem'
    whenPresent(
      fromButton,
      (button) => {
        if (!openOnPanel) seed()
        if (step === 'none') return
        button.click()
        whenPresent(
          'report-text',
          (textarea) => {
            if (step === 'open') {
              if (!openOnPanel) type(textarea as HTMLTextAreaElement, REPORT_TEXT)
              q('report-preview-toggle')?.setAttribute('open', '')
              return
            }
            type(textarea as HTMLTextAreaElement, REPORT_TEXT)
            q('report-consent')?.click()
            if (step === 'send') requestAnimationFrame(() => q('report-dialog-confirm')?.click())
          },
          cancelled,
        )
      },
      cancelled,
    )
    return () => {
      cancelled.current = true
    }
  }, [step, openOnPanel])
  return null
}

const TXT = {
  en: { eyebrow: 'Assets', title: 'Commissioning', lede: 'Put the fixed asset into service.' },
  ru: { eyebrow: 'Основные средства', title: 'Ввод в эксплуатацию', lede: 'Введите основное средство в эксплуатацию.' },
  kk: { eyebrow: 'Негізгі құралдар', title: 'Пайдалануға беру', lede: 'Негізгі құралды пайдалануға беріңіз.' },
}

function shell(step: Step, lang: 'en' | 'ru' | 'kk'): ReactElement {
  const t = TXT[lang]
  return (
    <AuthContext.Provider value={AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell />}>
                  <Route
                    path="*"
                    element={
                      <>
                        <PageHeader eyebrow={t.eyebrow} title={t.title} lede={t.lede} />
                        <Driver step={step} />
                      </>
                    }
                  />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

function crashPage(open: boolean): ReactElement {
  const error = new Error('Cannot read properties of undefined (reading "asset")')
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={accessState('platformAdmin')}>
        <ShellCrashPanel error={error} reset={() => undefined} />
        {open && <Driver step="open" openOnPanel />}
        <ToastContainer />
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

const base = (status: number): FixtureRoute[] => [...makeRoutes(null), notificationsRoute, reportRoute(status)]

export const reportProblemScreens: HarnessScreen[] = [
  { name: 'report-problem-shell', routes: base(201), render: ({ lang }) => shell('none', lang) },
  { name: 'report-problem-open', routes: base(201), render: ({ lang }) => shell('open', lang) },
  { name: 'report-problem-ready', routes: base(201), render: ({ lang }) => shell('ready', lang) },
  { name: 'report-problem-error', routes: base(503), render: ({ lang }) => shell('send', lang) },
  { name: 'report-problem-received', routes: base(201), render: ({ lang }) => shell('send', lang) },
  { name: 'report-problem-crash', routes: base(201), render: () => crashPage(false) },
  { name: 'report-problem-crash-open', routes: base(201), render: () => crashPage(true) },
]
