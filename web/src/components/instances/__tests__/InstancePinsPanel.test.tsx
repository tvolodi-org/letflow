// @vitest-environment jsdom
/**
 * Component-level coverage for InstancePinsPanel (REQ-399 AC4/AC5/AC6).
 * Backend AC1/AC2/AC3/AC7 are covered elsewhere (test/letflow/routers/
 * instances_test.exs, feca389b's AC2 telemetry test) — this file covers only
 * the frontend-side acceptance criteria against the new panel.
 *
 * Mocks `@/api/instances` directly (same pattern as AttachmentPanel.test.tsx
 * — the design doc's own closer precedent, §4.1/§7), letting the real
 * `useInstancePins` hook and real `useQuery`/`QueryStateBoundary`/
 * `classifyError` wiring run unmocked, so these tests exercise the actual
 * loading -> success/empty -> fetch-failure state machine, not a stubbed
 * rendererState.
 *
 * AC-to-test map (docs/requirements.yaml REQ-399):
 *   AC4 -> 'renders all four source values ... each in its own row'
 *   AC5 -> 'zero recorded pins renders a distinct "no dependencies" state'
 *        + 'the empty state is not the loading state'
 *        + 'the empty state is not the fetch-failure state'
 *   AC6 -> 'a fetch failure renders the existing FetchError/retry state'
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { EffectivePin, InstancePinsResponse } from '@/types/api'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-pins-1'

const getPins = vi.fn()

vi.mock('@/api/instances', () => ({
  instancesApi: {
    getPins: (...args: unknown[]) => getPins(...args),
  },
}))

// Synthetic, clearly-fake tenant id -- not a real platform tenant (matches
// PromotionReviewListPage.test.tsx's FIXTURE_TENANT_SLUG convention); this
// panel/hook doesn't render the tenant slug, but useTenantScopedQueryKeys
// requires a session to build its query keys.
const FIXTURE_TENANT_ID = 'tid-instance-pins-fixture-tenant'

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 't',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: FIXTURE_TENANT_ID,
        tenant_type: null,
        production_tenant_display_name: null,
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

import { InstancePinsPanel } from '@/components/instances/InstancePinsPanel'

function renderPanel() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <InstancePinsPanel instanceId={INSTANCE_ID} />
    </QueryClientProvider>,
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

// ── Fixtures ────────────────────────────────────────────────────────────────

function pin(overrides: Partial<EffectivePin>): EffectivePin {
  return {
    kind: 'catalog_entry',
    ref: 'ref-default',
    resolved_id: 'resolved-default',
    version: '1.0.0',
    source: 'resolved',
    ...overrides,
  }
}

const RESOLVED_PIN = pin({ ref: 'svc-billing', version: '1.0.0', source: 'resolved' })
const OVERRIDE_PIN = pin({ ref: 'svc-shipping', version: '2.3.1', source: 'override' })
const INHERITED_PIN = pin({ ref: 'svc-tax', version: '0.9.0', source: 'inherited' })
const REBOUND_PIN = pin({ ref: 'svc-fraud', version: '4.1.0', source: 'rebound' })

const ALL_FOUR_SOURCES_RESPONSE: InstancePinsResponse = {
  instance_id: INSTANCE_ID,
  pins: [RESOLVED_PIN, OVERRIDE_PIN, INHERITED_PIN, REBOUND_PIN],
}

// The exact source->label map InstancePinsPanel.tsx's SOURCE_LABELS declares
// (design doc §4.2). Kept here, independent of the component's own map, so
// a mutation that scrambles the component's labels is actually caught (see
// the fail-then-pass mutation below) rather than the test importing and
// re-checking the same broken map.
const EXPECTED_LABEL_BY_REF: Record<string, string> = {
  'svc-billing': 'Chosen automatically',
  'svc-shipping': 'Requested explicitly',
  'svc-tax': 'Inherited from parent case',
  'svc-fraud': 'Changed via rebind',
}

// ── AC4: all four source values, each with its own distinct label ──────────

describe('REQ-399 AC4 — renders all four PinResolver source values with distinct labels', () => {
  it('renders all four source values, each in its own row, matched to that row\'s dependency', async () => {
    getPins.mockResolvedValue(ALL_FOUR_SOURCES_RESPONSE)

    renderPanel()

    await waitFor(() => {
      expect(screen.getByTestId('data-table')).toBeInTheDocument()
    })

    const rows = screen.getAllByRole('row')
    // First row is the header; one row per pin follows.
    const bodyRows = rows.slice(1)
    expect(bodyRows).toHaveLength(4)

    // Assert each row's own `ref` cell is paired with that row's own
    // `source` label cell -- not merely that all four label strings appear
    // somewhere on the page (which would pass even if labels were
    // shuffled across rows).
    for (const [ref, expectedLabel] of Object.entries(EXPECTED_LABEL_BY_REF)) {
      const row = bodyRows.find((r) => within(r).queryByText(ref) !== null)
      expect(row, `expected a row for ref "${ref}"`).toBeDefined()
      expect(within(row!).getByText(expectedLabel)).toBeInTheDocument()
    }

    // And every label is distinct from every other -- no two source values
    // collapsed onto the same text.
    const labels = Object.values(EXPECTED_LABEL_BY_REF)
    expect(new Set(labels).size).toBe(labels.length)
  })
})

// ── AC5: zero-pins empty state, distinct from loading and fetch-failure ────

describe('REQ-399 AC5 — zero recorded pins renders a distinct "no dependencies" state', () => {
  it('renders a plain "no dependencies" message when the response has zero pins', async () => {
    getPins.mockResolvedValue({ instance_id: INSTANCE_ID, pins: [] })

    renderPanel()

    await waitFor(() => {
      expect(screen.getByText('No dependencies recorded for this case.')).toBeInTheDocument()
    })

    // Not the table (no rows to show), not a retry/error affordance.
    expect(screen.queryByTestId('data-table')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Retry' })).not.toBeInTheDocument()
  })

  it('the empty state is not the loading state', () => {
    getPins.mockReturnValue(new Promise(() => {})) // never resolves -- stays loading

    renderPanel()

    // While loading: no empty message yet, and the loading skeleton is shown.
    expect(screen.queryByText('No dependencies recorded for this case.')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Loading content')).toBeInTheDocument()
  })

  it('the empty state is not the fetch-failure state', async () => {
    getPins.mockRejectedValue(new Error('boom'))

    renderPanel()

    await waitFor(() => {
      expect(screen.getByRole('alert')).toBeInTheDocument()
    })

    // Fetch failure must never render the empty-dependencies message.
    expect(screen.queryByText('No dependencies recorded for this case.')).not.toBeInTheDocument()
  })
})

// ── AC6: fetch failure renders the existing QueryStateBoundary/FetchError state ─

describe('REQ-399 AC6 — fetch failure renders the existing failure state', () => {
  it('renders the FetchError retry UI on a fetch failure, not the table or empty state', async () => {
    getPins.mockRejectedValue(new Error('network down'))

    renderPanel()

    await waitFor(() => {
      expect(screen.getByRole('alert')).toBeInTheDocument()
    })

    expect(screen.getByText('Something went wrong loading this content.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
    expect(screen.queryByTestId('data-table')).not.toBeInTheDocument()
    expect(screen.queryByText('No dependencies recorded for this case.')).not.toBeInTheDocument()
  })
})
