// @vitest-environment jsdom
/** T-1893 (master-detail slice 7): the webhook subscription detail is a pane of ListDetail, not a fixed
 *  overlay dialog; the `subscription` URL parameter still selects it, and closing clears the parameter. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, within, fireEvent } from '@testing-library/react'
import { MemoryRouter, useLocation } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import WebhooksPage from '@/pages/dlq/WebhooksPage'

const SESSION = {
  token: 'tok',
  display_name: 'Operator',
  loginSource: null as null,
  tenant_slug: 'test-tenant',
  tenant_display_name: 'Test Tenant',
  tenant_id: 'tid-test-tenant',
  tenant_type: 'production' as const,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function Where() {
  return <span data-testid="where">{useLocation().search}</span>
}

function mockAuth() {
  vi.mocked(useAuth).mockReturnValue({
    session: SESSION,
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  })
}

function mountPage(path: string) {
  mockAuth()
  vi.mocked(useQuery).mockImplementation(
    (opts: unknown) => {
      const key = (opts as { queryKey: readonly unknown[] }).queryKey
      const deliveries = key.includes('deliveries')
      return {
        data: deliveries
          ? { items: [] }
          : { items: [{ id: 'wh-1', subscription_id: 'wh-1', target_url: 'https://example.com/h', event_types: ['task.completed'], status: 'ACTIVE', created_at: '2026-01-01T00:00:00Z' }] },
        isLoading: false,
        isError: false,
        error: null,
        refetch: vi.fn(),
      } as unknown as ReturnType<typeof useQuery>
    },
  )
  return render(
    <MemoryRouter initialEntries={[path]}>
      <WebhooksPage />
      <Where />
    </MemoryRouter>,
  )
}

describe('T-1893 WebhooksPage on ListDetail', () => {
  it('opens the record in the details pane (no modal dialog) from the URL parameter', () => {
    mountPage('/webhooks?subscription=wh-1')
    const panel = screen.getByTestId('webhook-subscription-detail-panel')
    expect(within(screen.getByTestId('registry-details')).getByTestId('webhook-subscription-detail-panel')).toBe(panel)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('View details sets the parameter; Close and Escape clear it', () => {
    mountPage('/webhooks')
    expect(screen.queryByTestId('webhook-subscription-detail-panel')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'View details' }))
    expect(screen.getByTestId('where')).toHaveTextContent('subscription=wh-1')
    fireEvent.click(within(screen.getByTestId('webhook-subscription-detail-panel')).getByRole('button', { name: 'Close' }))
    expect(screen.getByTestId('where')).toHaveTextContent('')
    fireEvent.click(screen.getByRole('button', { name: 'View details' }))
    fireEvent.keyDown(screen.getByTestId('webhook-subscription-detail-panel'), { key: 'Escape' })
    expect(screen.getByTestId('where').textContent).toBe('')
  })
})
