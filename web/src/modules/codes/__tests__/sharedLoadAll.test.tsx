// @vitest-environment jsdom
/** T-1812 — code lookups use the shared fetchAllRecords: the cap marks the list `truncated`. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { entitiesApi } from '@/api/entities'
import { MAX_PAGES, anyTruncated, fetchAllRecords as shared } from '@/lib/entities/fetchAllRecords'
import { fetchAllRecords as codesFetch } from '../codes.api'
import { useCodeRows, useOpenAssignments } from '../CodesShell'

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-load-all' } }) }))
vi.mock('@/api/entities', () => ({ entitiesApi: { queryRecords: vi.fn() } }))

const query = vi.mocked(entitiesApi.queryRecords)
const rec = (i: number) => ({ record_id: `r${i}`, field_values: { code: `C${i}` } }) as never
const wrapper = ({ children }: { children: ReactNode }) => (
  <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
)
const endless = () => {
  let n = 0
  query.mockImplementation((async () => ({ items: [rec(1)], next_cursor: `c${(n += 1)}` })) as never)
}

beforeEach(() => query.mockReset())

describe('shared load-all loop', () => {
  it('L1: codes re-exports the shared helper (no private copy)', () => {
    expect(codesFetch).toBe(shared)
  })

  it('L3: code rows stop at the cap and carry the truncated flag', async () => {
    endless()
    const { result } = renderHook(() => useCodeRows('code_tag', 'all', []), { wrapper })
    await waitFor(() => expect(result.current.data).toHaveLength(MAX_PAGES))
    expect(anyTruncated([result.current])).toBe(true)
  })

  it('L4: open assignments keep the flag; a short list has none', async () => {
    endless()
    const cut = renderHook(() => useOpenAssignments(['a']), { wrapper })
    await waitFor(() => expect(cut.result.current.data).toHaveLength(MAX_PAGES))
    expect(anyTruncated([cut.result.current])).toBe(true)
    query.mockReset()
    query.mockResolvedValue({ items: [rec(1)], next_cursor: null } as never)
    const ok = renderHook(() => useCodeRows('code_tag', 'short', []), { wrapper })
    await waitFor(() => expect(ok.result.current.data).toHaveLength(1))
    expect(anyTruncated([ok.result.current])).toBe(false)
  })
})
