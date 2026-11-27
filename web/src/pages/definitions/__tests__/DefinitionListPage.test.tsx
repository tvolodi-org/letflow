// @vitest-environment jsdom
/**
 * Unit tests — REQ-371 AC1: rollback/withdraw action reachable from
 * DefinitionListPage.tsx, gated to platform-admin + ACTIVE-status rows only.
 *
 * See lib/letflow/design/req371-rollback-withdrawal-screen.md §6 and
 * DefinitionListPage.tsx:211 — the exact gating condition under test is
 * `def.status === 'ACTIVE' && isPlatformAdmin`, read directly from the
 * component (not assumed). Mocks `@/hooks/useDefinitions` directly, matching
 * `DefinitionRollbackPage.test.tsx` / `DefinitionEditorPage.promote.test.tsx`'s
 * established convention of mocking the hooks module rather than the
 * underlying API client, plus `@/auth/AuthContext` and `react-router-dom`'s
 * `useNavigate`.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
expect.extend(jestDomMatchers)

// ── Mocks ────────────────────────────────────────────────────────────────────

const mockNavigate = vi.fn()

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: vi.fn(() => mockNavigate),
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
  useDefinitions: vi.fn(),
  useDefinitionVersions: vi.fn(() => ({ data: undefined, isLoading: false })),
  useActivateDefinition: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useArchiveDefinition: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useDefinitionSearch: vi.fn(() => ({ data: undefined, isLoading: false, isFetching: false })),
  definitionKeys: { all: ['definitions'], list: () => ['definitions', 'list'] },
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    importJson: vi.fn(),
  },
}))

import { useAuth } from '@/auth/AuthContext'
import { useDefinitions, useCreateDefinition, useDefinitionSearch } from '@/hooks/useDefinitions'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import { renderWithAccess } from '@/auth/access/testing'

const ACTIVE_DEF = {
  id: 'def-active-1',
  name: 'approvals',
  version: '2.0.0',
  status: 'ACTIVE' as const,
  description: '',
  graph: { nodes: [], edges: [] },
  created_by: 'admin-user',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
}

const DRAFT_DEF = { ...ACTIVE_DEF, id: 'def-draft-1', status: 'DRAFT' as const }

function mockAuth() {
  vi.mocked(useAuth).mockReturnValue({
    session: {
      token: 't',
      display_name: 'op-1',
      loginSource: null,
      tenant_slug: null,
      tenant_display_name: null,
      tenant_id: null,
      tenant_type: null,
    },
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  } as unknown as ReturnType<typeof useAuth>)
}

function mockDefinitions(items: Array<typeof ACTIVE_DEF | typeof DRAFT_DEF>) {
  vi.mocked(useDefinitions).mockReturnValue({
    data: { items },
    isLoading: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
  } as unknown as ReturnType<typeof useDefinitions>)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('T-2012 process discovery', () => {
  it('opens a process from the list and explains editing', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])
    renderWithAccess(<DefinitionListPage />, 'platformAdmin')
    expect(screen.getByTestId('page-layout-title')).toHaveTextContent('Business processes')
    expect(screen.getByTestId('process-designer-hint')).toHaveTextContent('edit steps')
    fireEvent.click(screen.getByTestId(`open-process-${ACTIVE_DEF.id}`))
    expect(mockNavigate).toHaveBeenCalledWith(`/definitions/${ACTIVE_DEF.id}`)
  })
})

describe('T-2013 copy a process as a draft', () => {
  it('creates a DRAFT copy with the same graph and opens it', async () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])
    const mutateAsync = vi.fn().mockResolvedValue({ id: 'def-copy-1' })
    vi.mocked(useCreateDefinition).mockReturnValue({ mutateAsync, isPending: false } as unknown as ReturnType<typeof useCreateDefinition>)
    renderWithAccess(<DefinitionListPage />, 'platformAdmin')
    fireEvent.click(screen.getByTestId(`btn-copy-${ACTIVE_DEF.id}`))
    await vi.waitFor(() => expect(mockNavigate).toHaveBeenCalledWith('/definitions/def-copy-1'))
    expect(mutateAsync).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'approvals-copy', version: '1.0.0', graph: ACTIVE_DEF.graph, copy_variable_schemas_from: ACTIVE_DEF.id }),
    )
  })

  it('shows an error and does not navigate when the copy is refused', async () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])
    const mutateAsync = vi.fn().mockRejectedValue({ status: 409 })
    vi.mocked(useCreateDefinition).mockReturnValue({ mutateAsync, isPending: false } as unknown as ReturnType<typeof useCreateDefinition>)
    renderWithAccess(<DefinitionListPage />, 'platformAdmin')
    fireEvent.click(screen.getByTestId(`btn-copy-${ACTIVE_DEF.id}`))
    expect(await screen.findByTestId('copy-error')).toBeInTheDocument()
    expect(mockNavigate).not.toHaveBeenCalled()
  })
})

describe('DefinitionListPage — rollback button gating (REQ-371 AC1)', () => {
  it('TC-REQ371-07a: btn-rollback renders for an ACTIVE-status row when the session has platform-admin', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])

    renderWithAccess(<DefinitionListPage />, 'platformAdmin')

    expect(screen.getByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).toBeInTheDocument()
    expect(screen.getByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).toHaveTextContent('Rollback…')
  })

  it('TC-REQ371-07b: btn-rollback is absent for a non-ACTIVE row, even as platform-admin', () => {
    mockAuth()
    mockDefinitions([DRAFT_DEF])

    renderWithAccess(<DefinitionListPage />, 'platformAdmin')

    expect(screen.queryByTestId(`btn-rollback-${DRAFT_DEF.id}`)).not.toBeInTheDocument()
  })

  it('TC-REQ371-07c: btn-rollback is absent for a non-platform-admin session, even on an ACTIVE row', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])

    renderWithAccess(<DefinitionListPage />, 'designer')

    expect(screen.queryByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).not.toBeInTheDocument()
  })

  it('TC-REQ371-07d: clicking btn-rollback navigates to /definitions/:id/rollback', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])

    renderWithAccess(<DefinitionListPage />, 'platformAdmin')

    screen.getByTestId(`btn-rollback-${ACTIVE_DEF.id}`).click()

    expect(mockNavigate).toHaveBeenCalledWith(`/definitions/${ACTIVE_DEF.id}/rollback`)
  })
})

describe('DefinitionListPage — write controls follow DefinitionsWrite (GH 2238, BUILDS 5)', () => {
  it('an auditor sees the rows but no new, import, activate, archive or rollback control', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF, DRAFT_DEF])

    renderWithAccess(<DefinitionListPage />, 'auditor')

    expect(screen.getAllByText('approvals').length).toBeGreaterThan(0)
    expect(screen.queryByTestId('btn-new-definition')).not.toBeInTheDocument()
    expect(screen.queryByTestId('btn-import-definition')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Activate' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Archive' })).not.toBeInTheDocument()
    expect(screen.queryByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).not.toBeInTheDocument()
  })

  it('a designer sees new, import, activate and archive', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF, DRAFT_DEF])

    renderWithAccess(<DefinitionListPage />, 'designer')

    expect(screen.getByTestId('btn-new-definition')).toBeInTheDocument()
    expect(screen.getByTestId('btn-import-definition')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Activate' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Archive' })).toBeInTheDocument()
  })
})

describe('DefinitionListPage — friendly names (T-1511)', () => {
  const WRITEOFF = { ...ACTIVE_DEF, id: 'def-wo', name: 'assets_writeoff', version: '1.0.0' }

  it('D5: a catalog definition shows the label with the key as second line; an unknown name is unchanged', () => {
    mockAuth()
    mockDefinitions([WRITEOFF, ACTIVE_DEF])
    renderWithAccess(<DefinitionListPage />, 'platformAdmin')
    expect(screen.getByTestId('def-name-def-wo')).toHaveTextContent('Asset write-off')
    expect(screen.getByTestId('def-key-def-wo')).toHaveTextContent('assets_writeoff')
    expect(screen.getByTestId(`def-name-${ACTIVE_DEF.id}`)).toHaveTextContent('approvals')
    expect(screen.queryByTestId(`def-key-${ACTIVE_DEF.id}`)).toBeNull()
  })
})

describe('T-3161 search combined with the status filter', () => {
  it('passes the chosen status to the search, so the word + status gives the active row', async () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])
    renderWithAccess(<DefinitionListPage />, 'platformAdmin')
    fireEvent.change(screen.getByTestId('status-filter-select'), { target: { value: 'ACTIVE' } })
    fireEvent.change(screen.getByTestId('definition-search'), { target: { value: 'register' } })
    await waitFor(() =>
      expect(vi.mocked(useDefinitionSearch)).toHaveBeenCalledWith(
        'register',
        expect.objectContaining({ status: 'ACTIVE' }),
      ),
    )
  })
})

describe('T-3161 rendered row', () => {
  it('shows the active row the search answers for word + status Active', async () => {
    mockAuth()
    mockDefinitions([])
    vi.mocked(useDefinitionSearch).mockImplementation(
      (q: string, o?: { status?: string }) =>
        (q === 'register' && o?.status === 'ACTIVE'
          ? { data: { items: [{ definition: ACTIVE_DEF, rank: 1 }] }, isLoading: false, isFetching: false }
          : { data: undefined, isLoading: false, isFetching: false }) as unknown as ReturnType<typeof useDefinitionSearch>,
    )
    renderWithAccess(<DefinitionListPage />, 'platformAdmin')
    fireEvent.change(screen.getByTestId('status-filter-select'), { target: { value: 'ACTIVE' } })
    fireEvent.change(screen.getByTestId('definition-search'), { target: { value: 'register' } })
    expect(await screen.findByTestId(`open-process-${ACTIVE_DEF.id}`)).toBeInTheDocument()
  })
})

describe('T-2815 D5 runner residue and D8 archive refusal', () => {
  const RESIDUE = { ...ACTIVE_DEF, id: 'def-res', name: 'platform.register_tenant', version: 'uat-20261125-ab12', status: 'DEPRECATED' as const }

  it('hides uat- versions until the toggle is on', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF, RESIDUE as unknown as typeof ACTIVE_DEF])
    renderWithAccess(<DefinitionListPage />, 'designer')
    expect(screen.queryByTestId('open-process-def-res')).not.toBeInTheDocument()
    expect(screen.getByTestId(`open-process-${ACTIVE_DEF.id}`)).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('show-test-runs'))
    expect(screen.getByTestId('open-process-def-res')).toBeInTheDocument()
  })

  it('disables archive of an active version and says why', () => {
    mockAuth()
    mockDefinitions([ACTIVE_DEF])
    renderWithAccess(<DefinitionListPage />, 'designer')
    const btn = screen.getByRole('button', { name: 'Archive' })
    expect(btn).toBeDisabled()
    expect(screen.getByText('Only a deprecated version can be archived.')).toBeVisible()
    expect(btn.getAttribute('aria-describedby')).toBe(`archive-why-${ACTIVE_DEF.id}`)
  })

  it('says why when archive is refused', async () => {
    const { useArchiveDefinition } = await import('@/hooks/useDefinitions')
    vi.mocked(useArchiveDefinition).mockReturnValue({ mutate: vi.fn(), isPending: false, isError: true } as unknown as ReturnType<typeof useArchiveDefinition>)
    mockAuth()
    mockDefinitions([ACTIVE_DEF])
    renderWithAccess(<DefinitionListPage />, 'designer')
    expect(screen.getByTestId('archive-error')).toHaveTextContent('Only a deprecated version can be archived')
  })
})
