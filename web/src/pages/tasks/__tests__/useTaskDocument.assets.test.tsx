// @vitest-environment jsdom
/** T-1942: an asset document task (assets_opening) resolves its document, not "Document not available". */
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { describe, expect, it, vi } from 'vitest'

const get = vi.fn()
vi.mock('@/api/client', () => ({ client: { get: (...a: unknown[]) => get(...a) } }))
vi.mock('@/api/instances', () => ({
  instancesApi: { get: async () => ({ id: 'i1', variables: { document_id: 'op1', document_type: 'assets_opening' } }) },
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { tenant_id: 't1' } }) }))

import { useTaskContexts } from '../useTaskDocument'

describe('useTaskContexts asset documents', () => {
  it('reads the asset document of an assets_opening instance with number, kind and lines', async () => {
    get.mockImplementation(async (path: string) => {
      if (path === '/api/v1/modules/assets/documents/op1') {
        return {
          id: 'op1', kind: 'opening', state: 'issued', number: 'AOP-2026-000001', org_unit_id: 'u1', issued_at: '2026-11-14T08:00:00Z',
          lines: [{ line_no: 1, asset_id: 'a1', quantity: '1', location_id: 'l1', inventory_number: 'FA-1', asset_name: 'Van' }],
        }
      }
      return { items: [{ actor_id: 'u9', actor_label: 'Saule Zhumabek' }] }
    })
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    const { result } = renderHook(() => useTaskContexts(['i1']), { wrapper })
    await waitFor(() => expect(result.current('i1')).toBeTruthy())
    const doc = result.current('i1')?.doc
    expect(doc?.number).toBe('AOP-2026-000001')
    expect(doc?.typeKey).toBe('assets_opening')
    expect(doc?.orgUnitId).toBe('u1')
    expect(doc?.eventTime).toBe('2026-11-14T08:00:00Z')
    expect(result.current('i1')?.issuerLabel).toBe('Saule Zhumabek')
    expect(doc?.lines[0]?.assetId).toBe('a1')
    expect(doc?.lines[0]?.locationId).toBe('l1')
  })
})
