// @vitest-environment jsdom
/**
 * GH #2589: the API tokens page types and displays the four effective token
 * statuses that GH #2552 sends (active | revoked | expired | owner_inactive,
 * lowercase) and the token's issuer.
 *
 * End to end: TokensPage, @/api/identity, @/api/client and the real
 * react-query QueryClientProvider all run. Only window.fetch is stubbed (a
 * URL router returning the GET /identity/tokens and GET /identity/users
 * bodies in the shape lib/letflow/routers/identity.ex token_map/2 emits), so
 * the test exercises the real client parsing. As edge cases, two rows
 * deliberately omit a field (one has no status, one has no issuer_user_id)
 * and two rows carry unknown statuses ('suspended' and 'toString'). Same
 * harness as src/pages/tasks/__tests__/TaskInboxPage.sodMessage.test.tsx.
 *
 * Why this fails on the pre-fix page: the Status cell chose its colour only
 * from revoked_at, so every row without revoked_at (expired, owner_inactive,
 * a row with no status and the two unknown-status rows) was drawn in
 * --color-success-dark; it printed the raw status string and fell back to
 * 'ACTIVE'; and there was no issuer column.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, within } from '@testing-library/react'
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

import TokensPage from '@/pages/admin/TokensPage'
import { renderWithAccess } from '@/auth/access/testing'
import type { AccessFixtureName } from '@/auth/access/fixtures'
import type { ApiTokenStatus } from '@/types/api'

const SUCCESS_COLOUR = 'var(--color-success-dark)'

function user(id: string, displayName: string) {
  return {
    id,
    username: id,
    display_name: displayName,
    email: `${id}@example.com`,
    status: 'active',
    auth_source: 'internal',
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  }
}

const USERS = [user('u-owner', 'Token Owner'), user('u-issuer', 'Issuer Admin')]

// The token_map/2 wire shape after GH 2552. Row order is the render order
// (DataTable keeps data order when no column is sorted).
const TOKENS: Record<string, unknown>[] = [
  {
    id: 'tok-active',
    name: null,
    user_id: 'u-owner',
    issuer_user_id: 'u-issuer',
    roles: ['SOME_ROLE'],
    status: 'active',
    created_at: '2026-10-01T00:00:00Z',
    expires_at: null,
    revoked_at: null,
    last_used_at: null,
  },
  {
    id: 'tok-revoked',
    name: null,
    user_id: 'u-owner',
    issuer_user_id: 'u-gone-issuer',
    roles: ['SOME_ROLE'],
    status: 'revoked',
    created_at: '2026-10-01T00:00:00Z',
    expires_at: null,
    revoked_at: '2026-10-02T00:00:00Z',
    last_used_at: null,
  },
  {
    id: 'tok-expired',
    name: null,
    user_id: 'u-owner',
    issuer_user_id: null,
    roles: ['SOME_ROLE'],
    status: 'expired',
    created_at: '2026-01-01T00:00:00Z',
    expires_at: '2026-02-01T00:00:00Z',
    revoked_at: null,
    last_used_at: null,
  },
  {
    id: 'tok-owner-inactive',
    name: null,
    user_id: 'u-owner',
    roles: ['SOME_ROLE'],
    status: 'owner_inactive',
    created_at: '2026-10-01T00:00:00Z',
    expires_at: null,
    revoked_at: null,
    last_used_at: null,
  },
  {
    // No status at all: must render a neutral "Unknown", never green "ACTIVE".
    id: 'tok-no-status',
    name: null,
    user_id: 'u-owner',
    issuer_user_id: null,
    roles: ['SOME_ROLE'],
    created_at: '2026-10-01T00:00:00Z',
    expires_at: null,
    revoked_at: null,
    last_used_at: null,
  },
  {
    // An unknown, non-empty status: must render "Unknown", never green.
    id: 'tok-suspended',
    name: 'suspended-token',
    user_id: 'u-owner',
    issuer_user_id: null,
    roles: ['SOME_ROLE'],
    status: 'suspended' as unknown as ApiTokenStatus,
    created_at: '2026-10-01T00:00:00Z',
    expires_at: null,
    revoked_at: null,
    last_used_at: null,
  },
  {
    // An unknown status that names an Object.prototype member: a plain
    // `in` or indexed lookup would hit the prototype; it must render "Unknown".
    id: 'tok-tostring',
    name: 'tostring-token',
    user_id: 'u-owner',
    issuer_user_id: null,
    roles: ['SOME_ROLE'],
    status: 'toString' as unknown as ApiTokenStatus,
    created_at: '2026-10-01T00:00:00Z',
    expires_at: null,
    revoked_at: null,
    last_used_at: null,
  },
]

const ROW_ACTIVE = 0
const ROW_REVOKED = 1
const ROW_EXPIRED = 2
const ROW_OWNER_INACTIVE = 3
const ROW_NO_STATUS = 4
const ROW_SUSPENDED = 5
const ROW_TOSTRING = 6

type Route = { ok: boolean; status: number; statusText: string; body: unknown }
const ok200 = (body: unknown): Route => ({ ok: true, status: 200, statusText: 'OK', body })

function stubNetwork() {
  const calls: string[] = []
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, init?: RequestInit) => {
      const method = init?.method ?? 'GET'
      const path = String(url).split('?')[0]
      calls.push(`${method} ${path}`)
      let r: Route
      if (method === 'GET' && path.endsWith('/api/v1/identity/tokens')) {
        r = ok200({ items: TOKENS })
      } else if (method === 'GET' && path.endsWith('/api/v1/identity/users')) {
        r = ok200({ items: USERS, next_cursor: null, count: USERS.length })
      } else {
        r = { ok: false, status: 404, statusText: 'Not Found', body: { title: 'Not Found' } }
      }
      return {
        ok: r.ok,
        status: r.status,
        statusText: r.statusText,
        json: async () => r.body,
        text: async () => JSON.stringify(r.body),
        headers: { get: () => null },
      }
    }),
  )
  return calls
}

function renderPage(access: AccessFixtureName = 'tenantAdmin') {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <TokensPage />
      </MemoryRouter>
    </QueryClientProvider>,
    access,
  )
}

async function renderedRows(access: AccessFixtureName = 'tenantAdmin'): Promise<HTMLElement[]> {
  const calls = stubNetwork()
  renderPage(access)
  await waitFor(() => expect(screen.getAllByTestId('datatable-row')).toHaveLength(TOKENS.length))
  expect(calls).toContain('GET /api/v1/identity/tokens')
  return screen.getAllByTestId('datatable-row')
}

/** The element inside the Status cell that carries the status text and colour. */
function statusElement(row: HTMLElement): HTMLElement {
  const cell = within(row).getByTestId('datatable-cell-status')
  const el = cell.querySelector('span')
  if (!el) throw new Error('status cell has no span')
  return el as HTMLElement
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

describe('GH-2589 TokensPage: the four effective token statuses and the issuer', () => {
  it('only the active row uses the success (green) colour; revoked, expired, owner_inactive, a missing status and an unknown status do not', async () => {
    const rows = await renderedRows()

    expect(statusElement(rows[ROW_ACTIVE]).style.color).toBe(SUCCESS_COLOUR)

    for (const index of [ROW_REVOKED, ROW_EXPIRED, ROW_OWNER_INACTIVE, ROW_NO_STATUS, ROW_SUSPENDED, ROW_TOSTRING]) {
      const colour = statusElement(rows[index]).style.color
      expect(colour, `row ${index} (${String(TOKENS[index].status)}) must not be a success colour`).not.toContain('success')
    }
  })

  it('each status has its own human-readable label, and a missing or unknown status reads "Unknown", never "ACTIVE"', async () => {
    const rows = await renderedRows()

    expect(statusElement(rows[ROW_ACTIVE]).textContent).toBe('Active')
    expect(statusElement(rows[ROW_REVOKED]).textContent).toBe('Revoked')
    expect(statusElement(rows[ROW_EXPIRED]).textContent).toBe('Expired')
    expect(statusElement(rows[ROW_OWNER_INACTIVE]).textContent).toBe('Owner inactive')
    expect(statusElement(rows[ROW_NO_STATUS]).textContent).toBe('Unknown')
    expect(statusElement(rows[ROW_SUSPENDED]).textContent).toBe('Unknown')
    expect(statusElement(rows[ROW_TOSTRING]).textContent).toBe('Unknown')

    // The four known statuses render with four distinct colours.
    const colours = [ROW_ACTIVE, ROW_REVOKED, ROW_EXPIRED, ROW_OWNER_INACTIVE].map(
      (index) => statusElement(rows[index]).style.color,
    )
    expect(new Set(colours).size).toBe(4)
  })

  it('shows the issuer: a known user by display name, an unknown id as the id, a null or absent issuer (legacy) as a dash', async () => {
    const rows = await renderedRows()
    const issuerText = (index: number) =>
      within(rows[index]).getByTestId('datatable-cell-issuer').textContent

    expect(screen.getByTestId('datatable-header-issuer')).toBeInTheDocument()
    await waitFor(() => expect(issuerText(ROW_ACTIVE)).toBe('Issuer Admin'))
    expect(issuerText(ROW_REVOKED)).toBe('u-gone-issuer')
    expect(issuerText(ROW_EXPIRED)).toBe('—')
    expect(issuerText(ROW_OWNER_INACTIVE)).toBe('—')
  })
})

describe('GH 2238 BUILDS 5 — TokensPage write controls follow TokensManage', () => {
  it('a tenant admin sees the issue and revoke controls', async () => {
    await renderedRows('tenantAdmin')
    expect(screen.getByText('+ Issue token')).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Revoke' }).length).toBeGreaterThan(0)
  })

  it('an auditor sees the rows but no issue or revoke control', async () => {
    await renderedRows('auditor')
    expect(screen.queryByText('+ Issue token')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Revoke' })).not.toBeInTheDocument()
  })
})
