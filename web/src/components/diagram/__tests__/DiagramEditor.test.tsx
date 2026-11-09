// @vitest-environment jsdom
/** T-1563 DiagramEditor and NodeEditPanel, with the real React Flow (jsdom has no layout, so ResizeObserver is stubbed).
 *  N1 handles non-connectable when reading / connectable when editing, N2 illegal connection refused, E1 add, E2 Delete,
 *  E3 node marker (glyph + word), E4 edge marker, E5 list item selects the node, U5 undo/redo keys (not while typing),
 *  K1 Enter opens the panel, K2 Alt+Arrow, K3 Connect from this step, K4 Delete, K5 aria-live, K6 accessible names,
 *  K7 connection row Edit, K8 row Delete connection, K9 narrow step list, P1..P5 properties and the script binding. */
import { useState } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'
import type { DefinitionGraph, NodeType } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import ProcessDiagram from '../ProcessDiagram'
import DiagramEditor from '../DiagramEditor'
import { useDiagramDraft, type DiagramDraft } from '@/hooks/useDiagramDraft'
import type { DraftCheck } from '@/hooks/useValidateDraft'
import { positionOf, readAttrs } from '@/utils/canvas/graphEdit'
expect.extend(jestDomMatchers)

let width = 1200
class RO {
  constructor(private cb: ResizeObserverCallback) {}
  observe(el: Element) {
    this.cb([{ contentRect: { width, height: 600 }, target: el } as unknown as ResizeObserverEntry], this as unknown as ResizeObserver)
  }
  unobserve() {}
  disconnect() {}
}
class DOMMatrixRO {
  m22 = 1
}
Object.defineProperties(window.HTMLElement.prototype, {
  offsetHeight: { configurable: true, get: () => 600 },
  offsetWidth: { configurable: true, get: () => 1000 },
})
beforeEach(() => {
  width = 1200
  vi.stubGlobal('ResizeObserver', RO)
  vi.stubGlobal('DOMMatrixReadOnly', DOMMatrixRO)
})
afterEach(() => {
  cleanup()
  act(() => useUiLocaleStore.getState().setLocale('en'))
  vi.unstubAllGlobals()
})

const node = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null, x: number, y: number) => ({
  id,
  node_type,
  label,
  attributes: { ...(attributes ?? {}), position: { x, y } },
})
const GRAPH: DefinitionGraph = {
  nodes: [
    node('start', 'START', null, null, 0, 0),
    node('review', 'HUMAN_TASK', 'Review', { role: 'CLERK', form_schema: { properties: { a: {} } }, mystery: 1 }, 0, 160),
    node('call', 'SERVICE_TASK', 'Call', null, 0, 320),
    node('end', 'END', null, null, 0, 480),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'review' },
    { id: 'e2', source: 'review', target: 'call', condition: 'a > 1' },
    { id: 'e3', source: 'call', target: 'end' },
  ],
}

let latest: DiagramDraft
const onSave = vi.fn()
function Harness({ seed = GRAPH, violations = [], check = { phase: 'idle' } as DraftCheck }: { seed?: DefinitionGraph; violations?: { code: string; message: string }[]; check?: DraftCheck }) {
  const draft = useDiagramDraft(seed)
  latest = draft
  const [, force] = useState(0)
  void force
  return (
    <DiagramEditor
      draft={draft}
      violations={violations}
      check={check}
      toolbar={{ onSave, onDiscard: vi.fn(), saving: false, saveBlockedReason: null, saveLabel: 'Save draft' }}
    />
  )
}
const renderEditor = (props: React.ComponentProps<typeof Harness> = {}) =>
  render(
    <ProcessDiagramIntlProvider>
      <Harness {...props} />
    </ProcessDiagramIntlProvider>,
  )
const nodeIds = () => latest.graph.nodes.map((n) => n.id)
const openNode = (id: string) => {
  const el = document.querySelector(`.react-flow__node[data-id="${id}"]`) as HTMLElement
  fireEvent.click(el)
  return el
}

