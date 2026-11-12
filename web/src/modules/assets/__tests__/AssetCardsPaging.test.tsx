// @vitest-environment jsdom
/** T-1793: the asset card list is paged and searched on the server; it shows and finds every card (fixture above
 *  the old 10 000 cap) and says when it shows only part of the result. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, cleanup, fireEvent, renderHook, screen, waitFor } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { useAssetRows } from '../AssetsShell'
import { fakeServer, queryBodies, rec, renderAssets } from './assetsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const PATH = '/admin/assets/cards'
const no = (i: number) => `FA-${String(i).padStart(6, '0')}`
const cards = (n: number) =>
  Array.from({ length: n }, (_, i) => rec(`c-${i}`, 'assets_card', { inventory_number: no(i), name: `Asset ${i}`, kind: 'fixed' }))
const field = (name: string) => document.querySelector(`[name="${name}"]`) as HTMLInputElement
const cardQueries = () => queryBodies(clientMock, 'assets_card')
const count = () => document.querySelector('.caption .mono')?.textContent

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('T1/T3 paged list', () => {
  it('opens with one request of 100 cards and the notice', async () => {
    fakeServer(clientMock, { assets_card: cards(10500), org_unit: [] })
    renderAssets(PATH)
    expect(await screen.findByText(no(0))).toBeInTheDocument()
    expect(cardQueries()).toHaveLength(1)
    expect(cardQueries()[0]['page_size']).toBe(100)
    expect(cardQueries()[0]['cursor']).toBeUndefined()
    expect(count()).toBe('100+')
  })

  it('Load more follows the cursor to the end: all 10 500 cards, 105 requests, no loop', async () => {
    fakeServer(clientMock, { assets_card: cards(10500), org_unit: [] })
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    const { result } = renderHook(() => useAssetRows({ kind: '', orgUnitId: '', showRetired: false }, ''), { wrapper })
    await waitFor(() => expect(result.current.rows).toHaveLength(100))
    for (let i = 2; i <= 105; i++) {
      await waitFor(() => expect(result.current.hasMore).toBe(true))
      act(() => result.current.loadMore())
      await waitFor(() => expect(result.current.rows).toHaveLength(Math.min(i * 100, 10500)))
    }
    await waitFor(() => expect(result.current.hasMore).toBe(false))
    expect(result.current.truncated).toBe(false)
    expect(result.current.rows.at(-1)?.field_values['inventory_number']).toBe(no(10499))
    expect(cardQueries()).toHaveLength(105)
  }, 60_000)
})

describe('T2 search past the old cap', () => {
  it('finds card 10 400 with one server search on number and name, without loading pages', async () => {
    fakeServer(clientMock, { assets_card: cards(10500), org_unit: [] })
    renderAssets(PATH)
    await screen.findByText(no(0))
    fireEvent.change(field('filter_search'), { target: { value: no(10400) } })
    expect(await screen.findByText(no(10400))).toBeInTheDocument()
    const filters = cardQueries().flatMap((b) => b['filters'] as { field: string; op: string }[])
    expect(filters.filter((f) => f.op === 'contains').map((f) => f.field).sort()).toEqual(['inventory_number', 'name'])
    expect(screen.queryByTestId('asset-truncated')).not.toBeInTheDocument()
    expect(screen.queryByTestId('asset-load-more')).not.toBeInTheDocument()
  })
})

describe('T4 truncation notice', () => {
  it('list: banner and N+ while more pages exist, none on the last page', async () => {
    fakeServer(clientMock, { assets_card: cards(150), org_unit: [] })
    renderAssets(PATH)
    await screen.findByText(no(0))
    expect(screen.getByTestId('asset-truncated')).toHaveTextContent('Showing the first 100 cards')
    expect(count()).toBe('100+')
    fireEvent.click(screen.getByTestId('asset-load-more'))
    await waitFor(() => expect(count()).toBe('150'))
    expect(screen.queryByTestId('asset-truncated')).not.toBeInTheDocument()
  })

  it('search: banner when a query has more matches than one page, none when all fit', async () => {
    fakeServer(clientMock, { assets_card: cards(250), org_unit: [] })
    renderAssets(PATH)
    await screen.findByText(no(0))
    fireEvent.change(field('filter_search'), { target: { value: 'Asset' } })
    await waitFor(() => expect(screen.getByTestId('asset-truncated')).toHaveTextContent('matches'))
    expect(screen.queryByTestId('asset-load-more')).not.toBeInTheDocument()
    fireEvent.change(field('filter_search'), { target: { value: no(7) } })
    await waitFor(() => expect(screen.queryByTestId('asset-truncated')).not.toBeInTheDocument())
    expect(screen.getByText(no(7))).toBeInTheDocument()
  })
})

describe('T5 dedupe and wildcard characters', () => {
  it('a card matching both number and name shows once', async () => {
    const data = [rec('c-1', 'assets_card', { inventory_number: 'AB-1', name: 'AB-1 van' })]
    fakeServer(clientMock, { assets_card: data, org_unit: [] })
    renderAssets(PATH)
    await screen.findByText('AB-1')
    fireEvent.change(field('filter_search'), { target: { value: 'ab' } })
    await waitFor(() => expect(cardQueries().length).toBeGreaterThan(1))
    await waitFor(() => expect(screen.getAllByText('AB-1')).toHaveLength(1))
  })

  it('% and _ are escaped, so they search for themselves', async () => {
    const data = [
      rec('c-1', 'assets_card', { inventory_number: 'A_1', name: 'x' }),
      rec('c-2', 'assets_card', { inventory_number: 'AB1', name: 'y' }),
    ]
    fakeServer(clientMock, { assets_card: data, org_unit: [] })
    renderAssets(PATH)
    await screen.findByText('AB1')
    fireEvent.change(field('filter_search'), { target: { value: 'A_1' } })
    await waitFor(() => expect(screen.queryByText('AB1')).not.toBeInTheDocument())
    expect(screen.getByText('A_1')).toBeInTheDocument()
    const sent = cardQueries().at(-1)?.['filters'] as { value: unknown }[]
    expect(sent.some((f) => f.value === 'A\\_1')).toBe(true)
  })
})

describe('selected card after an edit', () => {
  it('the panel shows the saved values from the reloaded row, not the stale clicked object', async () => {
    const data = { assets_card: [rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Old name' })], org_unit: [] }
    fakeServer(clientMock, data)
    const { queryClient } = renderAssets(PATH)
    fireEvent.click(await screen.findByText('FA-1'))
    await screen.findByRole('form')
    expect(screen.getAllByText('Old name').length).toBeGreaterThan(0)
    data.assets_card[0] = rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'New name' })
    await queryClient.invalidateQueries()
    // the panel header follows the reloaded row, not the object stored at click time
    expect(await screen.findByRole('heading', { name: 'New name' })).toBeInTheDocument()
  })
})
