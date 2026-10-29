// @vitest-environment jsdom
/**
 * GH 3423 / REQ-612 — the question bank page (B1..B10).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useLocation, useRoutes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-bank' }, isAuthenticated: true }),
}))

const clientMock = vi.hoisted(() => ({ post: vi.fn(), putWithHeaders: vi.fn(), delete: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

import { examRouteObjects } from '../examRoutes'

const writer: AccessState = { status: 'ready', info: ACCESS_FIXTURES.tenantAdmin }
const reader: AccessState = {
  status: 'ready',
  info: {
    ...ACCESS_FIXTURES.tenantAdmin,
    permissions: ACCESS_FIXTURES.tenantAdmin.permissions.filter((p) => p !== 'ExamAuthoringWrite'),
  },
}

function Routes() {
  return useRoutes(examRouteObjects)
}
function Where() {
  return <span data-testid="where">{useLocation().pathname}</span>
}

function renderBank(access: AccessState = writer) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={['/admin/questions']}>
          <Routes />
          <Where />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

function row(id: string, stem: Record<string, string>, difficulty: string) {
  return {
    record_id: id,
    field_values: { stem, type: 'single', status: 'draft', difficulty },
    deleted: false,
    entity_def_version: 'v',
    last_event_global_seq: 1,
  }
}

const THREE = {
  items: [
    row('q-1', { en: 'Easy one' }, 'easy'),
    row('q-2', { kk: 'Қазақша сұрақ' }, 'medium'),
    row('q-3', { en: 'Hard one' }, 'hard'),
  ],
  next_cursor: null,
}

function bodies(): Array<{ entity_type: string; filters?: Array<{ field: string; op: string; value?: unknown }> }> {
  return clientMock.post.mock.calls.map((c) => c[1])
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.post.mockResolvedValue(THREE)
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('bank list', () => {
  it('B1 three rows show three distinct difficulty badges', async () => {
    renderBank()
    const easy = await screen.findByTestId('difficulty-badge-easy')
    const medium = screen.getByTestId('difficulty-badge-medium')
    const hard = screen.getByTestId('difficulty-badge-hard')
    expect([easy.textContent, medium.textContent, hard.textContent]).toEqual(['easy', 'medium', 'hard'])
    const styles = [easy, medium, hard].map((el) => el.style.background)
    expect(new Set(styles).size).toBe(3)
  })

  it('B2 heading, stem with locale fallback, type, status and the deleted filter', async () => {
    renderBank()
    await screen.findByTestId('question-bank-table')
    expect(screen.getByRole('heading', { name: 'Question bank' })).toBeInTheDocument()
    expect(screen.getByText('Easy one')).toBeInTheDocument()
    expect(screen.getByText('Қазақша сұрақ')).toBeInTheDocument()
    expect(within(screen.getByTestId('question-row-q-1')).getByText('Single choice')).toBeInTheDocument()
    expect(within(screen.getByTestId('question-row-q-1')).getByText('draft')).toBeInTheDocument()
    expect(bodies()[0]).toMatchObject({ entity_type: 'question', filters: [{ field: 'deleted', op: 'eq', value: false }] })
  })
})

describe('bank search', () => {
  it('B3 typing sends nothing; the Search button sends one contains query on stem_en; Enter submits', async () => {
    renderBank()
    await screen.findByTestId('question-bank-table')
    const input = screen.getByLabelText('Search questions')
    expect(input).toHaveAttribute('placeholder', 'Search by question text')
    clientMock.post.mockClear()
    fireEvent.change(input, { target: { value: 'Easy' } })
    expect(clientMock.post).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledTimes(1))
    expect(bodies()[0].filters).toContainEqual({ field: 'stem_en', op: 'contains', value: 'Easy' })

    clientMock.post.mockClear()
    fireEvent.change(input, { target: { value: 'Hard' } })
    fireEvent.submit(screen.getByTestId('question-search-form'))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledTimes(1))
    expect(bodies()[0].filters).toContainEqual({ field: 'stem_en', op: 'contains', value: 'Hard' })
  })

  it.each([
    ['kk', 'stem_kk'],
    ['ru', 'stem_ru'],
  ])('B4 the %s UI locale searches %s', async (lang, column) => {
    vi.spyOn(window.navigator, 'languages', 'get').mockReturnValue([lang])
    renderBank()
    await screen.findByTestId('question-bank-table')
    clientMock.post.mockClear()
    fireEvent.change(document.querySelector('input[type="search"]') as HTMLInputElement, { target: { value: 'abc' } })
    fireEvent.submit(screen.getByTestId('question-search-form'))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledTimes(1))
    expect(bodies()[0].filters).toContainEqual({ field: column, op: 'contains', value: 'abc' })
  })

  it('B5 no match shows the empty state and no table rows', async () => {
    renderBank()
    await screen.findByTestId('question-bank-table')
    clientMock.post.mockResolvedValue({ items: [], next_cursor: null })
    fireEvent.change(screen.getByLabelText('Search questions'), { target: { value: 'zzz' } })
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    expect(await screen.findByTestId('question-bank-empty')).toBeInTheDocument()
    expect(screen.queryByTestId('question-bank-table')).toBeNull()
  })

  it('B6 clearing the input and submitting restores the unfiltered query', async () => {
    renderBank()
    await screen.findByTestId('question-bank-table')
    const input = screen.getByLabelText('Search questions')
    fireEvent.change(input, { target: { value: 'Easy' } })
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await waitFor(() => expect(bodies().some((b) => b.filters?.some((f) => f.op === 'contains'))).toBe(true))
    clientMock.post.mockClear()
    fireEvent.change(input, { target: { value: '' } })
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalled())
    expect(bodies()[0].filters).toEqual([{ field: 'deleted', op: 'eq', value: false }])
  })
})

describe('bank actions', () => {
  it('B7 New Question and Edit navigate to the editor routes', async () => {
    renderBank()
    fireEvent.click(await screen.findByTestId('question-edit-q-2'))
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/admin/questions/q-2/edit'))
    cleanup()
    clientMock.post.mockResolvedValue(THREE)
    renderBank()
    fireEvent.click(await screen.findByTestId('question-new'))
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/admin/questions/new'))
  })

  it('B8 a user without ExamAuthoringWrite sees the list but no New Question or Edit', async () => {
    renderBank(reader)
    expect(await screen.findByTestId('question-bank-table')).toBeInTheDocument()
    expect(screen.queryByTestId('question-new')).toBeNull()
    expect(screen.queryByTestId('question-edit-q-1')).toBeNull()
  })

  it('B9 the bank route is registered in examRouteObjects', () => {
    const paths = examRouteObjects.map((r) => r.path)
    expect(paths).toContain('admin/questions')
    const children = examRouteObjects.find((r) => r.path === 'admin/questions')?.children ?? []
    expect(children.map((c) => (c.index ? 'index' : c.path))).toEqual(['index', 'new', ':recordId/edit'])
  })

  it('B10 there is no AI or Import button', async () => {
    renderBank()
    await screen.findByTestId('question-bank-table')
    expect(screen.queryByRole('button', { name: /\bai\b|generate|import/i })).toBeNull()
  })

  it('Next page follows the cursor', async () => {
    clientMock.post.mockResolvedValue({ ...THREE, next_cursor: 'c2' })
    renderBank()
    fireEvent.click(await screen.findByTestId('question-next-page'))
    await waitFor(() => expect(bodies().some((b) => (b as { cursor?: string }).cursor === 'c2')).toBe(true))
  })
})
