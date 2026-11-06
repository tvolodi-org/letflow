// @vitest-environment jsdom
/** L2 — the effective layout read: any odd answer is `row`. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor, cleanup } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { useDocumentLayout } from '../useDocumentLayout'

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

function wrap() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

beforeEach(() => clientMock.get.mockReset())
afterEach(() => cleanup())

describe('L2 useDocumentLayout', () => {
  it('reads the effective layout from GET /me/preferences', async () => {
    clientMock.get.mockResolvedValue({ preferences: {}, effective: { 'ui.document_layout': 'tabs' }, tenant_defaults: {} })
    const { result } = renderHook(() => useDocumentLayout(), { wrapper: wrap() })
    expect(result.current).toBe('row')
    await waitFor(() => expect(result.current).toBe('tabs'))
    expect(clientMock.get).toHaveBeenCalledWith('/api/v1/me/preferences')
  })

  it.each([
    ['unknown layout', { effective: { 'ui.document_layout': 'grid' } }],
    ['list-shaped answer', { rows: [], next_cursor: null }],
    ['null answer', null],
  ])('%s gives row', async (_n, answer) => {
    clientMock.get.mockResolvedValue(answer)
    const { result } = renderHook(() => useDocumentLayout(), { wrapper: wrap() })
    await waitFor(() => expect(clientMock.get).toHaveBeenCalled())
    expect(result.current).toBe('row')
  })
  // A rejected read gives row: covered through the workspace in DocumentsWorkspace.layout.test.tsx (L3, case 'fail').
})
