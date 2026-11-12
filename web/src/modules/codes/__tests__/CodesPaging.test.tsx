// @vitest-environment jsdom
/** T-1802: the code list is paged on the server (fixture above the old 10 000 cap), says when it shows only part of
 *  the codes, and reads the open assignments only for the assigned codes it has loaded. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, cleanup, fireEvent, renderHook, screen, waitFor } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { useCodeTagRows } from '../CodesShell'
import { fakeServer, queryBodies, rec, renderCodes } from './codesTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-codes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const PATH = '/admin/codes'
const val = (i: number) => `C-${String(i).padStart(6, '0')}`
const codes = (n: number, status = 'not_assigned') =>
  Array.from({ length: n }, (_, i) => rec(`c-${i}`, 'code_tag', { value: val(i), kind: 'barcode', status }))
const tagQueries = () => queryBodies(clientMock, 'code_tag')

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('T1 paging past the old cap', () => {
  it('Load more follows the cursor to the end: all 10 500 codes, 105 requests, no loop', async () => {
    fakeServer(clientMock, { code_tag: codes(10500) })
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    const { result } = renderHook(() => useCodeTagRows('code_tag', 'all', []), { wrapper })
    await waitFor(() => expect(result.current.rows).toHaveLength(100))
    for (let i = 2; i <= 105; i++) {
      await waitFor(() => expect(result.current.hasMore).toBe(true))
      act(() => result.current.loadMore())
      await waitFor(() => expect(result.current.rows).toHaveLength(Math.min(i * 100, 10500)))
    }
    await waitFor(() => expect(result.current.hasMore).toBe(false))
    expect(result.current.rows.at(-1)?.field_values['value']).toBe(val(10499))
    expect(tagQueries()).toHaveLength(105)
  }, 60_000)
})

describe('T2/T3 notice and Load more', () => {
  it('opens with one request of 100, the notice and the button', async () => {
    fakeServer(clientMock, { code_tag: codes(10500) })
    renderCodes(PATH)
    expect(await screen.findByText(val(0))).toBeInTheDocument()
    expect(tagQueries()).toHaveLength(1)
    expect(tagQueries()[0]['page_size']).toBe(100)
    expect(tagQueries()[0]['cursor']).toBeUndefined()
    expect(screen.getByTestId('codes-truncated')).toHaveTextContent('Showing the first 100 codes')
    expect(screen.getByTestId('codes-load-more')).toBeInTheDocument()
  })

  it('Load more appends; notice and button are gone on the last page', async () => {
    fakeServer(clientMock, { code_tag: codes(250) })
    renderCodes(PATH)
    await screen.findByText(val(0))
    fireEvent.click(screen.getByTestId('codes-load-more'))
    await waitFor(() => expect(screen.getByTestId('codes-truncated')).toHaveTextContent('first 200'))
    fireEvent.click(screen.getByTestId('codes-load-more'))
    expect(await screen.findByText(val(249))).toBeInTheDocument()
    expect(screen.queryByTestId('codes-truncated')).not.toBeInTheDocument()
    expect(screen.queryByTestId('codes-load-more')).not.toBeInTheDocument()
  })
})

describe('T4 a code past the old cap is found by value', () => {
  it('the search sends an eq filter on value and shows the code without a notice', async () => {
    fakeServer(clientMock, { code_tag: codes(10500) })
    renderCodes(PATH)
    await screen.findByText(val(0))
    fireEvent.change(screen.getByLabelText('Exact value'), { target: { value: val(10400) } })
    fireEvent.click(screen.getByTestId('codes-search'))
    expect(await screen.findByText(val(10400))).toBeInTheDocument()
    const filters = tagQueries().at(-1)?.['filters'] as { field: string; op: string; value: unknown }[]
    expect(filters.some((f) => f.field === 'value' && f.op === 'eq' && f.value === val(10400))).toBe(true)
    await waitFor(() => expect(screen.queryByTestId('codes-truncated')).not.toBeInTheDocument())
  })
})

describe('T5 open assignments follow the loaded codes', () => {
  const assignedData = () => ({
    code_tag: codes(250, 'assigned'),
    location_node: [rec('l1', 'location_node', { code: 'A-01', name: 'Aisle' })],
    catalog_item: [],
    catalog_lot: [],
    code_assignment: Array.from({ length: 250 }, (_, i) =>
      rec(`a-${i}`, 'code_assignment', { code_id: `c-${i}`, target_type: 'location_node', target_id: 'l1', assigned_at: '2026-01-01T10:00:00Z' }),
    ),
  })
  const inSizes = () =>
    queryBodies(clientMock, 'code_assignment')
      .flatMap((b) => b['filters'] as { op: string; value: unknown }[])
      .filter((f) => f.op === 'in')
      .map((f) => (f.value as string[]).length)

  it('one chunk for 100 loaded codes, a second chunk once 250 are loaded; no fetch-all of assignments', async () => {
    fakeServer(clientMock, assignedData())
    renderCodes(PATH)
    await screen.findByText(val(0))
    await waitFor(() => expect(inSizes()).toEqual([100]))
    fireEvent.click(screen.getByTestId('codes-load-more'))
    await waitFor(() => expect(screen.getByTestId('codes-truncated')).toHaveTextContent('first 200'))
    fireEvent.click(screen.getByTestId('codes-load-more'))
    await screen.findByText(val(249))
    await waitFor(() => expect(inSizes().slice(-2)).toEqual([200, 50]))
    // every assignment query carries the code_id filter
    const bodies = queryBodies(clientMock, 'code_assignment')
    expect(bodies.every((b) => (b['filters'] as { op: string }[]).some((f) => f.op === 'in'))).toBe(true)
    // the target of a code in the second chunk is shown
    const r = (await screen.findByText(val(249))).closest('tr') as HTMLElement
    await waitFor(() => expect(r).toHaveTextContent('A-01'))
  })
})
