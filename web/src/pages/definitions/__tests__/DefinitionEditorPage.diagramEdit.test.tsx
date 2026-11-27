// @vitest-environment jsdom
/**
 * T-1563 (D-114 item 2, slice 2): the "Edit diagram" view of the definition page. S5: the Editor and the diagram draft
 * lock each other (an unsaved edit on one side refuses/disables the other); the unsaved-changes blocker covers the
 * diagram draft; a designer sees the switch button, a reader does not. The edit pane itself is stubbed (its own suite
 * is DiagramEditPane.test.tsx). Original header of the copied setup follows.
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
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
expect.extend(jestDomMatchers)

const canvasMounts = { count: 0 }
const probe = vi.hoisted(() => ({ order: [] as string[], canvasDirty: true, setQueryData: undefined as ((...a: unknown[]) => void) | undefined }))
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

vi.mock('@/components/diagram/DiagramEditPane', () => ({
  DiagramEditPane: ({ onDirtyChange, onSaved, onProblemsChange, def }: { onDirtyChange: (d: boolean) => void; onProblemsChange?: (n: number) => void; onSaved: (d: unknown, copied: boolean) => void; def: { id: string } }) => {
    // Local state stands for the unsaved graph and undo history: a remount would lose it.
    const [edits, setEdits] = React.useState(0)
    return (
    <div data-testid="edit-pane-stub">
      <span data-testid="edit-pane-edits">{edits}</span>
      <button onClick={() => setEdits((n) => n + 1)}>edit-once</button>
      <button onClick={() => onDirtyChange(true)}>make-dirty</button>
      <button onClick={() => { onDirtyChange(false); onSaved({ id: def.id }, false) }}>save-ok</button>
      <button onClick={() => { onSaved({ id: 'saved-copy' }, true) }}>copy-ok</button>
      <button onClick={() => onProblemsChange?.(1)}>problems-1</button>
      <button onClick={() => onProblemsChange?.(0)}>problems-0</button>
    </div>
    )
  },
}))
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
    probe.order.push('mount')
    canvasStateRef.current = EDITED
    onDirtyChange(probe.canvasDirty)
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
    Navigate: ({ to }: { to: string }) => <div data-testid="copy-target">{to}</div>,
    useBlocker: vi.fn((p) => {
      blockerPredicates.push(p)
      return { state: 'unblocked' as const }
    }),
  }
})
vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return { ...(actual as object), useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn(), setQueryData: (...a: unknown[]) => { probe.order.push('cache'); probe.setQueryData?.(...a) } })) }
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
import { useDefinition, useActivateDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
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
  const refetch = vi.fn()
  vi.mocked(useParams).mockReturnValue({ id: DEF.id })
  vi.mocked(useDefinition).mockReturnValue({
    data: { ...DEF, status },
    isLoading: false,
    isError: false,
    error: null,
    refetch,
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
  return refetch
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  canvasMounts.count = 0
  probe.order.length = 0
  probe.canvasDirty = true
  blockerPredicates.length = 0
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

describe('T-1563 definition page: Edit diagram', () => {
  it('T2012 a new definition id remounts the hidden editor with its own graph', async () => {
    probe.canvasDirty = false
    arrange('DRAFT')
    const page = renderWithAccess(<DefinitionEditorPage />, 'designer')
    await waitFor(() => expect(canvasMounts.count).toBe(1))
    vi.mocked(useParams).mockReturnValue({ id: 'saved-copy' })
    page.rerender(<AccessStateProvider state={accessState('designer')}><DefinitionEditorPage /></AccessStateProvider>)
    await waitFor(() => expect(canvasMounts.count).toBe(2))
  })
  it('T2012 an acknowledged copy bypasses the stale blocker only for that copy', async () => {
    const user = userEvent.setup()
    arrange('ACTIVE')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-edit'))
    await user.click(screen.getByText('make-dirty'))
    // Navigate's effect can run before useBlocker installs the clean predicate.
    const beforeSave = blockerPredicates.at(-1)!
    expect(beforeSave({ currentLocation: { pathname: '/definitions/old' }, nextLocation: { pathname: '/definitions/saved-copy' } })).toBe(true)
    await user.click(screen.getByText('copy-ok'))
    expect(beforeSave({ currentLocation: { pathname: '/definitions/old' }, nextLocation: { pathname: '/definitions/saved-copy' } })).toBe(false)
    expect(beforeSave({ currentLocation: { pathname: '/definitions/old' }, nextLocation: { pathname: '/tasks' } })).toBe(true)
    expect(screen.getByTestId('copy-target')).toHaveTextContent('/definitions/saved-copy')
  })
  it.each([
    { status: 422, details: [{ code: 'missing_end', message: 'Missing end step' }] },
    { status: 500, message: 'Service unavailable' },
  ])('T2012 publishing reports a $status failure without claiming success', async failure => {
    const user = userEvent.setup()
    probe.canvasDirty = false
    vi.mocked(useActivateDefinition).mockReturnValue({ mutateAsync: vi.fn().mockRejectedValue(failure) } as unknown as ReturnType<typeof useActivateDefinition>)
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-edit'))
    await user.click(screen.getByTestId('btn-publish-diagram'))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('Publishing failed'))
    expect(screen.queryByText('This version is active. New instances will use it.')).toBeNull()
    expect(screen.getByTestId('btn-publish-diagram')).toBeEnabled()
  })
  it('T2012 refreshes the saved definition before further diagram edits', async () => {
    const user = userEvent.setup()
    probe.canvasDirty = false
    const refresh = arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('btn-save-definition'))
    await waitFor(() => expect(refresh).toHaveBeenCalled())
  })
  it('T2012 publishes the saved diagram and refuses unsaved edits', async () => {
    const user = userEvent.setup()
    probe.canvasDirty = false
    const publish = vi.fn().mockResolvedValue({})
    vi.mocked(useActivateDefinition).mockReturnValue({ mutateAsync: publish } as unknown as ReturnType<typeof useActivateDefinition>)
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-edit'))
    expect(screen.getByTestId('btn-publish-diagram')).toBeEnabled()
    await user.click(screen.getByText('make-dirty'))
    expect(screen.getByTestId('btn-publish-diagram')).toBeDisabled()
    expect(publish).not.toHaveBeenCalled()
    await user.click(screen.getByText('save-ok'))
    await user.click(screen.getByTestId('btn-publish-diagram'))
    await waitFor(() => expect(publish).toHaveBeenCalledWith(DEF.id))
  })
  it('T-2812 D2d a saved draft with an open problem: Publish disabled with the reason, no activation; count 0 enables it', async () => {
    const user = userEvent.setup()
    probe.canvasDirty = false
    const publish = vi.fn().mockResolvedValue({})
    vi.mocked(useActivateDefinition).mockReturnValue({ mutateAsync: publish } as unknown as ReturnType<typeof useActivateDefinition>)
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-edit'))
    await user.click(screen.getByText('problems-1'))
    const btn = screen.getByTestId('btn-publish-diagram')
    expect(btn).toBeDisabled()
    expect(btn).toHaveAttribute('title', expect.stringContaining('Open problems in the saved draft: 1'))
    expect(screen.getByTestId('publish-blocked-reason')).toHaveTextContent('Open problems in the saved draft: 1')
    await user.click(btn)
    expect(publish).not.toHaveBeenCalled()
    await user.click(screen.getByText('problems-0'))
    expect(screen.getByTestId('btn-publish-diagram')).toBeEnabled()
    expect(screen.queryByTestId('publish-blocked-reason')).toBeNull()
  })
  it('S5 a dirty diagram draft disables the Editor button; saving releases it', async () => {
    const user = userEvent.setup()
    arrange('ACTIVE') // opens on the diagram: the (mocked) Editor canvas is not mounted, so it is not dirty
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-edit'))
    expect(screen.getByTestId('edit-pane-stub')).toBeInTheDocument()
    expect(screen.getByTestId('definition-view-editor')).not.toBeDisabled()
    await user.click(screen.getByText('make-dirty'))
    expect(screen.getByTestId('definition-view-editor')).toBeDisabled()
    expect(blockerPredicates.at(-1)?.({ currentLocation: { pathname: '/a' }, nextLocation: { pathname: '/b' } })).toBe(true)
    await user.click(screen.getByText('save-ok'))
    expect(screen.getByTestId('definition-view-editor')).not.toBeDisabled()
  })

  it('R1 switching to the read-only Diagram and back keeps the unsaved diagram draft and its history', async () => {
    const user = userEvent.setup()
    arrange('ACTIVE')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await user.click(screen.getByTestId('definition-view-edit'))
    await user.click(screen.getByText('edit-once'))
    await user.click(screen.getByText('edit-once'))
    await user.click(screen.getByText('make-dirty'))
    await user.click(screen.getByTestId('definition-view-diagram'))
    // hidden, not unmounted; the Editor stays locked while the draft is dirty
    expect(screen.getByTestId('definition-edit-view')).not.toBeVisible()
    expect(screen.getByTestId('definition-view-editor')).toBeDisabled()
    await user.click(screen.getByTestId('definition-view-edit'))
    expect(screen.getByTestId('definition-edit-view')).toBeVisible()
    expect(screen.getByTestId('edit-pane-edits')).toHaveTextContent('2')
  })

  it('P1 after a diagram save the saved definition is in the detail cache BEFORE the Editor remounts', async () => {
    const user = userEvent.setup()
    probe.canvasDirty = false
    probe.setQueryData = vi.fn()
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await waitFor(() => expect(canvasMounts.count).toBe(1))
    await user.click(screen.getByTestId('definition-view-edit'))
    await user.click(screen.getByText('save-ok'))
    await waitFor(() => expect(canvasMounts.count).toBe(2))
    expect(probe.setQueryData).toHaveBeenCalledWith(expect.anything(), { id: DEF.id })
    expect(probe.order).toEqual(['mount', 'cache', 'mount'])
  })

  it('P2 while the diagram draft is dirty the Editor controls (Save, Re-layout, Raw JSON, Submit) are gone from either view', async () => {
    const user = userEvent.setup()
    probe.canvasDirty = false
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await waitFor(() => expect(screen.getByTestId('btn-auto-layout')).toBeInTheDocument())
    await user.click(screen.getByTestId('definition-view-edit'))
    for (const id of ['btn-auto-layout', 'btn-save-definition', 'btn-show-raw-json', 'btn-submit-for-release']) expect(screen.queryByTestId(id)).toBeNull()
    await user.click(screen.getByText('make-dirty'))
    await user.click(screen.getByTestId('definition-view-diagram'))
    for (const id of ['btn-auto-layout', 'btn-save-definition', 'btn-show-raw-json', 'btn-submit-for-release']) expect(screen.queryByTestId(id)).toBeNull()
    expect(canvasMounts.count).toBe(1) // nothing remounted or touched the hidden Editor
  })

  it('S5 an unsaved Editor change refuses Edit diagram with the reason', async () => {
    const user = userEvent.setup()
    arrange('DRAFT')
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    await waitFor(() => expect(screen.getByTestId('definition-view-edit')).toBeInTheDocument())
    await user.click(screen.getByTestId('definition-view-edit'))
    expect(screen.queryByTestId('edit-pane-stub')).toBeNull()
    expect(screen.getByTestId('definition-edit-refused')).toHaveTextContent('Editor has unsaved changes')
  })

  it.each(['ACTIVE', 'DRAFT'] as const)('a reader never sees edit or publish controls for %s', status => {
    arrange(status)
    renderWithAccess(<DefinitionEditorPage />, 'auditor')
    expect(screen.queryByTestId('definition-view-edit')).toBeNull()
    expect(screen.queryByTestId('btn-publish-diagram')).toBeNull()
  })

  it('the Edit diagram label is localised (ru, kk)', () => {
    arrange('ACTIVE')
    act(() => useUiLocaleStore.getState().setLocale('ru'))
    renderWithAccess(<DefinitionEditorPage />, 'designer')
    expect(screen.getByTestId('definition-view-edit')).toHaveTextContent(processDiagramMessages.ru['processDiagram.view.edit'])
  })
})
