// @vitest-environment jsdom
/** REQ-872 criteria 2, 3 and 4 (screen part): "My reports" lists the caller's own problem reports. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { UI_LOCALES, useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { problemReportsMessages } from '@/pages/admin/problem-reports/problemReportsMessages'
import { reportProblemMessages } from '@/components/layout/reportProblemMessages'
import { router } from '@/router'
import { myProblemReportsMessages } from '../myProblemReportsMessages'
import MyProblemReportsPage from '../MyProblemReportsPage'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const URL_LIST = '/api/v1/me/problem-reports'
const row = (n: number, status: string, extra: Record<string, unknown> = {}) => ({
  id: `id-${n}`,
  number: `SR-${n}`,
  status,
  question: false,
  reply_text: null,
  text: `Text of report ${n}`,
  received_at: '2026-11-1' + n + 'T10:00:00Z',
  decided_at: null,
  ...extra,
})
const ALL = [
  row(1, 'received'),
  row(2, 'in_work', { question: true, reply_text: 'Which screen was it?' }),
  row(3, 'answered', { reply_text: 'Use the Commission button.' }),
  row(4, 'fixed', { reply_text: 'Fixed in the last version.' }),
  row(5, 'not_done', { reply_text: 'Works as designed.' }),
]

function renderPage(fixture: AccessFixtureName = 'storekeeper', element = <MyProblemReportsPage />) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={accessState(fixture)}>
        <MemoryRouter initialEntries={['/me/problem-reports']}>
          <Routes>
            <Route path="/me/problem-reports" element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  clientMock.get.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('REQ-872 criterion 2: one row per report', () => {
  it('shows number, date, status label, text, and the reply only where the server sent it', async () => {
    clientMock.get.mockResolvedValue({ reports: ALL, has_more: false })
    renderPage()
    const rows = await screen.findAllByTestId('my-report-row')
    expect(rows).toHaveLength(5)
    const labels = ['Received', 'In work', 'Answered', 'Fixed', 'Not done']
    rows.forEach((r, i) => {
      expect(within(r).getByTestId('my-report-number')).toHaveTextContent(`SR-${i + 1}`)
      expect(within(r).getByTestId('my-report-received').textContent).toMatch(/2026/)
      expect(within(r).getByTestId('my-report-status')).toHaveTextContent(labels[i]!)
      expect(within(r).getByTestId('my-report-text')).toHaveTextContent(`Text of report ${i + 1}`)
    })
    expect(within(rows[0]!).queryByTestId('my-report-reply')).toBeNull()
    expect(within(rows[1]!).getByTestId('my-report-reply')).toHaveTextContent('Question from the support team')
    expect(within(rows[1]!).getByTestId('my-report-reply')).toHaveTextContent('Which screen was it?')
    expect(within(rows[2]!).getByTestId('my-report-reply')).toHaveTextContent('Reply from the support team')
    expect(within(rows[4]!).getByTestId('my-report-reply')).toHaveTextContent('Works as designed.')
    expect(clientMock.get).toHaveBeenCalledWith(URL_LIST)
  })

  it('uses the session language for the status labels (ru, kk)', async () => {
    clientMock.get.mockResolvedValue({ reports: ALL, has_more: false })
    for (const locale of UI_LOCALES) {
      useUiLocaleStore.getState().setLocaleTransient(locale)
      const { unmount } = renderPage()
      const rows = await screen.findAllByTestId('my-report-row')
      expect(within(rows[0]!).getByTestId('my-report-status')).toHaveTextContent(
        problemReportsMessages[locale]['problemReports.status.received']!,
      )
      expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(myProblemReportsMessages[locale].title)
      unmount()
    }
  })
})

describe('REQ-872 criterion 3: empty, unavailable, has_more', () => {
  it('empty list shows an empty state that names the Report a problem button', async () => {
    clientMock.get.mockResolvedValue({ reports: [], has_more: false })
    renderPage()
    const empty = await screen.findByTestId('my-reports-empty')
    expect(empty).toHaveTextContent(reportProblemMessages.en.button!)
    expect(screen.queryAllByTestId('my-report-row')).toHaveLength(0)
  })

  it('a 503 answer shows the unavailable message and no rows', async () => {
    clientMock.get.mockRejectedValue({ status: 503 })
    renderPage()
    expect(await screen.findByTestId('my-reports-unavailable')).toHaveTextContent(myProblemReportsMessages.en.unavailable)
    expect(screen.queryAllByTestId('my-report-row')).toHaveLength(0)
  })

  it('any other failure shows the load error with a retry', async () => {
    clientMock.get.mockRejectedValue({ status: 500 })
    renderPage()
    expect(await screen.findByRole('button', { name: /try again|retry/i })).toBeInTheDocument()
    expect(screen.queryByTestId('my-reports-unavailable')).toBeNull()
  })

  it('has_more true says only the newest 50 are listed; false shows no such line', async () => {
    clientMock.get.mockResolvedValue({ reports: ALL, has_more: true })
    renderPage()
    expect(await screen.findByTestId('my-reports-has-more')).toHaveTextContent('newest 50')
    cleanup()
    clientMock.get.mockResolvedValue({ reports: ALL, has_more: false })
    renderPage()
    await screen.findAllByTestId('my-report-row')
    expect(screen.queryByTestId('my-reports-has-more')).toBeNull()
  })

  it('shows a skeleton while loading', () => {
    clientMock.get.mockReturnValue(new Promise(() => undefined))
    renderPage()
    expect(screen.getByLabelText(/loading/i)).toHaveAttribute('aria-busy', 'true')
  })
})

describe('REQ-872 criterion 4: the real route is open to a warehouse-only and a candidate session', () => {
  const route = router.routes.find((r) => r.path === '/')?.children?.find((c) => c.path === 'me/problem-reports')

  it('the route exists and is not wrapped in a permission guard', () => {
    expect(route).toBeDefined()
    expect(route?.element).toBeDefined()
  })

  for (const fixture of ['storekeeper', 'candidate'] as const) {
    it(`renders the screen for ${fixture} only and asks /api/v1/me/problem-reports`, async () => {
      clientMock.get.mockResolvedValue({ reports: [row(1, 'received')], has_more: false })
      renderPage(fixture, route!.element as React.ReactElement)
      expect(await screen.findByTestId('my-report-row')).toBeInTheDocument()
      expect(screen.queryByText(/permission|not allowed|access denied/i)).toBeNull()
      expect(clientMock.get).toHaveBeenCalledWith(URL_LIST)
    })
  }
})
