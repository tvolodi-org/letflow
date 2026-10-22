// @vitest-environment jsdom
/**
 * Unit test — REQ-431 AC5: the release-submission re-check surface must show
 * the FRESH result of an `activate` call distinctly from a STALE, already-clean
 * save-time `validate` result, never conflating the two.
 *
 * Per lib/letflow/design/req431-definition-validation-canvas-presentation.md
 * §7.2: this exact "stub a clean save-time validate response followed by an
 * activate call that returns {:error, {:semantic_validation_failed, [...]}}"
 * scenario structurally cannot be produced against a real backend (a graph
 * that passes save-time validate would also pass activate's own semantic
 * check, since both call the same SemanticValidation.validate/2 over the same
 * stored graph) -- it belongs here, as a stub-based component test, not in the
 * real-backend e2e pipeline spec.
 *
 * Heavy child components are mocked, mirroring
 * DefinitionEditorPage.promote.test.tsx's established convention. The
 * ProcessCanvas mock additionally populates `canvasStateRef.current` with a
 * minimal valid graph (as the real component would after loading a
 * definition) so `handleSave`'s "Canvas not ready" early-return never fires.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useEffect } from 'react'
expect.extend(jestDomMatchers)

// ── Mock heavy dependencies before importing the component ────────────────────

vi.mock('@xyflow/react', () => ({
  ReactFlowProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

function MockProcessCanvas({
  canvasStateRef,
}: {
  canvasStateRef: React.MutableRefObject<{ nodesJSON: string; edgesJSON: string } | null>
}) {
  useEffect(() => {
    canvasStateRef.current = {
      nodesJSON: JSON.stringify([
        { id: 'start', position: { x: 0, y: 0 }, data: { nodeType: 'START', name: 'Start', attributes: {} } },
        { id: 'end', position: { x: 0, y: 100 }, data: { nodeType: 'END', name: 'End', attributes: {} } },
      ]),
      edgesJSON: JSON.stringify([
        { id: 'e1', source: 'start', target: 'end', data: {} },
      ]),
    }
  }, [canvasStateRef])
  return null
}

vi.mock('@/components/canvas/ProcessCanvas', () => ({
  default: MockProcessCanvas,
}))
vi.mock('@/components/canvas/NodePalette', () => ({ default: () => null }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => null }))

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useParams: vi.fn(),
    useBlocker: vi.fn(() => ({ state: 'unblocked' as const })),
  }
})

vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return {
    ...(actual as object),
    useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
  }
})

const mockValidateMutateAsync = vi.fn()
const mockActivateMutateAsync = vi.fn()

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useValidateDefinition: vi.fn(() => ({ mutateAsync: mockValidateMutateAsync, isPending: false })),
  useActivateDefinition: vi.fn(() => ({ mutateAsync: mockActivateMutateAsync, isPending: false })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/auth/useTenantContext', () => ({
  useTenantContext: vi.fn(),
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    promote: vi.fn(),
    exportJson: vi.fn(),
    update: vi.fn().mockResolvedValue({}),
  },
}))

vi.mock('@/stores/canvasHistoryStore', () => ({
  useCanvasHistoryStore: Object.assign(vi.fn(() => undefined), {
    getState: vi.fn(() => ({ clear: vi.fn() })),
  }),
}))

// ── Imports after mocks ───────────────────────────────────────────────────────

import { useParams } from 'react-router-dom'
import { useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'

const mockUseParams = vi.mocked(useParams)
const mockUseDefinition = vi.mocked(useDefinition)
const mockUseAuth = vi.mocked(useAuth)
const mockUseTenantContext = vi.mocked(useTenantContext)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const DRAFT_DEFINITION = {
  id: 'def-431',
  name: 'Two-Rule Decision',
  version: '1.0.0',
  description: null,
  status: 'DRAFT' as const,
  graph: {
    nodes: [
      { id: 'start', node_type: 'START', label: null, attributes: null },
      { id: 'end', node_type: 'END', label: null, attributes: null },
    ],
    edges: [{ id: 'e1', source: 'start', target: 'end' }],
  },
}

const DESIGNER_SESSION = {
  token: 'tok',
  display_name: 'Alice',
  loginSource: null as null,
  tenant_slug: 'acme-test',
  tenant_display_name: 'Acme Test',
  tenant_id: 'tid-001',
  tenant_type: 'test' as const,
}

const AUTH_VALUE = {
  isAuthenticated: true,
  isLoading: false,
  loginSource: null as null,
  login: vi.fn(),
  logout: vi.fn(),
  setSession: vi.fn(),
  switchTenant: vi.fn(),
  switchingToTenantSlug: null,
  session: DESIGNER_SESSION,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-431 AC5 — ReleaseCheckPanel shows the FRESH release-time result, distinct from a stale clean save', () => {
  it('a clean save-time validate followed by a failing activate shows "blocked" on the release panel while the save-time bar stays clean', async () => {
    const user = userEvent.setup()

    mockUseParams.mockReturnValue({ id: 'def-431' })
    mockUseDefinition.mockReturnValue({
      data: DRAFT_DEFINITION,
      isLoading: false,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useDefinition>)
    mockUseAuth.mockReturnValue(AUTH_VALUE)
    mockUseTenantContext.mockReturnValue({
      tenantType: 'test',
      tenantSlug: 'acme-test',
      tenantId: 'tid-001',
      tenantDisplayName: 'Acme Test',
      isUnknown: false,
    })

    // Save-time validate resolves CLEAN.
    mockValidateMutateAsync.mockResolvedValue({
      status: 'valid',
      definition_id: 'def-431',
      findings: [],
      validated_at: '2026-09-30T00:00:00Z',
    })

    render(<DefinitionEditorPage />)

    // No release-check panel shown before any submission attempt.
    expect(screen.queryByTestId('release-check-panel')).not.toBeInTheDocument()

    // Save — triggers handleSave's post-save validate call (clean).
    await user.click(screen.getByTestId('btn-save-definition'))
    await waitFor(() => expect(mockValidateMutateAsync).toHaveBeenCalledWith('def-431'))

    // Save-time bar shows no problems (clean).
    expect(screen.queryByText(/error/i)).not.toBeInTheDocument()

    // THIS activate call returns a FRESH failure — a violation that was not
    // present (or not checked) at the earlier clean save-time validate call.
    mockActivateMutateAsync.mockRejectedValue({
      status: 422,
      message: 'definition graph failed semantic validation',
      details: [
        {
          code: 'incompatible_comparison_operand_types',
          message:
            "Edge 'e2' (from EXCLUSIVE_GATEWAY node 'gw') condition compares incompatible types: 'amount' (numeric) == 'customer_name' (string); rule as authored: \"amount == customer_name\"",
        },
      ],
    })

    await user.click(screen.getByTestId('btn-submit-for-release'))

    // The release panel shows the FRESH failing result...
    const panel = await screen.findByTestId('release-check-panel')
    expect(panel).toHaveAttribute('data-release-check-phase', 'blocked')
    expect(panel).toHaveTextContent('Release blocked')
    expect(panel).toHaveTextContent('compares incompatible types')

    // ...while the save-time validation state (serverValidationErrors) is
    // STILL clean from the earlier save -- these are two independently-set
    // state slots, never merged, so the old clean result is never silently
    // overwritten or reused to mask the new failure.
    expect(mockActivateMutateAsync).toHaveBeenCalledWith('def-431')
    expect(mockValidateMutateAsync).toHaveBeenCalledTimes(1)
  })
})
