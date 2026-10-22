// @vitest-environment jsdom
/**
 * GH 2238 / REQ-450 BUILDS item 5: the definition editor opened by direct URL without
 * DefinitionsWrite (auditor /me/access fixture) renders read-only.
 *
 * Heavy child components are mocked to null; only the toolbar and metadata controls are checked.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)

// ── Mock heavy dependencies before importing the component ────────────────────

vi.mock('@xyflow/react', () => ({
  ReactFlowProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

vi.mock('@/components/canvas/ProcessCanvas', () => ({ default: () => null }))
vi.mock('@/components/canvas/NodePalette', () => ({ default: () => null }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => null }))
vi.mock('@/components/canvas/ValidationSummaryBar', () => ({ default: () => null }))

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

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  // REQ-431 — DefinitionEditorPage now also calls these; this suite doesn't
  // exercise save/release, so bare no-op stubs are sufficient.
  useValidateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useActivateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
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
    update: vi.fn(),
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
import { renderWithAccess } from '@/auth/access/testing'

const mockUseParams = vi.mocked(useParams)
const mockUseDefinition = vi.mocked(useDefinition)
const mockUseAuth = vi.mocked(useAuth)
const mockUseTenantContext = vi.mocked(useTenantContext)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const ACTIVE_DEFINITION = {
  id: 'def-123',
  name: 'Onboarding Flow',
  version: '1.0.0',
  description: null,
  status: 'ACTIVE' as const,
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

const AUTH_VALUE_BASE = {
  isAuthenticated: true,
  isLoading: false,
  loginSource: null as null,
  login: vi.fn(),
  logout: vi.fn(),
  setSession: vi.fn(),
  switchTenant: vi.fn(),
  switchingToTenantSlug: null,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const AUTH = { ...AUTH_VALUE_BASE, session: DESIGNER_SESSION }
const TENANT = {
  tenantType: 'test' as const,
  tenantSlug: 'acme-test',
  tenantId: 'tid-001',
  tenantDisplayName: 'Acme Test',
  isUnknown: false,
}
const MUTATING_TESTIDS = [
  'btn-save-definition',
  'btn-submit-for-release',
  'promote-to-production-btn',
  'btn-export-definition',
  'btn-auto-layout',
]

function arrange(id: string | undefined, status: 'DRAFT' | 'ACTIVE' | null) {
  mockUseParams.mockReturnValue(id ? { id } : {})
  mockUseDefinition.mockReturnValue({
    data: status ? { ...ACTIVE_DEFINITION, status } : undefined,
    isLoading: false,
  } as unknown as ReturnType<typeof useDefinition>)
  mockUseAuth.mockReturnValue(AUTH)
  mockUseTenantContext.mockReturnValue(TENANT)
}

describe('GH 2238 — DefinitionEditorPage without DefinitionsWrite', () => {
  it.each([
    ['existing DRAFT definition', 'def-123', 'DRAFT'],
    ['existing ACTIVE definition', 'def-123', 'ACTIVE'],
    ['new definition', undefined, null],
  ] as const)('TC-2238-01: auditor sees no mutating control on a %s', (_label, id, status) => {
    arrange(id, status)
    renderWithAccess(<DefinitionEditorPage />, 'auditor')

    for (const testId of MUTATING_TESTIDS) {
      expect(screen.queryByTestId(testId)).not.toBeInTheDocument()
    }
    expect(screen.getByTestId('read-only-banner')).toBeInTheDocument()
    for (const input of screen.queryAllByRole('textbox')) {
      expect(input).toHaveAttribute('readonly')
    }
  })

  it('TC-2238-02: a designer still gets save and submit-for-release on a DRAFT definition', () => {
    arrange('def-123', 'DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')

    expect(screen.getByTestId('btn-save-definition')).toBeInTheDocument()
    expect(screen.getByTestId('btn-submit-for-release')).toBeInTheDocument()
    expect(screen.queryByTestId('read-only-banner')).not.toBeInTheDocument()
  })
})
