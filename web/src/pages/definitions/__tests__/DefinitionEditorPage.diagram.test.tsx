// @vitest-environment jsdom
/**
 * T-1520 (D-114 item 2): the Diagram | Editor switch of the definition page.
 * E1 default view per status and both switch directions; E2 no editing controls in Diagram; E3 an unsaved editor
 * edit is shown as a preview, survives the round trip (the editor is never unmounted) and is saved; E4 the
 * unsaved-changes blocker stays armed while Diagram is shown; E5 the switch and badge are localised (ru, kk).
 * The canvas is mocked as in the other suites of this page; the diagram is a stub that lists the node labels
 * (ProcessDiagram itself is covered by its own suite).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useEffect } from 'react'
import { renderWithAccess } from '@/auth/access/testing'
expect.extend(jestDomMatchers)

const canvasMounts = { count: 0 }
const EDITED = {
  nodesJSON: JSON.stringify([
    { id: 'start', position: { x: 0, y: 0 }, data: { nodeType: 'START', name: 'Start', attributes: {} } },
    { id: 'review', position: { x: 0, y: 80 }, data: { nodeType: 'HUMAN_TASK', name: 'Edited review', attributes: {} } },
    { id: 'end', position: { x: 0, y: 160 }, data: { nodeType: 'END', name: 'End', attributes: {} } },
  ]),
  edgesJSON: JSON.stringify([
    { id: 'e1', source: 'start', target: 'review', data: {} },
    { id: 'e2', source: 'review', target: 'end', data: {} },
  ]),
}

vi.mock('@/components/diagram/ProcessDiagramLazy', () => ({
  ProcessDiagramLazy: ({ graph }: { graph: { nodes: { id: string; label: string | null }[] } }) => (
    <div data-testid="diagram-stub">{graph.nodes.map((n) => n.label ?? n.id).join('|')}</div>
  ),
}))
vi.mock('@xyflow/react', () => ({
  ReactFlowProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))
function MockProcessCanvas({
  canvasStateRef,
  onDirtyChange,
}: {
  canvasStateRef: React.MutableRefObject<{ nodesJSON: string; edgesJSON: string } | null>
  onDirtyChange: (d: boolean) => void
}) {
  useEffect(() => {
    canvasMounts.count += 1
    canvasStateRef.current = EDITED
    onDirtyChange(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return <div data-testid="mock-canvas" />
}
vi.mock('@/components/canvas/ProcessCanvas', () => ({ default: MockProcessCanvas }))
vi.mock('@/components/canvas/NodePalette', () => ({ default: () => <div data-testid="mock-palette" /> }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => <div data-testid="mock-property-panel" /> }))

const blockerPredicates: Array<(a: { currentLocation: { pathname: string }; nextLocation: { pathname: string } }) => boolean> = []
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useParams: vi.fn(),
    useBlocker: vi.fn((p) => {
      blockerPredicates.push(p)
      return { state: 'unblocked' as const }
    }),
  }
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
vi.mock('@/api/definitions', () => ({
  definitionsApi: { promote: vi.fn(), exportJson: vi.fn(), update: vi.fn().mockResolvedValue({}) },
}))
vi.mock('@/stores/canvasHistoryStore', () => ({
  useCanvasHistoryStore: Object.assign(vi.fn(() => undefined), { getState: vi.fn(() => ({ clear: vi.fn() })) }),
}))

import { useParams } from 'react-router-dom'
import { useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import { definitionsApi } from '@/api/definitions'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'

const DEF = {
  id: 'def-1520',
  name: 'Order approval',
  version: '1.0.0',
  description: null,
  graph: {
    nodes: [
      { id: 'start', node_type: 'START', label: null, attributes: null },
      { id: 'review', node_type: 'HUMAN_TASK', label: 'Review', attributes: null },
      { id: 'end', node_type: 'END', label: null, attributes: null },
    ],
    edges: [
      { id: 'e1', source: 'start', target: 'review' },
      { id: 'e2', source: 'review', target: 'end' },
    ],
  },
}

function arrange(status: 'DRAFT' | 'ACTIVE') {
  vi.mocked(useParams).mockReturnValue({ id: DEF.id })
  vi.mocked(useDefinition).mockReturnValue({
    data: { ...DEF, status },
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
  vi.mocked(useTenantContext).mockReturnValue({
    tenantType: 'test',
    tenantSlug: 'acme',
    tenantId: 'tid',
    tenantDisplayName: 'Acme',
    isUnknown: false,
  } as unknown as ReturnType<typeof useTenantContext>)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  canvasMounts.count = 0
  blockerPredicates.length = 0
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

describe('T-1520 definition page: Diagram | Editor', () => {
  it('E1 a read-only definition opens on the diagram, a DRAFT on the editor; the switch works both ways', async () => {
    const user = userEvent.setup()
    arrange('ACTIVE')
    const { unmount } = renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(screen.getByTestId('diagram-stub')).toHaveTextContent('Review')
    expect(screen.queryByTestId('mock-canvas')).toBeNull()
    await user.click(screen.getByTestId('definition-view-editor'))
    expect(screen.getByTestId('mock-canvas')).toBeInTheDocument()
    expect(screen.queryByTestId('diagram-stub')).toBeNull()
    await user.click(screen.getByTestId('definition-view-diagram'))
    expect(screen.getByTestId('diagram-stub')).toBeInTheDocument()
    unmount()

    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(screen.getByTestId('mock-canvas')).toBeInTheDocument()
    expect(screen.getByTestId('definition-view-editor')).toHaveAttribute('aria-pressed', 'true')
  })

  it('E2 the diagram view has no palette and no property inputs', () => {
    arrange('ACTIVE')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(screen.queryByTestId('mock-palette')).toBeNull()
    expect(screen.queryByTestId('mock-property-panel')).toBeNull()
  })

  it('E3 an unsaved edit is previewed with the badge, survives Diagram → Editor (no remount) and is saved', async () => {
    const user = userEvent.setup()
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(canvasMounts.count).toBe(1)
    await user.click(screen.getByTestId('definition-view-diagram'))
    expect(screen.getByTestId('diagram-stub')).toHaveTextContent('Edited review')
    expect(screen.getByTestId('definition-unsaved-badge')).toHaveTextContent('Preview of unsaved changes')
    // the editor is hidden, not unmounted
    expect(screen.getByTestId('definition-editor-view')).not.toBeVisible()
    await user.click(screen.getByTestId('definition-view-editor'))
    expect(canvasMounts.count).toBe(1)
    await user.click(screen.getByTestId('btn-save-definition'))
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalled())
    const payload = vi.mocked(definitionsApi.update).mock.calls[0][1] as { graph: { nodes: { label: string | null }[] } }
    expect(payload.graph.nodes.map((n) => n.label)).toContain('Edited review')
  })

  it('E4 the unsaved-changes blocker stays armed while the diagram is shown', async () => {
    const user = userEvent.setup()
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-diagram'))
    const latest = blockerPredicates[blockerPredicates.length - 1]
    expect(latest({ currentLocation: { pathname: '/definitions/def-1520' }, nextLocation: { pathname: '/instances' } })).toBe(true)
  })

  it.each(['ru', 'kk'] as const)('E5 the switch, its group label and the badge render in %s', async (locale) => {
    const user = userEvent.setup()
    act(() => useUiLocaleStore.getState().setLocale(locale))
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    const msg = processDiagramMessages[locale]
    expect(screen.getByRole('group', { name: msg['processDiagram.view.group'] })).toBeInTheDocument()
    expect(screen.getByTestId('definition-view-diagram')).toHaveTextContent(msg['processDiagram.view.diagram'])
    expect(screen.getByTestId('definition-view-editor')).toHaveTextContent(msg['processDiagram.view.editor'])
    await user.click(screen.getByTestId('definition-view-diagram'))
    expect(screen.getByTestId('definition-unsaved-badge')).toHaveTextContent(msg['processDiagram.view.unsavedBadge'])
    // the rest of the page keeps its existing (English) text
    expect(screen.getByText('Order approval')).toBeInTheDocument()
  })
})
