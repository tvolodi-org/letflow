// @vitest-environment jsdom
/**
 * Unit tests — ISS-0532 (liveness) and T-1607 (per-part readiness and the backup line).
 * ISS-0532 TC-12/TC-13 asserted that the page shows NO per-subsystem data and says readiness is
 * "not available yet"; T-1607 delivers that readiness (GET /ready), so those two are replaced by
 * W1-* tests below that assert the new behaviour.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/api/queryKeys', () => ({
  queryKeys: {
    admin: {
      health: vi.fn(() => ['admin', 'health']),
      readiness: vi.fn(() => ['admin', 'readiness']),
      backupStatus: vi.fn(() => ['admin', 'backup-status']),
    },
  },
}))

vi.mock('react-router-dom', () => ({
  Navigate: ({ to }: { to: string }) => <div data-testid="navigate" data-to={to} />,
}))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import HealthDashboardPage from '@/pages/admin/HealthDashboardPage'
import { renderWithAccess } from '@/auth/access/testing'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

const ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  loginSource: null,
  tenant_slug: 'platform',
  tenant_display_name: 'Platform',
  tenant_id: 'tid-platform',
  tenant_type: 'production' as const,
}

const NON_ADMIN_SESSION = { ...ADMIN_SESSION }

function queryResult(overrides: Record<string, unknown>) {
  return {
    data: undefined,
    isLoading: false,
    isFetching: false,
    isError: false,
    error: null,
    dataUpdatedAt: 1,
    refetch: vi.fn(),
    ...overrides,
  }
}

const ALL_OK = {
  ready: true,
  parts: [
    { part: 'database', ok: true },
    { part: 'migrations', ok: true },
    { part: 'secrets_key', ok: true },
    { part: 'identity', ok: true },
  ],
}

/** One `useQuery` mock answering per query key: health (liveness), readiness, backup status. */
function mockQueries(opts: { live?: boolean; readiness?: unknown; backup?: unknown }) {
  mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
  mockUseQuery.mockImplementation(((o: { queryKey: string[] }) => {
    const key = o.queryKey[1]
    if (key === 'health') return queryResult({ data: opts.live ?? true })
    if (key === 'readiness') return queryResult(opts.readiness === undefined ? { data: ALL_OK } : (opts.readiness as Record<string, unknown>))
    return queryResult(opts.backup === undefined ? { data: { configured: false, jobs: [] } } : (opts.backup as Record<string, unknown>))
  }) as unknown as typeof useQuery)
}

describe('HealthDashboardPage', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('TC-ISS0532-11: redirects non-platform-admin users away, without calling the health query', () => {
    mockUseAuth.mockReturnValue({ session: NON_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: true }) as unknown as ReturnType<typeof useQuery>)

    renderWithAccess(<HealthDashboardPage />, 'operator')

    expect(screen.getByTestId('navigate')).toHaveAttribute('data-to', '/instances')
  })

  it('W1-1: shows one row per readiness part, all OK, and a ready summary', () => {
    mockQueries({})
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    for (const part of ['database', 'migrations', 'secrets_key', 'identity']) {
      expect(screen.getByTestId(`readiness-${part}`)).toHaveAttribute('data-ok', 'true')
    }
    expect(screen.getByTestId('readiness-summary')).toHaveTextContent('Every part is ready.')
  })

  it('W1-2: names the failing part and says what to do', () => {
    mockQueries({
      readiness: {
        data: {
          ready: false,
          parts: ALL_OK.parts.map((p) => (p.part === 'identity' ? { ...p, ok: false } : p)),
        },
      },
    })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('readiness-identity')).toHaveAttribute('data-ok', 'false')
    expect(screen.getByTestId('readiness-identity')).toHaveTextContent('Keycloak')
    expect(screen.getByTestId('readiness-database')).toHaveAttribute('data-ok', 'true')
    expect(screen.getByTestId('readiness-summary')).toHaveTextContent('Not ready: Identity provider.')
  })

  it('W1-3: a readiness load error shows its own message and keeps the rest of the page', () => {
    mockQueries({ readiness: { isError: true, error: new Error('x') } })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('readiness-error')).toBeInTheDocument()
    expect(screen.getByTestId('liveness-badge')).toHaveTextContent('LIVE')
  })

  it('W1-4: backup not configured says so', () => {
    mockQueries({})
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('backup-not-configured')).toHaveTextContent('not configured')
    expect(screen.queryByTestId('backup-dump')).not.toBeInTheDocument()
  })

  it('W1-5: backup lines show state per job; stale or failed adds the action sentence', () => {
    mockQueries({
      backup: {
        data: {
          configured: true,
          jobs: [
            { job: 'dump', state: 'stale', ts: '2026-11-08T01:45:00Z', age_seconds: 200000 },
            { job: 'base', state: 'ok', ts: '2026-11-09T01:45:00Z', age_seconds: 1000 },
            { job: 'prune', state: 'missing', ts: null, age_seconds: null },
            { job: 'restore_test', state: 'failed', ts: '2026-11-09T03:30:00Z', age_seconds: 1000 },
          ],
        },
      },
    })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('backup-dump')).toHaveAttribute('data-state', 'stale')
    expect(screen.getByTestId('backup-dump')).toHaveTextContent('Too old')
    expect(screen.getByTestId('backup-base')).toHaveAttribute('data-state', 'ok')
    expect(screen.getByTestId('backup-prune')).toHaveTextContent('No report')
    expect(screen.getByTestId('backup-restore_test')).toHaveTextContent('Failed')
    expect(screen.getByTestId('backup-action')).toBeInTheDocument()
  })

  it('W1-6: a backup load error shows its own message', () => {
    mockQueries({ backup: { isError: true, error: new Error('403') } })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('backup-error')).toBeInTheDocument()
  })

  it('TC-ISS0532-14: shows LIVE when the real liveness check (GET /health) succeeds', () => {
    mockQueries({ live: true })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('liveness-badge')).toHaveTextContent('LIVE')
  })

  it('TC-ISS0532-15: shows UNREACHABLE when the real liveness check fails, without crashing', () => {
    mockQueries({ live: false })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')

    expect(screen.getByTestId('liveness-badge')).toHaveTextContent('UNREACHABLE')
    expect(screen.getByTestId('readiness-block')).toBeInTheDocument()
  })

  it('H1: LIVE and UNREACHABLE each show a plain sentence on what to do', () => {
    mockQueries({ live: true })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')
    expect(screen.getByTestId('liveness-action')).toHaveTextContent('If users still report problems, open Metrics.')
    cleanup()
    mockQueries({ live: false })
    renderWithAccess(<HealthDashboardPage />, 'platformAdmin')
    expect(screen.getByTestId('liveness-action')).toHaveTextContent('tell the platform operator')
  })
})
