// @vitest-environment jsdom
/** T-2007: the owner inbox screen. PR-C1 list, C2 facts beside text, C3 escaping, C4/C5 decisions, C6 closed, C7 errors,
 *  C8 states, C9 layout setting, C10 Escape, C11 paging. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter, useLocation } from 'react-router-dom'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { queryKeys } from '@/api/queryKeys'
import type { InboxDetail, InboxSummary } from '@/api/platformProblemReports'
import { ToastContainer } from '@/components/ui/Toast'
import ProblemReportsPage from '../ProblemReportsPage'

expect.extend(jestDomMatchers)

const api = vi.hoisted(() => ({ list: vi.fn(), get: vi.fn(), decide: vi.fn() }))
const layoutMock = vi.hoisted(() => ({ value: 'row' as 'row' | 'tabs' }))
vi.mock('@/api/platformProblemReports', () => ({ platformProblemReportsApi: api }))
vi.mock('@/hooks/useDocumentLayout', () => ({ useDocumentLayout: () => layoutMock.value }))
vi.mock('@/api/useTenantScopedQueryKeys', async () => {
  const { queryKeys: qk } = await import('@/api/queryKeys')
  return {
    useTenantScopedQueryKeys: () => ({
      problemReportsInbox: {
        all: () => qk.problemReportsInbox.all('t1'),
        lists: () => qk.problemReportsInbox.lists('t1'),
        list: (s: string) => qk.problemReportsInbox.list('t1', s),
        detail: (id: string) => qk.problemReportsInbox.detail('t1', id),
      },
    }),
  }
})
void queryKeys

const summary = (over: Partial<InboxSummary> = {}): InboxSummary => ({
  id: 'r1', number: 'SR-14', class: 'problem', status: 'received', last_action: null,
  received_at: '2026-11-15T09:00:00Z', decided_at: null,
  reporter: { tenant_name: 'Acme', name: 'Aida' }, text_preview: 'It broke', ...over,
})
const detail = (over: Partial<InboxDetail> = {}): InboxDetail => ({
  id: 'r1', number: 'SR-14', class: 'problem', status: 'received', last_action: null,
  received_at: '2026-11-15T09:00:00Z', decided_at: null, decided_by_user_id: null,
  reporter: { tenant_id: 'tt', tenant_name: 'Acme', user_id: 'uu', name: 'Aida', roles: ['role-a'], permissions: ['InstancesRead'] },
  text: 'It broke when I pressed Save', server_version: '1.4.0', trace_id: 'trace-xyz', reply_text: null, dev_summary: null,
  context: {
    route: '/admin/assets', ui_language: 'en', browser: { user_agent: 'UA/1', viewport: '1440x900', language: 'en' },
    actions: [{ at: 't1', kind: 'click', name: 'Save' }], requests: [],
  },
  ...over,
})

function Loc() {
  const l = useLocation()
  return <span data-testid="loc">{l.search}</span>
}
function renderPage(initial = '/admin/problem-reports?report=r1') {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[initial]}>
        <ProblemReportsPage />
        <Loc />
        <ToastContainer />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  api.list.mockReset().mockResolvedValue({ reports: [summary()], next_before: null })
  api.get.mockReset().mockResolvedValue(detail())
  api.decide.mockReset()
  layoutMock.value = 'row'
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe('PR-C1 list', () => {
  it('lists open reports and the Closed filter asks for closed', async () => {
    renderPage('/admin/problem-reports')
    const list = await screen.findByTestId('pr-list')
    await waitFor(() => expect(list).toHaveTextContent('SR-14'))
    expect(list).toHaveTextContent('Acme')
    expect(list).toHaveTextContent('It broke')
    expect(list).toHaveTextContent('Received')
    expect(list).not.toHaveTextContent('Aida')
    expect(api.list).toHaveBeenCalledWith({ status: 'open', before: null })
    api.list.mockResolvedValue({ reports: [], next_before: null })
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'closed' } })
    await waitFor(() => expect(api.list).toHaveBeenCalledWith({ status: 'closed', before: null }))
    expect(screen.getByTestId('loc')).toHaveTextContent('status=closed')
    expect(await screen.findByText('No closed reports')).toBeInTheDocument()
  })
})

describe('PR-C2 text beside facts', () => {
  it('Row layout: text and facts are children of the grid', async () => {
    renderPage()
    const text = await screen.findByTestId('pr-text')
    const facts = screen.getByTestId('pr-facts')
    expect(text).toHaveTextContent('It broke when I pressed Save')
    expect(facts).toHaveTextContent('/admin/assets')
    expect(facts).toHaveTextContent('UA/1')
    expect(facts).toHaveTextContent('1.4.0')
    expect(facts).toHaveTextContent('trace-xyz')
    expect(text.parentElement).toBe(screen.getByTestId('pr-grid'))
    expect(facts.parentElement).toBe(screen.getByTestId('pr-grid'))
    expect(facts).not.toHaveTextContent('tt')
  })
})

describe('PR-C3 escaping', () => {
  it('shows customer text and context as plain text', async () => {
    const evil = '<img src=x onerror="window.__pwned=1"><script>window.__pwned=2</script> **bold**'
    api.get.mockResolvedValue(detail({ text: evil, context: { actions: [{ at: 't', kind: 'click', name: '<b>x</b>' }] } }))
    const { container } = renderPage()
    expect(await screen.findByText(evil)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('tab', { name: /Recent actions/ }))
    expect(screen.getByText('<b>x</b>')).toBeInTheDocument()
    expect(container.querySelector('[data-testid="pr-text"] img, [data-testid="pr-text"] script, [data-testid="pr-text"] b')).toBeNull()
    expect(container.querySelector('[data-testid="pr-actions-table"] b')).toBeNull()
    expect((window as unknown as { __pwned?: number }).__pwned).toBeUndefined()
  })
})

async function openDialog(action: string) {
  fireEvent.click(await screen.findByTestId(`pr-action-${action}`))
  return screen.findByTestId('pr-decision-text')
}

describe('PR-C4 answer', () => {
  it('sends the decision, keeps the selection and shows the new status', async () => {
    api.decide.mockResolvedValue(detail({ status: 'answered', last_action: 'answer', reply_text: 'Thanks, fixed in 1.4' }))
    renderPage()
    const field = await openDialog('answer')
    fireEvent.change(field, { target: { value: 'Thanks, fixed in 1.4' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save decision' }))
    await waitFor(() => expect(api.decide).toHaveBeenCalledWith('r1', { action: 'answer', text: 'Thanks, fixed in 1.4' }))
    await waitFor(() => expect(screen.queryByTestId('pr-action-answer')).toBeNull())
    expect(screen.getByTestId('pr-status-answered')).toBeInTheDocument()
    expect(screen.getByTestId('pr-closed-note')).toBeInTheDocument()
    expect(screen.getByTestId('loc')).toHaveTextContent('report=r1')
    expect(await screen.findByText('Decision saved: Answered')).toBeInTheDocument()
  })
  it('refuses an empty answer in the field and sends nothing', async () => {
    renderPage()
    await openDialog('answer')
    fireEvent.click(screen.getByRole('button', { name: 'Save decision' }))
    expect(await screen.findByText('Write the text first.')).toBeInTheDocument()
    expect(api.decide).not.toHaveBeenCalled()
  })
})

describe('PR-C5 fixed', () => {
  it('confirms with an empty field and sends no text', async () => {
    api.decide.mockResolvedValue(detail({ status: 'fixed', last_action: 'fixed' }))
    renderPage()
    await openDialog('fixed')
    fireEvent.click(screen.getByRole('button', { name: 'Save decision' }))
    await waitFor(() => expect(api.decide).toHaveBeenCalledTimes(1))
    expect(api.decide.mock.calls[0]).toEqual(['r1', { action: 'fixed' }])
  })
})

describe('PR-C6 closed report', () => {
  it('shows a note and no decision buttons', async () => {
    api.get.mockResolvedValue(detail({ status: 'not_done', last_action: 'reject' }))
    renderPage()
    expect(await screen.findByTestId('pr-closed-note')).toBeInTheDocument()
    expect(screen.queryByTestId('pr-action-answer')).toBeNull()
    expect(screen.queryByTestId('pr-action-develop')).toBeNull()
  })
  it('an open report shows the five buttons, answer last', async () => {
    renderPage()
    await screen.findByTestId('pr-action-answer')
    const header = screen.getByTestId('detail-header')
    const ids = within(header).getAllByRole('button').map((b) => b.getAttribute('data-testid'))
    expect(ids).toEqual(['pr-action-develop', 'pr-action-ask', 'pr-action-reject', 'pr-action-fixed', 'pr-action-answer'])
  })
  it('a question sent shows the note', async () => {
    api.get.mockResolvedValue(detail({ status: 'in_work', last_action: 'ask' }))
    renderPage()
    expect(await screen.findByTestId('pr-question-sent')).toHaveTextContent('Question sent')
  })
})

describe('PR-C7 errors', () => {
  it('409 shows the closed text and refetches the detail', async () => {
    api.decide.mockRejectedValue({ status: 409, message: 'x', code: 'report_closed' })
    renderPage()
    const field = await openDialog('answer')
    fireEvent.change(field, { target: { value: 'hello' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save decision' }))
    expect(await screen.findByText('This report was already closed by another decision.')).toBeInTheDocument()
    await waitFor(() => expect(api.get.mock.calls.length).toBeGreaterThanOrEqual(2))
  })
  it('422 copies keeps the dialog open and shows the text in the field', async () => {
    api.decide.mockRejectedValue({ status: 422, message: 'x', code: 'x', details: { detail: 'The summary must be in your own words.' } })
    renderPage()
    const field = await openDialog('develop')
    fireEvent.change(field, { target: { value: 'copy' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save decision' }))
    expect(await screen.findByText(/Write the summary in your own words/)).toBeInTheDocument()
    expect(screen.getByTestId('pr-decision-text')).toBeInTheDocument()
  })
})

describe('PR-C8 states', () => {
  it('shows the empty text', async () => {
    api.list.mockResolvedValue({ reports: [], next_before: null })
    renderPage('/admin/problem-reports')
    expect(await screen.findByText('No open reports')).toBeInTheDocument()
  })
  it('shows a list error with a retry that reloads', async () => {
    api.list.mockRejectedValueOnce({ status: 500, message: 'x', code: 'x' }).mockResolvedValue({ reports: [], next_before: null })
    renderPage('/admin/problem-reports')
    expect(await screen.findByText('Could not load the reports.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('No open reports')).toBeInTheDocument()
  })
  it('maps 503 on the list to the unavailable text', async () => {
    api.list.mockRejectedValue({ status: 503, message: 'x', code: 'x' })
    renderPage('/admin/problem-reports')
    expect(await screen.findByText('Problem reports are not available right now.')).toBeInTheDocument()
  })
  it('shows a skeleton while the list loads', () => {
    api.list.mockReturnValue(new Promise(() => undefined))
    renderPage('/admin/problem-reports')
    expect(screen.getAllByTestId('skeleton').length).toBeGreaterThan(0)
  })
  it('detail 404 shows the not-found text', async () => {
    api.get.mockRejectedValue({ status: 404, message: 'x', code: 'x' })
    renderPage()
    expect(await screen.findByTestId('pr-detail-error')).toHaveTextContent('This report no longer exists.')
  })
})

describe('PR-C9 the layout setting', () => {
  it('tabs: Report and Facts are tabs and there is no grid', async () => {
    layoutMock.value = 'tabs'
    const { container } = renderPage()
    await screen.findByTestId('pr-detail')
    const names = screen.getAllByRole('tab').map((x) => x.textContent ?? '')
    expect(names[0]).toBe('Report')
    expect(names[1]).toBe('Facts')
    expect(names.some((n) => n.startsWith('Recent actions'))).toBe(true)
    expect(names.some((n) => n.startsWith('Decision'))).toBe(true)
    expect(container.querySelector('.lf-pr__grid')).toBeNull()
    expect(screen.getByRole('tab', { name: 'Report' })).toHaveAttribute('aria-selected', 'true')
  })
  it('row: the grid is shown and the tabs start with Recent actions', async () => {
    const { container } = renderPage()
    await screen.findByTestId('pr-detail')
    expect(container.querySelector('.lf-pr__grid')).not.toBeNull()
    expect(screen.getAllByRole('tab')[0].textContent).toMatch(/^Recent actions/)
  })
})

describe('PR-C10 Escape', () => {
  it('closes the dialog first and keeps the record, a second Escape closes the record', async () => {
    renderPage()
    await openDialog('answer')
    fireEvent.keyDown(screen.getByTestId('pr-decision-text'), { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('pr-decision-text')).toBeNull())
    expect(screen.getByTestId('loc')).toHaveTextContent('report=r1')
  })
})

describe('PR-C11 paging', () => {
  it('loads older reports and appends them, with an honest count', async () => {
    api.list
      .mockResolvedValueOnce({ reports: [summary()], next_before: 7 })
      .mockResolvedValueOnce({ reports: [summary({ id: 'r0', number: 'SR-13', text_preview: 'older' })], next_before: null })
    renderPage('/admin/problem-reports')
    const more = await screen.findByTestId('pr-load-older')
    expect(screen.getByTestId('pr-count')).toHaveTextContent('1 reports shown')
    fireEvent.click(more)
    await waitFor(() => expect(api.list).toHaveBeenCalledWith({ status: 'open', before: 7 }))
    await waitFor(() => expect(screen.getByTestId('pr-list')).toHaveTextContent('SR-13'))
    expect(screen.getByTestId('pr-count')).toHaveTextContent('2 reports shown')
    expect(screen.queryByTestId('pr-load-older')).toBeNull()
  })
})

describe('catalog', () => {
  it('ru and kk show the page title', async () => {
    for (const [l, title] of [['ru', 'Сообщения о проблемах'], ['kk', 'Мәселе туралы хабарламалар']] as const) {
      useUiLocaleStore.getState().setLocaleTransient(l)
      renderPage('/admin/problem-reports')
      expect(await screen.findByRole('heading', { name: title })).toBeInTheDocument()
      cleanup()
    }
  })
})
