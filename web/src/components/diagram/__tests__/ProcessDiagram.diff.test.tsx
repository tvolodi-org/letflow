// @vitest-environment jsdom
/** T-1588 D1: in a version diff every added / removed / changed step and connection carries a word AND a glyph, the
 *  glyph shape differs per kind (dot / dash / half), and the step list shows the words too. Real React Flow. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, within } from '@testing-library/react'
import type { DefinitionGraph } from '@/types/api'
import ProcessDiagram from '../ProcessDiagram'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { diffGraphs } from '@/utils/canvas/graphDiff'
expect.extend(jestDomMatchers)

class RO {
  constructor(private cb: ResizeObserverCallback) {}
  observe(el: Element) {
    this.cb([{ contentRect: { width: 1200, height: 600 }, target: el } as unknown as ResizeObserverEntry], this as unknown as ResizeObserver)
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
  vi.stubGlobal('ResizeObserver', RO)
  vi.stubGlobal('DOMMatrixReadOnly', DOMMatrixRO)
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const FROM: DefinitionGraph = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'a', node_type: 'HUMAN_TASK', label: 'Review', attributes: { role: 'clerk' } },
    { id: 'old', node_type: 'HUMAN_TASK', label: 'Old step', attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [
    { id: 'e_1', source: 'start', target: 'a' },
    { id: 'e_2', source: 'a', target: 'old' },
    { id: 'e_3', source: 'old', target: 'end', condition: 'x > 1' },
  ],
}
const TO: DefinitionGraph = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'a', node_type: 'HUMAN_TASK', label: 'Review', attributes: { role: 'boss' } },
    { id: 'new', node_type: 'HUMAN_TASK', label: 'New step', attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [
    { id: 'e_1', source: 'start', target: 'a', condition: 'y' },
    { id: 'e_2', source: 'a', target: 'new' },
    { id: 'e_4', source: 'new', target: 'end' },
  ],
}

function renderDiff(initialMode?: 'steps') {
  const diff = diffGraphs(FROM, TO)
  return render(
    <ProcessDiagramIntlProvider>
      <ProcessDiagram graph={diff.graph} diff={diff} initialMode={initialMode} />
    </ProcessDiagramIntlProvider>,
  )
}

describe('ProcessDiagram version diff', () => {
  it('D1 steps carry a word and a glyph; the glyph kind differs per kind', () => {
    renderDiff()
    const pills = screen.getAllByTestId('diagram-node-diff')
    const byKind = Object.fromEntries(pills.map((p) => [p.getAttribute('data-diff'), p]))
    expect(Object.keys(byKind).sort()).toEqual(['added', 'changed', 'removed'])
    expect(byKind.added).toHaveTextContent('Added')
    expect(byKind.removed).toHaveTextContent('Removed')
    expect(byKind.changed).toHaveTextContent('Changed')
    const glyph = (el: HTMLElement) => within(el).getByTestId('diagram-diff-glyph').className
    expect(glyph(byKind.added)).toBe('lf-glyph')
    expect(glyph(byKind.removed)).toContain('lf-glyph--dash')
    expect(glyph(byKind.changed)).toContain('lf-glyph--half')
  })

  it('V3 the step carries its word in the accessible name', () => {
    renderDiff()
    expect(screen.getByLabelText(/New step.*Added/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Old step.*Removed/)).toBeInTheDocument()
  })

  it('V4 changed, added and removed connections show a chip with a word and a glyph', () => {
    renderDiff()
    const chips = screen.getAllByTestId('diagram-edge-diff')
    expect(chips.map((c) => c.getAttribute('data-diff')).sort()).toEqual(['added', 'added', 'changed', 'removed', 'removed'])
    for (const c of chips) {
      expect(c.textContent?.trim()).toMatch(/Added|Removed|Changed/)
      expect(within(c).getByTestId('diagram-diff-glyph')).toBeInTheDocument()
    }
  })

  it('D1 the step list shows the words for steps and connections', () => {
    renderDiff('steps')
    expect(screen.getAllByTestId('steps-node-diff').map((x) => x.textContent).sort()).toEqual(['Added', 'Changed', 'Removed'])
    expect(screen.getAllByTestId('steps-edge-diff').length).toBe(5)
  })
})
