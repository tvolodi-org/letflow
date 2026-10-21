// @vitest-environment jsdom
/**
 * ISS-0916 (Q-909): ServicesPage row-action and dialog-cancel click handlers
 * must defer their setState by one macrotask (deferClickState, ISS-0662
 * family). Pins that the dialog does NOT open synchronously inside the click,
 * but does once the deferred task runs.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, act } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({ session: { roles: ['platform-admin'], token: 't' } })),
}))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: vi.fn(() => ({ admin: { services: () => ['services'] } })),
}))

const SERVICE = {
  service_id: 'svc-1',
  endpoint_url: 'https://example.test/svc',
  request_schema: '{}',
  response_schema: '{}',
  required_auth: 'none',
  timeout_ms: 5000,
  max_retries: 0,
  scope: 'global',
  owner_tenant_id: null,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
}

vi.mock('@tanstack/react-query', () => ({
  useQuery: () => ({
    data: { items: [SERVICE], next_cursor: null },
    isLoading: false, isError: false, error: null, refetch: vi.fn(),
  }),
  useMutation: () => ({ mutate: vi.fn(), isPending: false, isError: false, error: null }),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))

import ServicesPage from '../ServicesPage'
import { renderWithAccess } from '@/auth/access/testing'

afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('ISS-0916 — ServicesPage defers click-driven state', () => {
  it('Delete opens its confirm dialog only after a macrotask; Cancel closes it likewise', () => {
    vi.useFakeTimers()
    renderWithAccess(React.createElement(ServicesPage))

    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    expect(screen.queryAllByRole('button', { name: /cancel/i })).toHaveLength(0)

    act(() => { vi.runAllTimers() })
    const cancel = screen.getByRole('button', { name: /cancel/i })

    fireEvent.click(cancel)
    expect(screen.queryAllByRole('button', { name: /cancel/i })).toHaveLength(1)

    act(() => { vi.runAllTimers() })
    expect(screen.queryAllByRole('button', { name: /cancel/i })).toHaveLength(0)
  })

  it('Edit scope opens only after a macrotask', () => {
    vi.useFakeTimers()
    renderWithAccess(React.createElement(ServicesPage))

    fireEvent.click(screen.getByRole('button', { name: /edit scope/i }))
    expect(screen.queryAllByRole('button', { name: /cancel/i })).toHaveLength(0)

    act(() => { vi.runAllTimers() })
    expect(screen.getAllByRole('button', { name: /cancel/i })).toHaveLength(1)
  })
})