describe('T-1563 diagram editor', () => {
  it('N1 read mode handles are not connectable, edit mode handles are', () => {
    const { unmount } = render(
      <ProcessDiagramIntlProvider>
        <ProcessDiagram graph={GRAPH} />
      </ProcessDiagramIntlProvider>,
    )
    expect(document.querySelectorAll('.react-flow__handle.connectable').length).toBe(0)
    unmount()
    renderEditor()
    expect(document.querySelectorAll('.react-flow__handle.connectable').length).toBeGreaterThan(0)
    expect(document.querySelector('.lf-pd__canvas.is-editing')).not.toBeNull()
  })

  it('E1 Add step adds a node with a position and opens its panel; K5 announces it', () => {
    renderEditor()
    fireEvent.change(screen.getByLabelText('Step type'), { target: { value: 'TIMER' } })
    fireEvent.click(screen.getByTestId('edit-add'))
    expect(nodeIds()).toContain('n_timer_1')
    expect(positionOf(latest.graph.nodes.find((n) => n.id === 'n_timer_1')!)).not.toBeNull()
    expect(screen.getByTestId('edit-node-panel')).toBeInTheDocument()
    expect(screen.getByTestId('edit-live')).toHaveTextContent('Added step')
    // the other nodes are carried through unchanged (single source of truth)
    expect(latest.graph.nodes.find((n) => n.id === 'review')).toEqual(GRAPH.nodes[1])
  })

  it('E2/K4 Delete removes the selected step and its connections; START is refused', () => {
    renderEditor()
    openNode('call')
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'Delete' })
    expect(nodeIds()).not.toContain('call')
    expect(latest.graph.edges.map((e) => e.id)).toEqual(['e1'])
    openNode('start')
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'Delete' })
    expect(nodeIds()).toContain('start')
    expect(screen.getByTestId('edit-live')).toHaveTextContent('start cannot be deleted')
  })

  it('U5 Ctrl+Z / Ctrl+Shift+Z undo and redo, but not while typing in a field', () => {
    renderEditor()
    openNode('call')
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'Delete' })
    expect(nodeIds()).not.toContain('call')
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'z', ctrlKey: true })
    expect(nodeIds()).toContain('call')
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'z', ctrlKey: true, shiftKey: true })
    expect(nodeIds()).not.toContain('call')
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'z', ctrlKey: true })
    openNode('review')
    fireEvent.keyDown(screen.getByTestId('edit-field-label'), { key: 'z', ctrlKey: true })
    expect(nodeIds()).toContain('call') // unchanged: typing owns the key
    expect(latest.canUndo).toBe(false)
  })

  it('K1 Enter on a focused step opens the panel; Escape closes it', () => {
    renderEditor()
    const el = document.querySelector('.react-flow__node[data-id="review"]') as HTMLElement
    fireEvent.keyDown(el, { key: 'Enter' })
    expect(screen.getByTestId('edit-node-panel')).toBeInTheDocument()
    fireEvent.keyDown(screen.getByTestId('diagram-editor'), { key: 'Escape' })
    expect(screen.queryByTestId('edit-node-panel')).toBeNull()
  })

  it('K2 Alt+Arrow moves the selected step by 16 px (Shift 64) and is one undo step per burst', () => {
    renderEditor()
    openNode('review')
    const ed = screen.getByTestId('diagram-editor')
    fireEvent.keyDown(ed, { key: 'ArrowRight', altKey: true })
    fireEvent.keyDown(ed, { key: 'ArrowRight', altKey: true })
    expect(positionOf(latest.graph.nodes.find((n) => n.id === 'review')!)).toEqual({ x: 32, y: 160 })
    fireEvent.keyDown(ed, { key: 'ArrowDown', altKey: true, shiftKey: true })
    expect(positionOf(latest.graph.nodes.find((n) => n.id === 'review')!)).toEqual({ x: 32, y: 224 })
    // the whole nudge burst is ONE undo step
    fireEvent.keyDown(ed, { key: 'z', ctrlKey: true })
    expect(positionOf(latest.graph.nodes.find((n) => n.id === 'review')!)).toEqual({ x: 0, y: 160 })
  })

  it('K3/N2 "Connect from this step" lists legal targets only and creates the edge; a self-loop is not offered', () => {
    renderEditor()
    openNode('review')
    const select = within(screen.getByTestId('edit-connections')).getByRole('combobox')
    const options = within(select).getAllByRole('option').map((o) => o.textContent)
    expect(options).not.toContain('Review') // self loop
    expect(options).not.toContain('Start') // into START
    expect(options).toContain('End')
    fireEvent.change(select, { target: { value: 'end' } })
    fireEvent.click(screen.getByTestId('edit-connect-go'))
    expect(latest.graph.edges.some((e) => e.source === 'review' && e.target === 'end')).toBe(true)
    expect(screen.getByTestId('edit-live')).toHaveTextContent('Connected Review to End')
  })

  it.each(['en', 'ru', 'kk'] as const)('K10 React Flow control names and keyboard instructions are in the UI language (%s)', (loc) => {
    act(() => useUiLocaleStore.getState().setLocale(loc))
    renderEditor()
    const msg = processDiagramMessages[loc]
    expect(document.querySelector(`.react-flow__controls button[aria-label="${msg['processDiagram.a11y.zoomIn']}"]`)).not.toBeNull()
    expect(document.querySelector(`.react-flow__controls button[aria-label="${msg['processDiagram.a11y.fitView']}"]`)).not.toBeNull()
    expect(document.body.textContent).toContain(msg['processDiagram.edit.a11y.node'])
    if (loc !== 'en') {
      expect(document.body.textContent).not.toContain('Press Enter to select a node')
      expect(document.querySelector('button[aria-label="zoom in"]')).toBeNull()
    }
  })

  it('K6 every toolbar control has an accessible name', () => {
    renderEditor()
    const tb = screen.getByRole('toolbar', { name: 'Diagram editing' })
    for (const b of within(tb).getAllByRole('button')) expect(b).toHaveAccessibleName()
    expect(within(tb).getByRole('button', { name: 'Undo' })).toBeDisabled()
  })

  it('K7/K8 the connection rows edit a condition and delete a connection without a pointer', () => {
    renderEditor()
    openNode('review')
    const rows = screen.getAllByTestId('edit-connection-row')
    expect(rows).toHaveLength(2)
    fireEvent.click(within(rows[1]).getByTestId('edit-connection-edit')) // review → call
    fireEvent.change(screen.getByTestId('edit-field-condition'), { target: { value: 'a > 5' } })
    expect(latest.graph.edges.find((e) => e.id === 'e2')?.condition).toBe('a > 5')
    fireEvent.click(screen.getByTestId('edit-field-default'))
    expect(latest.graph.edges.find((e) => e.id === 'e2')?.is_default).toBe(true)
    fireEvent.click(screen.getByTestId('edit-delete-edge'))
    expect(latest.graph.edges.map((e) => e.id)).toEqual(['e1', 'e3'])
  })

  it('K9 under the narrow width the step list edits and deletes connections', () => {
    width = 400
    renderEditor()
    expect(screen.queryByTestId('diagram-canvas')).toBeNull()
    const steps = screen.getAllByTestId('edit-step')
    expect(steps).toHaveLength(4)
    const row = within(steps[1]).getAllByTestId('edit-step-connection')[0]
    fireEvent.click(within(row).getByTestId('edit-step-connection-edit'))
    expect(screen.getByTestId('edit-edge-panel')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('edit-delete-edge'))
    expect(latest.graph.edges.map((e) => e.id)).toEqual(['e1', 'e3'])
    const again = within(screen.getAllByTestId('edit-step')[0]).getByTestId('edit-step-connection-delete')
    fireEvent.click(again)
    expect(latest.graph.edges.map((e) => e.id)).toEqual(['e3'])
  })

  it('E3/E4/E5 violations mark the node and the edge with a glyph and a word; a list item selects the node', () => {
    renderEditor({
      check: { phase: 'invalid', violations: [] },
      violations: [
        { code: 'missing_role', message: "Node 'review' (HUMAN_TASK) is missing a non-empty 'role' attribute." },
        { code: 'dangling_edge', message: "Edge 'e2' has dangling target 'ghost'" },
        { code: 'missing_end_node', message: 'Graph must have an END node' },
      ],
    })
    const marker = within(document.querySelector('.react-flow__node[data-id="review"]') as HTMLElement).getByTestId('diagram-node-invalid')
    expect(marker).toHaveTextContent('1 problem')
    expect(document.querySelector('.react-flow__node[data-id="call"] [data-testid="diagram-node-invalid"]')).toBeNull()
    expect(screen.getAllByTestId('edit-violation')).toHaveLength(3)
    expect(screen.getByTestId('edit-check-status')).toHaveTextContent('3 problems')
    fireEvent.click(screen.getAllByTestId('edit-violation')[0])
    expect(screen.getByTestId('edit-node-problems')).toHaveTextContent("missing a non-empty 'role'")
    fireEvent.click(screen.getAllByTestId('edit-violation')[1])
    expect(screen.getByTestId('edit-edge-problems')).toHaveTextContent('dangling target')
  })

  it('P1/P2/P3 label and flat attributes edit one key each; structured attributes survive', () => {
    renderEditor()
    openNode('review')
    fireEvent.change(screen.getByTestId('edit-field-label'), { target: { value: 'Check order' } })
    fireEvent.change(screen.getByTestId('edit-field-role'), { target: { value: 'HEAD' } })
    const n = latest.graph.nodes.find((x) => x.id === 'review')!
    expect(n.label).toBe('Check order')
    const a = readAttrs(n)
    expect(a.role).toBe('HEAD')
    expect(a.form_schema).toEqual({ properties: { a: {} } })
    expect(a.mystery).toBe(1)
    expect(typeof n.attributes).toBe('object') // never a JSON string
    // one burst of keystrokes = one undo step
    expect(latest.canUndo).toBe(true)
  })

  it('P5 script binding: a key prefills version 1, clearing it removes both; a service binding is replaced explicitly', () => {
    renderEditor({
      seed: {
        ...GRAPH,
        nodes: GRAPH.nodes.map((n) => (n.id === 'call' ? { ...n, attributes: { service_id: 'erp', position: { x: 0, y: 320 } } } : n)),
      },
    })
    openNode('call')
    expect(screen.getByTestId('edit-service-bound')).toBeInTheDocument()
    expect(screen.queryByTestId('edit-field-script-key')).toBeNull()
    fireEvent.click(screen.getByTestId('edit-use-script'))
    let a = readAttrs(latest.graph.nodes.find((x) => x.id === 'call')!)
    expect(a).toMatchObject({ script_key: 'new_script', script_version: 1 })
    expect('service_id' in a).toBe(false)
    expect(latest.canUndo).toBe(true)
    fireEvent.change(screen.getByTestId('edit-field-script-key'), { target: { value: 'calc' } })
    expect(readAttrs(latest.graph.nodes.find((x) => x.id === 'call')!)).toMatchObject({ script_key: 'calc', script_version: 1 })
    fireEvent.change(screen.getByTestId('edit-field-script-key'), { target: { value: 'Bad Key' } })
    expect(screen.getByText(/Lower-case letters/)).toBeInTheDocument()
    fireEvent.change(screen.getByTestId('edit-field-script-key'), { target: { value: '' } })
    a = readAttrs(latest.graph.nodes.find((x) => x.id === 'call')!)
    expect('script_key' in a || 'script_version' in a).toBe(false)
  })

  it('P4 timer duration, assignee and sub-process name are edited per type', () => {
    renderEditor({
      seed: {
        nodes: [
          node('start', 'START', null, null, 0, 0),
          node('t', 'TIMER', 'Wait', null, 0, 100),
          node('s', 'SUB_PROCESS', 'Child', null, 0, 200),
          node('end', 'END', null, null, 0, 300),
        ],
        edges: [],
      },
    })
    openNode('t')
    fireEvent.change(screen.getByTestId('edit-field-duration'), { target: { value: 'PT5M' } })
    expect(readAttrs(latest.graph.nodes.find((x) => x.id === 't')!).duration_iso8601).toBe('PT5M')
    openNode('s')
    fireEvent.change(screen.getByTestId('edit-field-sub-definition'), { target: { value: 'child_flow' } })
    expect(readAttrs(latest.graph.nodes.find((x) => x.id === 's')!).definition_name).toBe('child_flow')
  })
})
