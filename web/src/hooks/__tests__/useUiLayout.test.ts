// @vitest-environment jsdom
/** T-1431 — typed `ui.layout` key and hook (W1-W3). */
import { renderHook, waitFor, act } from '@testing-library/react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import React from 'react'

const GOOD = JSON.stringify({
  v: 1,
  shell: { sidenav: { collapsed: true, w: 250 } },
  screens: { 'stock.journal': { panes: { details: [38.3, null] } } },
})

vi.mock('@/api/preferences', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api/preferences')>()
  return {
    ...actual,
    preferencesApi: {
      get: vi.fn(async () => ({ preferences: { 'ui.layout': GOOD } })),
      put: vi.fn(async (p: Record<string, string | null>) => ({ preferences: p })),
    },
  }
})

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 't',
        display_name: 'User',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-abc-123',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { emptyUiLayout, parseUiLayout, preferencesApi } from '@/api/preferences'
import { queryKeys } from '@/api/queryKeys'
import { useUiLayout } from '../useUiLayout'

afterEach(() => vi.clearAllMocks())

function setup() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: qc }, children)
  return { qc, wrapper }
}

describe('parseUiLayout (W1)', () => {
  it('gives the empty layout for null, non-string and invalid JSON', () => {
    expect(parseUiLayout(null)).toEqual(emptyUiLayout())
    expect(parseUiLayout(5)).toEqual(emptyUiLayout())
    expect(parseUiLayout('{nope')).toEqual(emptyUiLayout())
    expect(parseUiLayout('[1]')).toEqual(emptyUiLayout())
  })

  it('parses a good document', () => {
    expect(parseUiLayout(GOOD).shell.sidenav).toEqual({ collapsed: true, w: 250 })
    expect(parseUiLayout(GOOD).screens['stock.journal']?.panes).toEqual({ details: [38.3, null] })
  })
})

describe('useUiLayout', () => {
  it('W2 returns the parsed layout under a tenant-scoped key', async () => {
    const { qc, wrapper } = setup()
    const { result } = renderHook(() => useUiLayout(), { wrapper })
    await waitFor(() => expect(result.current.layout).toBeDefined())
    expect(result.current.layout?.shell.sidenav.w).toBe(250)
    expect(qc.getQueryData(queryKeys.me.preferences('tenant-abc-123'))).toBeDefined()
  })

  it('W3 save PUTs the serialized string and reset PUTs null', async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useUiLayout(), { wrapper })
    await waitFor(() => expect(result.current.layout).toBeDefined())
    const layout = emptyUiLayout()
    await act(async () => {
      await result.current.save(layout)
    })
    expect(preferencesApi.put).toHaveBeenLastCalledWith({ 'ui.layout': JSON.stringify(layout) })
    await act(async () => {
      await result.current.reset()
    })
    expect(preferencesApi.put).toHaveBeenLastCalledWith({ 'ui.layout': null })
  })
})
