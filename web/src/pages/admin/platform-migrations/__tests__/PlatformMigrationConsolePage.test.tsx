// @vitest-environment jsdom
/**
 * Unit tests — REQ-375: PlatformMigrationConsolePage (rollout-status screen)
 *
 * See lib/letflow/design/req375-rollout-status-screen.md and
 * docs/requirements.yaml's REQ-375 acceptance_criteria. Mocks
 * `@/hooks/usePlatformMigrations` and `@tanstack/react-query`'s `useQuery`
 * directly (matching `PlatformDashboardPage.test.tsx`'s established
 * convention for this exact page family — mock the hook boundary, not the
 * HTTP client underneath it), and `@/auth/AuthContext`/`react-router-dom`.
 *
 * TC-REQ375-10: AC4 — non-platform-admin session redirects to /instances,
 *   never rendering the screen.
 * TC-REQ375-11: AC4 — platform-admin session renders the start form.
 * TC-REQ375-12/13: AC2 — hasOutstandingCompanies visibility: the resume
 *   control is present when >=1 outcome is not 'succeeded', and ABSENT
 *   (not merely disabled) once every outcome is 'succeeded'.
 * TC-REQ375-14: AC2 — invoking the resume control calls the real
 *   useResumeRollout().mutate with the active rollout id (no mock data path).
 * TC-REQ375-15: AC3 — a fresh-run response (not every outcome
 *   already_current) renders rollout-fresh-run-banner and NOT
 *   rollout-noop-banner.
 * TC-REQ375-16: AC3 — a no-op re-run response (every outcome
 *   already_current: true) renders rollout-noop-banner distinctly, and NOT
 *   rollout-fresh-run-banner — this is isNoOpResult's own scoping: it must
 *   fire on the START mutation response.
 * TC-REQ375-17: AC1/EO-003 — RolloutOutcomeTable renders one row per company
 *   with outcome, completion time, and reason for non-succeeded companies
 *   only (a succeeded row renders no reason text).
 * TC-REQ375-18: isNoOpResult is scoped to the START mutation's response only
 *   — a resume response (lastAction 'resume') never triggers the noop
 *   banner, even if the resume response happens to also show every outcome
 *   already_current (a resume response's own outcomes always report
 *   already_current: false per the design's §5 nuance, but this test proves
 *   the SCREEN's own gating, not just the backend's promise).
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { RolloutResult } from '@/api/platformMigrations'
expect.extend(jestDomMatchers)

const mockStartMutate = vi.fn()
const mockResumeMutate = vi.fn()

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: { items: [], next_cursor: null, count: 0 }, isLoading: false, isError: false, error: null })),
}))

vi.mock('@/hooks/usePlatformMigrations', () => ({
  useStartRollout: vi.fn(() => ({ mutate: mockStartMutate, isPending: false })),
  useResumeRollout: vi.fn(() => ({ mutate: mockResumeMutate, isPending: false })),
  useRolloutStatus: vi.fn(() => ({ data: undefined, isLoading: false, isError: false, error: null, refetch: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('react-router-dom', () => ({
  Navigate: ({ to }: { to: string }) => <div data-testid="navigate" data-to={to} />,
  useSearchParams: () => [new URLSearchParams(), vi.fn()],
}))

import { useAuth } from '@/auth/AuthContext'
import PlatformMigrationConsolePage from '@/pages/admin/platform-migrations/PlatformMigrationConsolePage'
import { renderWithAccess } from '@/auth/access/testing'

const mockUseAuth = vi.mocked(useAuth)

const ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  loginSource: null as null,
  tenant_slug: null,
  tenant_display_name: null,
  tenant_id: null,
  tenant_type: null,
}

const NON_ADMIN_SESSION = { ...ADMIN_SESSION }

function outcome(overrides: Partial<RolloutResult['outcomes'][number]>): RolloutResult['outcomes'][number] {
  return {
    tenant_id: 'tenant-a',
    status: 'succeeded',
    completed_at: '2026-09-21T10:00:00Z',
    reason: null,
    already_current: false,
    ...overrides,
  }
}

function rolloutResult(overrides: {
  outcomes: RolloutResult['outcomes']
  rolloutOverrides?: Partial<RolloutResult['rollout']>
}): RolloutResult {
  return {
    rollout: {
      id: 'rollout-1',
      entity_type: 'invoice',
      attribute: 'tax_id',
      status: 'running',
      started_at: '2026-09-21T09:00:00Z',
      completed_at: null,
      ...overrides.rolloutOverrides,
    },
    outcomes: overrides.outcomes,
  }
}

function fillMinimalStartForm() {
  fireEvent.change(screen.getByTestId('rollout-entity-type-input'), { target: { value: 'invoice' } })
  fireEvent.change(screen.getByTestId('rollout-attribute-input'), { target: { value: 'tax_id' } })
  fireEvent.change(screen.getByTestId('rollout-pg-type-input'), { target: { value: 'text' } })
}

function startAndResolve(result: RolloutResult) {
  mockStartMutate.mockImplementationOnce((_body, opts: { onSuccess: (data: RolloutResult) => void }) => {
    opts.onSuccess(result)
  })
  fillMinimalStartForm()
  fireEvent.click(screen.getByTestId('rollout-start-btn'))
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-375 — PlatformMigrationConsolePage — route guard (AC4)', () => {
  it('TC-REQ375-10: a non-platform-admin session redirects to /instances and never renders the screen', () => {
    mockUseAuth.mockReturnValue({ session: NON_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)

    renderWithAccess(<PlatformMigrationConsolePage />, 'operator')

    expect(screen.getByTestId('navigate')).toHaveAttribute('data-to', '/instances')
    expect(screen.queryByTestId('rollout-start-btn')).not.toBeInTheDocument()
  })

  it('TC-REQ375-11: a platform-admin session renders the start form', () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)

    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    expect(screen.getByTestId('rollout-start-btn')).toBeInTheDocument()
    expect(screen.queryByTestId('navigate')).not.toBeInTheDocument()
  })
})

describe('REQ-375 — resume-control visibility, hasOutstandingCompanies (AC2)', () => {
  it('TC-REQ375-12: at least one outstanding (non-succeeded) company shows the resume control', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        outcomes: [
          outcome({ tenant_id: 'good', status: 'succeeded' }),
          outcome({ tenant_id: 'poisoned', status: 'failed', completed_at: null, reason: 'column type conflict: existing bigint, requested text' }),
        ],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-resume-btn')).toBeInTheDocument())
  })

  it('TC-REQ375-13: zero outstanding companies (every outcome succeeded) HIDES the resume control entirely (absent, not disabled)', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        outcomes: [
          outcome({ tenant_id: 'good-a', status: 'succeeded' }),
          outcome({ tenant_id: 'good-b', status: 'succeeded' }),
        ],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-outcome-table')).toBeInTheDocument())
    expect(screen.queryByTestId('rollout-resume-btn')).not.toBeInTheDocument()
  })

  it('TC-REQ375-14: invoking the resume control calls useResumeRollout().mutate with the active rollout id', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        rolloutOverrides: { id: 'rollout-xyz' },
        outcomes: [outcome({ tenant_id: 'poisoned', status: 'failed', completed_at: null, reason: 'boom' })],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-resume-btn')).toBeInTheDocument())

    mockResumeMutate.mockImplementationOnce((_id, opts: { onSuccess: (data: RolloutResult) => void }) => {
      opts.onSuccess(
        rolloutResult({
          rolloutOverrides: { id: 'rollout-xyz', status: 'completed', completed_at: '2026-09-21T11:00:00Z' },
          outcomes: [outcome({ tenant_id: 'poisoned', status: 'succeeded', completed_at: '2026-09-21T11:00:00Z' })],
        }),
      )
    })
    fireEvent.click(screen.getByTestId('rollout-resume-btn'))

    expect(mockResumeMutate).toHaveBeenCalledWith('rollout-xyz', expect.anything())
    // The resume result is real (not a mock backend) — the screen re-renders
    // from the mutation's own response and the resume control disappears
    // once every outcome is succeeded.
    await waitFor(() => expect(screen.queryByTestId('rollout-resume-btn')).not.toBeInTheDocument())
  })
})

describe('REQ-375 — no-op re-run distinguishability, isNoOpResult (AC3)', () => {
  it('TC-REQ375-15: a fresh run (not every outcome already_current) renders the fresh-run banner, not the no-op banner', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        outcomes: [
          outcome({ tenant_id: 'a', status: 'succeeded', already_current: false }),
          outcome({ tenant_id: 'b', status: 'succeeded', already_current: false }),
        ],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-fresh-run-banner')).toBeInTheDocument())
    expect(screen.queryByTestId('rollout-noop-banner')).not.toBeInTheDocument()
  })

  it('TC-REQ375-16: a no-op re-run (every outcome already_current: true) renders the no-op banner INSTEAD of the fresh-run banner', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        outcomes: [
          outcome({ tenant_id: 'a', status: 'succeeded', already_current: true }),
          outcome({ tenant_id: 'b', status: 'succeeded', already_current: true }),
        ],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-noop-banner')).toBeInTheDocument())
    expect(screen.queryByTestId('rollout-fresh-run-banner')).not.toBeInTheDocument()
  })

  it('TC-REQ375-18: isNoOpResult is scoped to the START mutation response only — a resume response never triggers the no-op banner', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    // First: a normal fresh start with an outstanding company.
    startAndResolve(
      rolloutResult({
        rolloutOverrides: { id: 'rollout-r' },
        outcomes: [outcome({ tenant_id: 'poisoned', status: 'failed', completed_at: null, reason: 'boom', already_current: false })],
      }),
    )
    await waitFor(() => expect(screen.getByTestId('rollout-fresh-run-banner')).toBeInTheDocument())

    // Resume — even though this resume response reports every outcome as
    // already_current: true (an artificial/adversarial case chosen here
    // specifically to prove the SCREEN never runs isNoOpResult against a
    // resume response, regardless of what the response contains), the
    // no-op banner must NOT appear: lastAction is 'resume', not 'start'.
    mockResumeMutate.mockImplementationOnce((_id, opts: { onSuccess: (data: RolloutResult) => void }) => {
      opts.onSuccess(
        rolloutResult({
          rolloutOverrides: { id: 'rollout-r', status: 'completed', completed_at: '2026-09-21T11:00:00Z' },
          outcomes: [outcome({ tenant_id: 'poisoned', status: 'succeeded', completed_at: '2026-09-21T11:00:00Z', already_current: true })],
        }),
      )
    })
    fireEvent.click(screen.getByTestId('rollout-resume-btn'))

    await waitFor(() => expect(screen.queryByTestId('rollout-resume-btn')).not.toBeInTheDocument())
    expect(screen.queryByTestId('rollout-noop-banner')).not.toBeInTheDocument()
    expect(screen.queryByTestId('rollout-fresh-run-banner')).not.toBeInTheDocument()
  })
})

describe('REQ-375 — RolloutOutcomeTable / Row field mapping (AC1/EO-003)', () => {
  it('TC-REQ375-17: renders one row per company with outcome, completion time, and reason for non-succeeded companies only', async () => {
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        outcomes: [
          outcome({ tenant_id: 'good-co', status: 'succeeded', completed_at: '2026-09-21T10:05:00Z', reason: null }),
          // REQ-374's record_outcome_result/2 sets completed_at the instant
          // status leaves 'pending' -- for BOTH succeeded and failed
          // (migration_rollout_test.exs asserts a non-nil completed_at for
          // every outcome, poisoned one included). A failed outcome's
          // completed_at is therefore a real timestamp here, not null --
          // matching UAT-RUNNER's live-run finding (WF02-REQ375-e2e-live-
          // 20260922): the component correctly rendered the real timestamp
          // for a failed row; it was this test's own fixture/assertion that
          // baked in the wrong assumption (null implies "only while
          // pending", silently conflated with "only on success").
          outcome({ tenant_id: 'poisoned-co', status: 'failed', completed_at: '2026-09-21T10:06:00Z', reason: 'column type conflict: existing bigint, requested text' }),
        ],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-outcome-table')).toBeInTheDocument())

    expect(screen.getByTestId('rollout-outcome-row-good-co')).toBeInTheDocument()
    expect(screen.getByTestId('rollout-outcome-row-poisoned-co')).toBeInTheDocument()

    // Succeeded row: no reason text rendered.
    expect(screen.getByTestId('rollout-outcome-reason-good-co')).toHaveTextContent('')
    expect(screen.getByTestId('rollout-outcome-completed-good-co')).not.toHaveTextContent('—')

    // Non-succeeded (failed) row: reason IS rendered, AND completed-at
    // renders the real timestamp -- NOT the em-dash placeholder. The
    // em-dash is reserved for a genuinely null completed_at, which only
    // occurs while status === 'pending' (never for 'failed').
    expect(screen.getByTestId('rollout-outcome-reason-poisoned-co')).toHaveTextContent('column type conflict: existing bigint, requested text')
    expect(screen.getByTestId('rollout-outcome-completed-poisoned-co')).not.toHaveTextContent('—')

    // Status badges use the rollout-outcome domain (TC-REQ375-03/04 in
    // StatusBadge.test.tsx cover the domain's own token resolution).
    expect(screen.getByTestId('rollout-outcome-status-good-co').querySelector('[data-testid="status-badge"]'))
      .toHaveAttribute('data-status', 'succeeded')
    expect(screen.getByTestId('rollout-outcome-status-poisoned-co').querySelector('[data-testid="status-badge"]'))
      .toHaveAttribute('data-status', 'failed')
  })

  it('TC-REQ375-19: a genuinely pending outcome (completed_at actually null) is the only case rendering the em-dash placeholder', async () => {
    // Regression test for UAT-RUNNER's live-run finding
    // (WF02-REQ375-e2e-live-20260922, "new_finding_2"): REQ-374's
    // record_outcome_result/2 sets completed_at the instant status leaves
    // 'pending', for BOTH 'succeeded' and 'failed' -- so the em-dash must be
    // reserved for the genuinely-still-pending case only, never inferred
    // from status !== 'succeeded'.
    mockUseAuth.mockReturnValue({ session: ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    renderWithAccess(<PlatformMigrationConsolePage />, 'platformAdmin')

    startAndResolve(
      rolloutResult({
        outcomes: [
          outcome({ tenant_id: 'still-pending', status: 'pending', completed_at: null, reason: null }),
        ],
      }),
    )

    await waitFor(() => expect(screen.getByTestId('rollout-outcome-table')).toBeInTheDocument())
    expect(screen.getByTestId('rollout-outcome-completed-still-pending')).toHaveTextContent('—')
  })
})
