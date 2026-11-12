// @vitest-environment jsdom
/** T-1804 P2 — the assets picker reads every page up to the cap and keeps the truncated flag. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { entitiesApi } from '@/api/entities'
import { MAX_PAGES } from '@/lib/entities/fetchAllRecords'
import { usePickerOptions, usePickerState, anyPickerTruncated } from '../assetsPickers'

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-pick-assets' } }) }))
vi.mock('@/api/entities', () => ({ entitiesApi: { queryRecords: vi.fn() } }))

const query = vi.mocked(entitiesApi.queryRecords)
const rec = (i: number) => ({ record_id: `r${i}`, field_values: { code: `C${i}`, name: `Item ${i}` } }) as never
const wrapper = ({ children }: { children: ReactNode }) => (
  <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
)

beforeEach(() => query.mockReset())

describe('stock usePickerOptions', () => {
  it('P1: returns record 450 when the server serves 450 rows in three pages', async () => {
    query.mockImplementation((async (_t: string, body?: { cursor?: string }) => {
      const page = body?.cursor ? Number(body?.cursor) : 0
      const from = page * 200
      const to = Math.min(from + 200, 450)
      return { items: Array.from({ length: to - from }, (_, i) => rec(from + i + 1)), next_cursor: to < 450 ? String(page + 1) : null }
    }) as never)
    const { result } = renderHook(() => usePickerOptions('catalog_item'), { wrapper })
    await waitFor(() => expect(result.current).toHaveLength(450))
    expect(result.current[449]?.value).toBe('r450')
    expect(query).toHaveBeenCalledTimes(3)
    expect(anyPickerTruncated(result.current)).toBe(false)
  })

  it('P3: 200 rows or fewer is one request and no flag', async () => {
    query.mockResolvedValue({ items: [rec(1), rec(2)], next_cursor: null } as never)
    const { result } = renderHook(() => usePickerOptions('catalog_item'), { wrapper })
    await waitFor(() => expect(result.current).toHaveLength(2))
    expect(query).toHaveBeenCalledTimes(1)
    expect(query.mock.calls[0]?.[1]).not.toHaveProperty('sort')
    expect(anyPickerTruncated(result.current)).toBe(false)
  })

  it('P4: a server that never ends stops at the cap and the flag survives the hook', async () => {
    let n = 0
    query.mockImplementation((async () => ({ items: [rec(1)], next_cursor: `c${(n += 1)}` })) as never)
    const { result } = renderHook(() => usePickerOptions('catalog_item'), { wrapper })
    await waitFor(() => expect(result.current).toHaveLength(MAX_PAGES))
    expect(anyPickerTruncated(result.current)).toBe(true)
  })

  it('P2: usePickerState is ready with all 450 options', async () => {
    query.mockImplementation((async (_t: string, body?: { cursor?: string }) => {
      const first = !body?.cursor
      return { items: Array.from({ length: first ? 200 : 250 }, (_, i) => rec(i + 1)), next_cursor: first ? 'a' : null }
    }) as never)
    const { result } = renderHook(() => usePickerState('assets_card'), { wrapper })
    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(result.current.options).toHaveLength(450)
  })
})
