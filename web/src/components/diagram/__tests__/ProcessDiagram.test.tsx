// @vitest-environment jsdom
/** T-1520 ProcessDiagram: N1 shapes per type, N2 state class + glyph + word, N3 details panel content, C1/C2 controls
 *  and minimap, K1..K3 keyboard and step list, W1 narrow fallback. The real React Flow renders; jsdom has no layout,
 *  so ResizeObserver is stubbed to report a chosen container width. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import type { DefinitionGraph, NodeType } from '@/types/api'
import ProcessDiagram from '../ProcessDiagram'
import { IntlProvider } from 'react-intl'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'
import { NODE_TYPES } from '../diagramConfig'
import { summariseNode } from '../nodeSummary'
import { basisPath } from '../DiagramEdge'
import { deriveInstancePath, timelineEvidence } from '@/utils/canvas/instancePath'
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

// React Flow reads the viewport transform through DOMMatrixReadOnly and element sizes through offsetWidth/Height.
class DOMMatrixRO {
  m22: number
  constructor(transform?: string) {
    const scale = transform?.match(/scale\(([0-9.]+)\)/)?.[1]
    this.m22 = scale !== undefined ? Number(scale) : 1
  }
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
  vi.unstubAllGlobals()
})

const node = (id: string, node_type: NodeType, attributes: object | null = null, label: string | null = id) => ({
  id,
  node_type,
  label,
  attributes: attributes === null ? null : JSON.stringify(attributes),
})

const ALL_TYPES: DefinitionGraph = {
  nodes: [
    node('start', 'START', null, null),
    node('review', 'HUMAN_TASK', {
      role: 'CLERK',
      form_schema: { properties: { amount: { title: 'Amount' }, note: {} } },
      distinct_from: ['approve'],
      module_writes: [{ handler: 'post_document', args: { secret: { var: 'x' } } }],
      mystery: 'hidden value',
    }),
    node('call', 'SERVICE_TASK', { endpoint: 'https://api.example.test/hook?token=abc', service_id: 'erp' }),
    node('decide', 'EXCLUSIVE_GATEWAY'),
    node('fork', 'PARALLEL_GATEWAY'),
    node('wait', 'TIMER', { duration_iso8601: 'PT15M' }),
    node('child', 'SUB_PROCESS', { definition_name: 'child_flow' }),
    node('approve', 'HUMAN_TASK'),
    node('end', 'END', null, null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'review' },
    { id: 'e2', source: 'review', target: 'call' },
    { id: 'e3', source: 'call', target: 'decide' },
    { id: 'e4', source: 'decide', target: 'fork', condition: 'amount > 100' },
    { id: 'e5', source: 'decide', target: 'end', is_default: true },
    { id: 'e6', source: 'fork', target: 'wait' },
    { id: 'e7', source: 'fork', target: 'child' },
    { id: 'e8', source: 'wait', target: 'approve' },
    { id: 'e9', source: 'child', target: 'approve' },
    { id: 'e10', source: 'approve', target: 'end' },
  ],
}

function renderDiagram(props: Partial<React.ComponentProps<typeof ProcessDiagram>> = {}) {
  return render(
    <ProcessDiagramIntlProvider>
      <div style={{ width: 1200, height: 700 }}>
        <ProcessDiagram graph={ALL_TYPES} {...props} />
      </div>
    </ProcessDiagramIntlProvider>,
  )
}

describe('ProcessDiagram', () => {
  it('N1 one shape class per node type, for all eight types', () => {
    renderDiagram()
    for (const t of NODE_TYPES) {
      const el = screen.getAllByTestId(`diagram-node-${t}`)[0]
      expect(el.className).toContain(`lf-pd-node--${t.toLowerCase().replace(/_/g, '-')}`)
    }
    expect(screen.getAllByTestId('diagram-edge-label').map((e) => e.textContent)).toEqual(expect.arrayContaining(['amount > 100', 'default']))
  })

  it('N2 an instance state is a class, a glyph and a word', () => {
    const path = deriveInstancePath(
      ALL_TYPES,
      { status: 'ACTIVE', current_nodes: ['call'] },
      timelineEvidence(
        [{ event_id: 'a', event_type: 'TASK_COMPLETED', node_id: 'review', sequence_num: 1 } as never],
        { complete: true },
      ),
    )
    renderDiagram({ path })
    const review = screen.getByTestId('diagram-node-SERVICE_TASK')
    expect(review).toHaveAttribute('data-state', 'active')
    expect(review.className).toContain('is-active')
    const pill = within(review).getByTestId('diagram-node-state')
    expect(pill).toHaveTextContent('Active')
    expect(pill.querySelector('.lf-glyph')).not.toBeNull()
    expect(screen.getAllByTestId('diagram-node-HUMAN_TASK')[0]).toHaveAttribute('data-state', 'done')
  })

  it('N3 the details panel shows only known keys, endpoint host only, handler names, labels for distinct_from', async () => {
    renderDiagram({ graph: ALL_TYPES })
    fireEvent.click(screen.getByTestId('diagram-mode-steps'))
    fireEvent.click(screen.getByRole('button', { name: 'review' }))
    const panel = screen.getByTestId('diagram-node-details')
    expect(panel).toHaveTextContent('Form: 2 fields')
    expect(panel).toHaveTextContent('Amount')
    expect(panel).toHaveTextContent('post_document')
    expect(panel).toHaveTextContent('Must differ fromapprove')
    expect(panel).toHaveTextContent('1 other attributes')
    expect(panel).not.toHaveTextContent('hidden value')
    expect(panel).not.toHaveTextContent('secret')
    const s = summariseNode('SERVICE_TASK', { endpoint: 'https://api.example.test/hook?token=abc', service_id: 'erp' })
    expect(s.endpointHost).toBe('https://api.example.test')
    expect(summariseNode('SERVICE_TASK', { endpoint: 'not a url' }).endpointHost).toBeNull()
  })

  it('C1 controls and minimap are rendered; C2 minimap off above 150 nodes', () => {
    const { container, unmount } = renderDiagram()
    expect(container.querySelector('.react-flow__controls')).not.toBeNull()
    expect(container.querySelector('.react-flow__minimap')).not.toBeNull()
    unmount()
    const big: DefinitionGraph = {
      nodes: Array.from({ length: 160 }, (_, i) => node(`n${i}`, 'HUMAN_TASK')),
      edges: Array.from({ length: 159 }, (_, i) => ({ id: `e${i}`, source: `n${i}`, target: `n${i + 1}` })),
    }
    const r = renderDiagram({ graph: big })
    expect(r.container.querySelector('.react-flow__minimap')).toBeNull()
    expect(r.container.querySelector('.react-flow__controls')).not.toBeNull()
  })

  it('K1 nodes are focusable with label, type and state in their name', () => {
    const path = deriveInstancePath(ALL_TYPES, { status: 'ACTIVE', current_nodes: ['review'] }, timelineEvidence([], { complete: true }))
    const { container } = renderDiagram({ path })
    const el = container.querySelector('.react-flow__node[data-id="review"]') as HTMLElement
    expect(el).toHaveAttribute('tabindex', '0')
    expect(el.getAttribute('aria-label')).toBe('review, User task, Active')
  })

  it('K2 Enter on a focused node opens the details panel, Escape closes it', () => {
    const { container } = renderDiagram()
    const el = container.querySelector('.react-flow__node[data-id="call"]') as HTMLElement
    act(() => el.focus())
    fireEvent.keyDown(el, { key: 'Enter' })
    expect(screen.getByTestId('diagram-node-details')).toHaveTextContent('erp')
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(screen.queryByTestId('diagram-node-details')).toBeNull()
  })

  it('K3 the steps list lists every node with its outgoing connections', () => {
    renderDiagram()
    fireEvent.click(screen.getByTestId('diagram-mode-steps'))
    const steps = screen.getAllByTestId('diagram-step')
    expect(steps).toHaveLength(ALL_TYPES.nodes.length)
    expect(steps[0]).toHaveAttribute('data-node-id', 'start')
    expect(screen.getByTestId('diagram-steps')).toHaveTextContent('if amount > 100')
  })

  it('W1 a 390 px container shows the steps list and no canvas', () => {
    width = 390
    renderDiagram()
    expect(screen.getByTestId('diagram-steps')).toBeInTheDocument()
    expect(screen.queryByTestId('diagram-canvas')).toBeNull()
    expect(screen.getByTestId('process-diagram')).toHaveAttribute('data-width-class', 'narrow')
  })

  it('W2 under 900 px a chosen step opens its details in place of the list; closing returns to the list', () => {
    width = 390
    renderDiagram()
    fireEvent.click(screen.getByRole('button', { name: 'call' }))
    expect(screen.getByTestId('diagram-node-details')).toHaveTextContent('erp')
    expect(screen.queryByTestId('diagram-steps')).toBeNull()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(screen.queryByTestId('diagram-node-details')).toBeNull()
    expect(screen.getByTestId('diagram-steps')).toBeInTheDocument()
  })

  it('empty graph and missing graph have their own empty states', () => {
    const { unmount } = renderDiagram({ graph: { nodes: [], edges: [] } })
    expect(screen.getByTestId('diagram-empty')).toBeInTheDocument()
    unmount()
    renderDiagram({ graph: null })
    expect(screen.getByTestId('diagram-no-graph')).toBeInTheDocument()
  })

  it('A1 React Flow screen-reader texts come from the catalog in every language, worded for a read-only view', () => {
    for (const locale of ['en', 'ru', 'kk'] as const) {
      const msg = processDiagramMessages[locale]
      const { container, unmount } = render(
        <IntlProvider locale={locale} defaultLocale="en" messages={msg}>
          <div style={{ width: 1200, height: 700 }}>
            <ProcessDiagram graph={ALL_TYPES} />
          </div>
        </IntlProvider>,
      )
      const text = container.textContent ?? ''
      expect(text).toContain(msg['processDiagram.a11y.node'])
      expect(text).not.toMatch(/Press delete|remove it/)
      expect(container.querySelector(`[aria-label="${msg['processDiagram.a11y.zoomIn']}"]`)).not.toBeNull()
      expect(container.querySelector(`[aria-label="${msg['processDiagram.a11y.fitView']}"]`)).not.toBeNull()
      expect(container.querySelector(`[aria-label="${msg['processDiagram.a11y.controls']}"]`)).not.toBeNull()
      // The minimap names itself through an SVG <title>.
      expect(container.querySelector('.react-flow__minimap title')?.textContent).toBe(msg['processDiagram.a11y.minimap'])
      expect(container.querySelector('[aria-label="Zoom In"], [aria-label="Control Panel"]')).toBeNull()
      expect(text).not.toContain('Mini Map')
      unmount()
    }
  })

  it('R1 an edge route is drawn as one smooth curve from the first to the last point', () => {
    const d = basisPath([{ x: 0, y: 0 }, { x: 0, y: 50 }, { x: 100, y: 100 }, { x: 100, y: 150 }])
    expect(d.startsWith('M0,0')).toBe(true)
    expect(d.endsWith('L100,150')).toBe(true)
    expect(d.match(/C/g)).toHaveLength(3)
    expect(basisPath([{ x: 1, y: 2 }, { x: 3, y: 4 }])).toBe('M1,2L3,4')
    expect(basisPath([])).toBe('')
  })
})
