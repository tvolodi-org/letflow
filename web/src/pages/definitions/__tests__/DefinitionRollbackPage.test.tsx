// @vitest-environment jsdom
/**
 * Unit tests — REQ-371: DefinitionRollbackPage + classifyRollbackError
 *
 * See lib/letflow/design/req371-rollback-withdrawal-screen.md §8.1. Mocks
 * `@/hooks/useDefinitions` directly (matching
 * `DefinitionEditorPage.promote.test.tsx`'s established convention of
 * mocking the hooks module rather than the underlying API client), and
 * `@/auth/AuthContext`/`react-router-dom`'s `useParams`/`Navigate`.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
import type { ApiError } from '@/types/api'

expect.extend(jestDomMatchers)

// ── Mocks ────────────────────────────────────────────────────────────────────

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useParams: vi.fn(() => ({ id: 'def-active-id' })),
    Navigate: vi.fn(({ to }: { to: string }) => <div data-testid="navigate-mock">{to}</div>),
  }
})

const mockMutateAsync = vi.fn()

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useDefinitionVersions: vi.fn(),
  useRollbackDefinition: vi.fn(() => ({ mutateAsync: mockMutateAsync, isPending: false })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { useParams, Navigate } from 'react-router-dom'
import { useDefinition, useDefinitionVersions } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import DefinitionRollbackPage, { classifyRollbackError } from '@/pages/definitions/DefinitionRollbackPage'
import { renderWithAccess } from '@/auth/access/testing'

const ACTIVE_DEF = {
  id: 'def-active-id',
  name: 'approvals',
  version: '2.0.0',
  status: 'ACTIVE',
  description: '',
  graph: { nodes: [], edges: [] },
  created_by: 'admin-user',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
}

const VERSIONS = {
  items: [
    { ...ACTIVE_DEF, id: 'v2', version: '2.0.0', status: 'ACTIVE' },
    { ...ACTIVE_DEF, id: 'v1', version: '1.0.0', status: 'DEPRECATED' },
    { ...ACTIVE_DEF, id: 'v0', version: '0.9.0', status: 'ARCHIVED' },
  ],
}

function setupAdmin() {
  vi.mocked(useAuth).mockReturnValue({
    session: { token: 't', display_name: 'op-1', loginSource: null, tenant_slug: null, tenant_display_name: null, tenant_id: null, tenant_type: null},
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  } as unknown as ReturnType<typeof useAuth>)
  vi.mocked(useDefinition).mockReturnValue({
    data: ACTIVE_DEF,
    isLoading: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
  } as unknown as ReturnType<typeof useDefinition>)
  vi.mocked(useDefinitionVersions).mockReturnValue({
    data: VERSIONS,
    isLoading: false,
  } as unknown as ReturnType<typeof useDefinitionVersions>)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('DefinitionRollbackPage — role gating', () => {
  it('TC-REQ371-01: non-platform-admin session redirects to /instances', () => {
    vi.mocked(useParams).mockReturnValue({ id: 'def-active-id' })
    vi.mocked(useAuth).mockReturnValue({
      session: { token: 't', display_name: 'designer-1', loginSource: null, tenant_slug: null, tenant_display_name: null, tenant_id: null, tenant_type: null},
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    } as unknown as ReturnType<typeof useAuth>)
    vi.mocked(useDefinition).mockReturnValue({ data: undefined, isLoading: false, isError: false, error: null, refetch: vi.fn() } as unknown as ReturnType<typeof useDefinition>)
    vi.mocked(useDefinitionVersions).mockReturnValue({ data: undefined, isLoading: false } as unknown as ReturnType<typeof useDefinitionVersions>)

    renderWithAccess(<DefinitionRollbackPage />, 'designer')

    expect(Navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/instances', replace: true }), expect.anything())
    expect(screen.getByTestId('navigate-mock')).toHaveTextContent('/instances')
  })
})

describe('DefinitionRollbackPage — version picker', () => {
  it('TC-REQ371-02: platform-admin session renders the version picker excluding the ACTIVE row', () => {
    setupAdmin()
    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    const select = screen.getByTestId('rollback-target-version-select') as HTMLSelectElement
    const optionValues = Array.from(select.options).map((o) => o.value)
    expect(optionValues).not.toContain('2.0.0') // the current ACTIVE row is excluded
    expect(optionValues).toContain('1.0.0')
    expect(optionValues).toContain('0.9.0')
    expect(optionValues).toContain('__other__')
  })
})

describe('DefinitionRollbackPage — reason gating + confirmation flow', () => {
  it('TC-REQ371-03: empty reason keeps Continue disabled; filling it enables progression to the confirmation panel', () => {
    setupAdmin()
    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    const select = screen.getByTestId('rollback-target-version-select')
    fireEvent.change(select, { target: { value: '1.0.0' } })

    const continueBtn = screen.getByTestId('rollback-continue-btn')
    expect(continueBtn).toBeDisabled()

    const reasonInput = screen.getByTestId('rollback-reason-input')
    fireEvent.change(reasonInput, { target: { value: 'Wrong reviewer routing.' } })

    expect(continueBtn).not.toBeDisabled()
    fireEvent.click(continueBtn)

    expect(screen.getByTestId('rollback-confirm-dialog')).toBeInTheDocument()
  })

  it('TC-REQ371-04: confirming calls rollback with the exact selected target_version and renders success banner + history entry', async () => {
    setupAdmin()
    mockMutateAsync.mockResolvedValueOnce({
      definition_id: 'def-active-id',
      version: '1.0.0',
      rolled_back_from_version: '2.0.0',
      superseded_review_id: null,
      event_id: 'evt-123',
    })

    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    fireEvent.change(screen.getByTestId('rollback-target-version-select'), { target: { value: '1.0.0' } })
    fireEvent.change(screen.getByTestId('rollback-reason-input'), { target: { value: 'Wrong reviewer routing.' } })
    fireEvent.click(screen.getByTestId('rollback-continue-btn'))
    fireEvent.click(screen.getByTestId('rollback-confirm-btn'))

    await waitFor(() => {
      expect(mockMutateAsync).toHaveBeenCalledWith({ processKey: 'approvals', targetVersion: '1.0.0' })
    })

    await waitFor(() => {
      expect(screen.getByTestId('rollback-success-banner')).toHaveTextContent('Rolled back to 1.0.0')
    })

    const entry = screen.getByTestId('rollback-history-entry')
    expect(entry).toHaveTextContent('1.0.0')
    expect(entry).toHaveTextContent('2.0.0')
    expect(entry).toHaveTextContent('evt-123')
    expect(entry).toHaveTextContent('op-1')
  })
})

describe('DefinitionRollbackPage — error rendering (§5)', () => {
  async function driveToConfirmAndFail(apiError: ApiError) {
    setupAdmin()
    mockMutateAsync.mockRejectedValueOnce(apiError)

    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    fireEvent.change(screen.getByTestId('rollback-target-version-select'), { target: { value: '1.0.0' } })
    fireEvent.change(screen.getByTestId('rollback-reason-input'), { target: { value: 'reason' } })
    fireEvent.click(screen.getByTestId('rollback-continue-btn'))
    fireEvent.click(screen.getByTestId('rollback-confirm-btn'))
  }

  it('TC-REQ371-05a: 403 renders rollback-error-forbidden', async () => {
    await driveToConfirmAndFail({ status: 403, message: 'Forbidden', code: '403' })
    await waitFor(() => expect(screen.getByTestId('rollback-error-forbidden')).toBeInTheDocument())
  })

  it('TC-REQ371-05b: 404 renders rollback-error-not-found', async () => {
    await driveToConfirmAndFail({ status: 404, message: 'Not Found', code: '404' })
    await waitFor(() => expect(screen.getByTestId('rollback-error-not-found')).toBeInTheDocument())
  })

  it('TC-REQ371-05c: 422 version_never_active renders rollback-error-version-never-active', async () => {
    await driveToConfirmAndFail({
      status: 422,
      message: 'Unprocessable Entity',
      code: '422',
      details: { detail: 'target_version was never active' },
    })
    await waitFor(() => expect(screen.getByTestId('rollback-error-version-never-active')).toBeInTheDocument())
    expect(screen.getByTestId('rollback-error-version-never-active')).toHaveTextContent('1.0.0')
  })

  it('TC-REQ371-05d: 422 already_active renders rollback-error-already-active', async () => {
    await driveToConfirmAndFail({
      status: 422,
      message: 'Unprocessable Entity',
      code: '422',
      details: { detail: 'target_version is already the active version' },
    })
    await waitFor(() => expect(screen.getByTestId('rollback-error-already-active')).toBeInTheDocument())
  })
})

describe('DefinitionRollbackPage — "Other version…" manual-entry branch (§4 step 2)', () => {
  it('TC-REQ371-07: selecting "Other version…" switches to a manual text input', () => {
    setupAdmin()
    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    expect(screen.queryByTestId('rollback-target-version-manual')).not.toBeInTheDocument()

    fireEvent.change(screen.getByTestId('rollback-target-version-select'), { target: { value: '__other__' } })

    expect(screen.queryByTestId('rollback-target-version-select')).not.toBeInTheDocument()
    expect(screen.getByTestId('rollback-target-version-manual')).toBeInTheDocument()
  })

  it('TC-REQ371-08: typing a version into the manual input updates state and enables Continue once reason is set', () => {
    setupAdmin()
    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    fireEvent.change(screen.getByTestId('rollback-target-version-select'), { target: { value: '__other__' } })
    fireEvent.change(screen.getByTestId('rollback-target-version-manual'), { target: { value: '9.9.9' } })

    const continueBtn = screen.getByTestId('rollback-continue-btn')
    expect(continueBtn).toBeDisabled() // reason still empty

    fireEvent.change(screen.getByTestId('rollback-reason-input'), { target: { value: 'Manual version test.' } })
    expect(continueBtn).not.toBeDisabled()

    fireEvent.click(continueBtn)
    expect(screen.getByTestId('rollback-confirm-dialog')).toHaveTextContent('9.9.9')
  })

  it('TC-REQ371-09: "Choose from the list instead" cancels the manual entry and reverts to the dropdown, clearing the typed value', () => {
    setupAdmin()
    renderWithAccess(<DefinitionRollbackPage />, 'platformAdmin')

    fireEvent.change(screen.getByTestId('rollback-target-version-select'), { target: { value: '__other__' } })
    fireEvent.change(screen.getByTestId('rollback-target-version-manual'), { target: { value: '9.9.9' } })

    fireEvent.click(screen.getByTestId('rollback-target-version-manual-cancel'))

    expect(screen.queryByTestId('rollback-target-version-manual')).not.toBeInTheDocument()
    const select = screen.getByTestId('rollback-target-version-select') as HTMLSelectElement
    expect(select.value).toBe('')

    // Confirms the manually-typed value was actually cleared, not just hidden:
    // re-selecting "Other version…" should show a blank input, not "9.9.9".
    fireEvent.change(select, { target: { value: '__other__' } })
    expect(screen.getByTestId('rollback-target-version-manual')).toHaveValue('')
  })
})

describe('classifyRollbackError — direct unit coverage (§8.1 item 6)', () => {
  it('TC-REQ371-06a: 403 -> forbidden', () => {
    expect(classifyRollbackError({ status: 403, message: 'Forbidden', code: '403' })).toBe('forbidden')
  })
  it('TC-REQ371-06b: 404 -> not_found', () => {
    expect(classifyRollbackError({ status: 404, message: 'Not Found', code: '404' })).toBe('not_found')
  })
  it('TC-REQ371-06c: 422 with "target_version was never active" detail -> version_never_active', () => {
    expect(
      classifyRollbackError({ status: 422, message: 'Unprocessable Entity', code: '422', details: { detail: 'target_version was never active' } }),
    ).toBe('version_never_active')
  })
  it('TC-REQ371-06d: 422 with "target_version is already the active version" detail -> already_active', () => {
    expect(
      classifyRollbackError({ status: 422, message: 'Unprocessable Entity', code: '422', details: { detail: 'target_version is already the active version' } }),
    ).toBe('already_active')
  })
  it('TC-REQ371-06e: 500 with no matching detail -> unknown (must not be fooled by err.message)', () => {
    expect(
      classifyRollbackError({ status: 500, message: 'Unprocessable Entity', code: '500', details: { detail: 'some other unrelated detail' } }),
    ).toBe('unknown')
  })
})
