// @vitest-environment jsdom
/** T-1442 H1-H6 — the remembered layout: localStorage fallback, 400 ms debounce, server value, failure, flush, tenant key. */
import { act, cleanup, render, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import React from 'react'

const put = vi.fn(async (p: Record<string, string | null>) => ({ preferences: p }))
let serverDoc: string | null = null
vi.mock('@/api/preferences', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api/preferences')>()
  return {
    ...actual,
    preferencesApi: {
      get: vi.fn(async () => ({ preferences: serverDoc ? { 'ui.layout': serverDoc } : {} })),
      put: (p: Record<string, string | null>) => put(p),
    },
  }
})
let tenant = 'tenant-a'
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { tenant_id: tenant }, isAuthenticated: true }),
}))

import { LayoutPrefsProvider, resetDefaultLayoutStore, useLayoutPrefs } from '../useLayoutPrefs'
import { LAYOUT_STORAGE_KEY } from '@/lib/layoutStore'

function wrap() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>
      <LayoutPrefsProvider>{children}</LayoutPrefsProvider>
    </QueryClientProvider>
  )
}

beforeEach(() => {
  localStorage.clear()
  serverDoc = null
  tenant = 'tenant-a'
  put.mockClear()
  put.mockImplementation(async (p) => ({ preferences: p }))
  resetDefaultLayoutStore()
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('useLayoutPrefs', () => {
  it('H1 without a provider the store is local only: localStorage anon key, no network', () => {
    vi.useFakeTimers()
    const { result } = renderHook(() => useLayoutPrefs())
    act(() => result.current.setPanes('s', 'sp', [25, null]))
    act(() => void vi.advanceTimersByTime(400))
    expect(JSON.parse(localStorage.getItem(`${LAYOUT_STORAGE_KEY}.anon`) ?? '{}').screens.s.panes.sp).toEqual([25, null])
    expect(put).not.toHaveBeenCalled()
    resetDefaultLayoutStore()
    const again = renderHook(() => useLayoutPrefs())
    expect(again.result.current.getPanes('s', 'sp')).toEqual([25, null])
  })

  it('H2 five edits in 300 ms give one PUT with the last value after 400 ms', async () => {
    const { result } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    await waitFor(() => expect(result.current).toBeTruthy())
    vi.useFakeTimers()
    for (let i = 1; i <= 5; i++) {
      act(() => result.current.setPanes('s', 'sp', [10 + i, null]))
      act(() => void vi.advanceTimersByTime(60))
    }
    expect(put).not.toHaveBeenCalled()
    await act(async () => void vi.advanceTimersByTime(400))
    expect(put).toHaveBeenCalledTimes(1)
    const sent = JSON.parse(put.mock.calls[0][0]['ui.layout'] as string)
    expect(sent.screens.s.panes.sp).toEqual([15, null])
  })

  it('H3 the server value is applied when nothing changed locally; a local edit then wins', async () => {
    serverDoc = JSON.stringify({ v: 1, shell: { sidenav: { w: 300 } }, screens: {} })
    const { result } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    await waitFor(() => expect(result.current.getShell().w).toBe(300))
    act(() => result.current.setShell({ w: 280 }))
    expect(result.current.getShell().w).toBe(280)
  })

  it('H3b a local edit made before the server value arrives is not overwritten', async () => {
    serverDoc = JSON.stringify({ v: 1, shell: { sidenav: { w: 300 } }, screens: {} })
    const { result } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    act(() => result.current.setShell({ w: 250 }))
    await new Promise((r) => setTimeout(r, 50))
    expect(result.current.getShell().w).toBe(250)
  })

  it('H4 a failed PUT keeps the local copy and does not throw', async () => {
    put.mockRejectedValue(new Error('down'))
    const { result } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    act(() => result.current.setCols('s', 't', { a: 20 }))
    act(() => result.current.flush())
    await waitFor(() => expect(put).toHaveBeenCalled())
    expect(JSON.parse(localStorage.getItem(`${LAYOUT_STORAGE_KEY}.tenant-a`) ?? '{}').screens.s.cols.t).toEqual({ a: 20 })
    expect(result.current.getCols('s', 't')).toEqual({ a: 20 })
  })

  it('H5 unmount before the debounce fires still sends the PUT', async () => {
    const { result, unmount } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    act(() => result.current.setPanes('s', 'sp', [30, null]))
    expect(put).not.toHaveBeenCalled()
    unmount()
    await waitFor(() => expect(put).toHaveBeenCalledTimes(1))
  })

  it('H5b pagehide flushes', async () => {
    const { result } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    act(() => result.current.setPanes('s', 'sp', [30, null]))
    act(() => void window.dispatchEvent(new Event('pagehide')))
    await waitFor(() => expect(put).toHaveBeenCalledTimes(1))
  })

  it('H6 the fallback key is tenant-scoped: tenant B does not read tenant A', () => {
    function Probe({ out }: { out: { v: unknown } }) {
      out.v = useLayoutPrefs().getPanes('s', 'sp')
      return null
    }
    const a = { v: undefined as unknown }
    const r = render(<Probe out={a} />, { wrapper: wrap() })
    expect(a.v).toBeNull()
    // write as tenant A through a store, flush, then mount tenant B
    const { result } = renderHook(() => useLayoutPrefs(), { wrapper: wrap() })
    act(() => result.current.setPanes('s', 'sp', [40, null]))
    act(() => result.current.flush())
    expect(localStorage.getItem(`${LAYOUT_STORAGE_KEY}.tenant-a`)).toContain('40')
    r.unmount()
    tenant = 'tenant-b'
    const b = { v: undefined as unknown }
    render(<Probe out={b} />, { wrapper: wrap() })
    expect(b.v).toBeNull()
    expect(localStorage.getItem(`${LAYOUT_STORAGE_KEY}.tenant-b`)).toBeNull()
  })
})
