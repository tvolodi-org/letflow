// @vitest-environment jsdom
/** T-1448 U7: the remembered entry mode of the lines editor. */
import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import React from 'react'

const STORED = JSON.stringify({ v: 1, shell: { sidenav: {} }, screens: { 'stock-documents.lines': { cols: { t: { c: 30 } }, linesMode: 'form' }, other: { panes: { a: [40, null] } } } })

const api = vi.hoisted(() => ({ get: vi.fn(), put: vi.fn() }))
vi.mock('@/api/preferences', async (importOriginal) => ({ ...(await importOriginal<typeof import('@/api/preferences')>()), preferencesApi: api }))
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 't', tenant_id: 'tid' }, isAuthenticated: true }),
}))

import { useLinesMode } from '../useLinesMode'

const wrapper = () => {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => React.createElement(QueryClientProvider, { client: qc }, children)
}

beforeEach(() => {
  localStorage.clear()
  api.get.mockReset().mockResolvedValue({ preferences: { 'ui.layout': STORED } })
  api.put.mockReset().mockImplementation(async (p: Record<string, string | null>) => ({ preferences: p }))
})
afterEach(() => vi.clearAllMocks())

describe('U7 useLinesMode', () => {
  it('reads the stored mode of the screen; grid is the default', async () => {
    const { result } = renderHook(() => useLinesMode('stock-documents.lines'), { wrapper: wrapper() })
    await waitFor(() => expect(result.current[0]).toBe('form'))
    const other = renderHook(() => useLinesMode('nowhere'), { wrapper: wrapper() })
    await waitFor(() => expect(api.get).toHaveBeenCalled())
    expect(other.result.current[0]).toBe('grid')
  })

  it('writes the mode merged into the document: panes, cols and other screens stay', async () => {
    const { result } = renderHook(() => useLinesMode('stock-documents.lines'), { wrapper: wrapper() })
    await waitFor(() => expect(result.current[0]).toBe('form'))
    act(() => result.current[1]('grid'))
    await waitFor(() => expect(api.put).toHaveBeenCalledTimes(1))
    const sent = JSON.parse((api.put.mock.calls[0]![0] as Record<string, string>)['ui.layout']!)
    expect(sent.screens['stock-documents.lines']).toEqual({ cols: { t: { c: 30 } }, linesMode: 'grid' })
    expect(sent.screens['other']).toEqual({ panes: { a: [40, null] } })
    expect(result.current[0]).toBe('grid')
  })

  it('falls back to localStorage when the preference cannot be saved or read', async () => {
    api.get.mockReset().mockRejectedValue(new Error('offline'))
    api.put.mockReset().mockRejectedValue(new Error('offline'))
    const first = renderHook(() => useLinesMode('s1'), { wrapper: wrapper() })
    act(() => first.result.current[1]('form'))
    expect(localStorage.getItem('lf.linesMode.s1')).toBe('form')
    first.unmount()
    const again = renderHook(() => useLinesMode('s1'), { wrapper: wrapper() })
    expect(again.result.current[0]).toBe('form')
  })
})
