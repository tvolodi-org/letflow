// @vitest-environment jsdom
/** T-1588 C9: the definition page shows a Versions view for a saved definition (not for a new one); entering it mounts
 *  the pane, and the Editor's unsaved state survives the round trip. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useEffect } from 'react'
import { renderWithAccess } from '@/auth/access/testing'
expect.extend(jestDomMatchers)

const canvasMounts = { count: 0 }
vi.mock('@/components/diagram/ProcessDiagramLazy', () => ({ ProcessDiagramLazy: () => <div data-testid="diagram-stub" /> }))
vi.mock('@/components/diagram/DefinitionVersionsPane', () => ({
  DefinitionVersionsPane: ({ def }: { def: { id: string } }) => <div data-testid="versions-pane-stub">{def.id}</div>,
}))
vi.mock('@xyflow/react', () => ({ ReactFlowProvider: ({ children }: { children: React.ReactNode }) => <>{children}</> }))
function MockProcessCanvas({ onDirtyChange }: { onDirtyChange: (d: boolean) => void }) {
  useEffect(() => {
    canvasMounts.count += 1
    onDirtyChange(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return <div data-testid="mock-canvas" />
}
vi.mock('@/components/canvas/ProcessCanvas', () => ({ default: MockProcessCanvas }))
vi.mock('@/components/canvas/NodePalette', () => ({ default: () => <div /> }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => <div /> }))
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useParams: vi.fn(), useBlocker: vi.fn(() => ({ state: 'unblocked' as const })) }
})
vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return { ...(actual as object), useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })) }
})
vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useValidateDefinition: vi.fn(() => ({ mutateAsync: vi.fn().mockResolvedValue({ status: 'valid', findings: [] }), isPending: false })),
  useActivateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/auth/useTenantContext', () => ({ useTenantContext: vi.fn() }))
vi.mock('@/api/definitions', () => ({ definitionsApi: { promote: vi.fn(), exportJson: vi.fn(), update: vi.fn() } }))
vi.mock('@/stores/canvasHistoryStore', () => ({
  useCanvasHistoryStore: Object.assign(vi.fn(() => undefined), { getState: vi.fn(() => ({ clear: vi.fn() })) }),
}))

import { useParams } from 'react-router-dom'
import { useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'

const DEF = {
  id: 'def-1588',
  name: 'approval',
  version: '2',
  description: null,
  status: 'DRAFT',
  graph: { nodes: [{ id: 'start', node_type: 'START', label: null, attributes: null }], edges: [] },
}

function arrange(id: string | undefined) {
  vi.mocked(useParams).mockReturnValue(id ? { id } : {})
  vi.mocked(useDefinition).mockReturnValue({
    data: id ? DEF : undefined,
    isLoading: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
  } as unknown as ReturnType<typeof useDefinition>)
  vi.mocked(useAuth).mockReturnValue({
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    session: { token: 't', display_name: 'A', tenant_slug: 'acme', tenant_id: 'tid', tenant_type: 'test' },
  } as unknown as ReturnType<typeof useAuth>)
  vi.mocked(useTenantContext).mockReturnValue({ tenantType: 'test', tenantSlug: 'acme', tenantId: 'tid', tenantDisplayName: 'Acme', isUnknown: false } as unknown as ReturnType<typeof useTenantContext>)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  canvasMounts.count = 0
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

describe('T-1588 definition page: Versions view', () => {
  it('C9 the switch shows Versions, the pane mounts, and the Editor is not remounted on return', async () => {
    const user = userEvent.setup()
    arrange(DEF.id)
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(canvasMounts.count).toBe(1)
    await user.click(screen.getByTestId('definition-view-versions'))
    expect(screen.getByTestId('versions-pane-stub')).toHaveTextContent('def-1588')
    expect(screen.getByTestId('definition-view-versions')).toHaveAttribute('aria-pressed', 'true')
    await user.click(screen.getByTestId('definition-view-editor'))
    expect(screen.queryByTestId('versions-pane-stub')).toBeNull()
    expect(canvasMounts.count).toBe(1)
  })

  it('C9 a new unsaved definition has no Versions button', () => {
    arrange(undefined)
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(screen.queryByTestId('definition-view-versions')).toBeNull()
  })
})
