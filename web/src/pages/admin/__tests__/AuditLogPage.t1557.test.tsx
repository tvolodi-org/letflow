// @vitest-environment jsdom
/**
 * T-1557 (B2 #5): the Audit log shows the user's name (not the id), filters by user and by object
 * (type + id), exports the filtered list as CSV, and has en/ru/kk labels with the same id set.
 * Only window.fetch is stubbed; the page, api client and react-query run for real.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'admin-id' })) + '.sig',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
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

import AuditLogPage from '@/pages/admin/AuditLogPage'
import { renderWithAccess } from '@/auth/access/testing'
import { auditMessages } from '@/i18n/auditMessages'

const USERS = [
  { id: 'u1', username: 'ann', display_name: 'Ann Admin', email: 'a@x.test', status: 'active', auth_source: 'internal', inserted_at: '', updated_at: '' },
]

const ENTRY = {
  audit_id: 'a1',
  actor_id: 'u1',
  actor_name: 'Ann Admin',
  resource_name: null,
  action: 'document.posted',
  resource_type: 'document',
  resource_id: 'doc-7',
  timestamp: '2026-11-01T10:00:00Z',
  before_state: null,
  after_state: null,
}

function stubNetwork(truncated = false) {
  const urls: string[] = []
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string) => {
      urls.push(String(url))
      const path = String(url).split('?')[0]
      const isCsv = String(url).includes('format=csv')
      const body = path.endsWith('/api/v1/audit')
        ? { items: [ENTRY], next_cursor: null, count: 1 }
        : { items: USERS, next_cursor: null, count: 1 }
      return {
        ok: true,
        status: 200,
        statusText: 'OK',
        json: async () => body,
        text: async () => JSON.stringify(body),
        blob: async () => new Blob(['timestamp\r\n'], { type: 'text/csv' }),
        headers: {
          get: (k: string) =>
            k.toLowerCase() === 'x-audit-export-truncated' && isCsv ? String(truncated) : k.toLowerCase() === 'content-type' ? (isCsv ? 'text/csv' : 'application/json') : null,
        },
      }
    }),
  )
  return urls
}

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <AuditLogPage />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

describe('T-1557 AuditLogPage', () => {
  it('W1 the row shows the name, the user select sends actor_id, the object filters send type and id', async () => {
    const urls = stubNetwork()
    renderPage()
    expect(await screen.findByText('Ann Admin', { selector: 'span' })).toBeInTheDocument()
    expect(screen.getByText('Document posted')).toBeInTheDocument()

    await screen.findByRole('option', { name: 'Ann Admin' })
    fireEvent.change(screen.getByLabelText('User'), { target: { value: 'u1' } })
    fireEvent.change(screen.getByLabelText('Object type'), { target: { value: 'document' } })
    fireEvent.change(screen.getByLabelText('Object id'), { target: { value: 'doc-7' } })

    await waitFor(() => {
      const last = urls.filter((u) => u.includes('/api/v1/audit')).pop() ?? ''
      expect(last).toContain('actor_id=u1')
      expect(last).toContain('resource_type=document')
      expect(last).toContain('resource_id=doc-7')
    })
  })

  it('W2 the export button requests format=csv with the current filters and shows the truncation note', async () => {
    const urls = stubNetwork(true)
    URL.createObjectURL = vi.fn(() => 'blob:x')
    URL.revokeObjectURL = vi.fn()
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    renderPage()
    await screen.findByText('Document posted')
    fireEvent.change(screen.getByLabelText('Object id'), { target: { value: 'doc-7' } })
    fireEvent.click(screen.getByRole('button', { name: 'Export CSV' }))

    expect(await screen.findByText(/first 10 000 rows/)).toBeInTheDocument()
    const csv = urls.find((u) => u.includes('format=csv')) ?? ''
    expect(csv).toContain('resource_id=doc-7')
    expect(csv).not.toContain('cursor=')
  })

  it('W3 en, ru and kk catalogs have the same id set and no empty text', () => {
    const ids = Object.keys(auditMessages.en).sort()
    expect(Object.keys(auditMessages.ru).sort()).toEqual(ids)
    expect(Object.keys(auditMessages.kk).sort()).toEqual(ids)
    for (const locale of ['en', 'ru', 'kk'] as const) {
      for (const id of ids) expect(auditMessages[locale][id].length).toBeGreaterThan(0)
    }
    expect(auditMessages.ru['audit.title']).toBe('Журнал аудита')
  })
})
