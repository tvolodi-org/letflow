// @vitest-environment node
/** T-1520 read-only layout (L1..L6). L1 uses the shipped definitions of `priv/modules/*\/pack.json`, normalised to
 *  the API shape (`attributes` as a JSON string, `label` null). */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'
import type { DefinitionGraph, NodeType } from '@/types/api'
import { CAPTION_HEIGHT, COMPACT_SHAPE, initialViewport, isChain, layoutDefinition, visibleShare } from '../readLayout'

const REPO = join(__dirname, '..', '..', '..', '..', '..')

function shippedGraphs(): DefinitionGraph[] {
  const out: DefinitionGraph[] = []
  for (const rel of fg.sync('priv/modules/*/pack.json', { cwd: REPO })) {
    const pack = JSON.parse(readFileSync(join(REPO, rel), 'utf8')) as { definitions?: { graph?: { nodes: unknown[]; edges: unknown[] } }[] }
    for (const d of pack.definitions ?? []) {
      if (!d.graph) continue
      out.push({
        nodes: (d.graph.nodes as { id: string; node_type: NodeType; attributes?: unknown }[]).map((n) => ({
          id: n.id,
          node_type: n.node_type,
          label: null,
          attributes: n.attributes === undefined ? null : JSON.stringify(n.attributes),
        })),
        edges: d.graph.edges as DefinitionGraph['edges'],
      })
    }
  }
  return out
}

const overlaps = (a: { x: number; y: number; width: number; height: number }, b: typeof a) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height

const g = (nodes: [string, NodeType][], edges: [string, string][]): DefinitionGraph => ({
  nodes: nodes.map(([id, node_type]) => ({ id, node_type, label: id, attributes: null })),
  edges: edges.map(([source, target], i) => ({ id: `e${i}`, source, target })),
})

describe('layoutDefinition', () => {
  it('L1 shipped definitions: every node placed, no overlapping boxes, ranks follow edges', () => {
    const graphs = shippedGraphs()
    expect(graphs.length).toBeGreaterThan(0)
    for (const graph of graphs) {
      const l = layoutDefinition(graph, 'TB')
      expect(l.nodes).toHaveLength(graph.nodes.length)
      expect(l.droppedEdges).toBe(0)
      for (let i = 0; i < l.nodes.length; i++) {
        for (let j = i + 1; j < l.nodes.length; j++) expect(overlaps(l.nodes[i], l.nodes[j])).toBe(false)
      }
      const at = new Map(l.nodes.map((n) => [n.id, n]))
      for (const e of l.edges) expect(at.get(e.target)!.y).toBeGreaterThan(at.get(e.source)!.y)
      for (const n of l.nodes) {
        expect(Number.isInteger(n.x) && Number.isInteger(n.y)).toBe(true)
        if (n.nodeType === 'HUMAN_TASK') expect(typeof n.attributes).toBe('object')
      }
    }
  })

  it('L2 empty graph', () => {
    expect(layoutDefinition({ nodes: [], edges: [] })).toMatchObject({ nodes: [], edges: [], width: 0, height: 0 })
    expect(layoutDefinition(null).nodes).toEqual([])
  })

  it('L3 a cycle and a disconnected island are laid out', () => {
    const l = layoutDefinition(
      g(
        [['s', 'START'], ['a', 'HUMAN_TASK'], ['x', 'EXCLUSIVE_GATEWAY'], ['island', 'SERVICE_TASK']],
        [['s', 'a'], ['a', 'x'], ['x', 'a']],
      ),
    )
    expect(l.nodes).toHaveLength(4)
    expect(l.edges).toHaveLength(3)
  })

  it('L4 an edge to a missing node is dropped and counted; duplicate node ids keep the first', () => {
    const graph = g([['s', 'START'], ['a', 'HUMAN_TASK'], ['a', 'END']], [['s', 'a'], ['a', 'ghost']])
    const l = layoutDefinition(graph)
    expect(l.nodes.map((n) => n.id)).toEqual(['s', 'a'])
    expect(l.nodes[1].nodeType).toBe('HUMAN_TASK')
    expect(l.edges).toHaveLength(1)
    expect(l.droppedEdges).toBe(1)
  })

  it('L5 a persisted editor position is ignored; malformed attributes read as {}', () => {
    const graph = g([['s', 'START'], ['a', 'HUMAN_TASK']], [['s', 'a']])
    graph.nodes[1].attributes = JSON.stringify({ position: { x: 9999, y: 9999 }, role: 'CLERK' })
    graph.nodes[0].attributes = '{not json'
    const l = layoutDefinition(graph)
    expect(l.nodes[1].x).toBeLessThan(1000)
    expect(l.nodes[1].attributes.role).toBe('CLERK')
    expect(l.nodes[0].attributes).toEqual({})
  })

  it('L6 LR and TB change the primary axis; a chain is detected', () => {
    const graph = g([['s', 'START'], ['a', 'HUMAN_TASK'], ['e', 'END']], [['s', 'a'], ['a', 'e']])
    const tb = layoutDefinition(graph, 'TB')
    const lr = layoutDefinition(graph, 'LR')
    expect(tb.height).toBeGreaterThan(tb.width)
    expect(lr.width).toBeGreaterThan(lr.height)
    expect(isChain(graph)).toBe(true)
    expect(isChain(g([['s', 'START'], ['a', 'HUMAN_TASK'], ['b', 'HUMAN_TASK']], [['s', 'a'], ['s', 'b']]))).toBe(false)
  })

  // The purchase-request shape of the harness: the default edge amount → order skips the parallel block.
  const purchase = (): DefinitionGraph => {
    const graph = g(
      [
        ['start', 'START'], ['submit', 'HUMAN_TASK'], ['amount', 'EXCLUSIVE_GATEWAY'], ['fork', 'PARALLEL_GATEWAY'],
        ['head', 'HUMAN_TASK'], ['finance', 'HUMAN_TASK'], ['join', 'PARALLEL_GATEWAY'], ['wait', 'TIMER'],
        ['order', 'SUB_PROCESS'], ['end', 'END'],
      ],
      [
        ['start', 'submit'], ['submit', 'amount'], ['amount', 'fork'], ['amount', 'order'], ['fork', 'head'], ['fork', 'finance'],
        ['head', 'join'], ['finance', 'join'], ['join', 'wait'], ['wait', 'order'], ['order', 'end'],
      ],
    )
    graph.edges[2].condition = 'amount > 100000'
    graph.edges[3].is_default = true
    return graph
  }
  const label = (e: { condition?: string; isDefault: boolean }) => e.condition ?? (e.isDefault ? 'default' : null)
  const inside = (p: { x: number; y: number }, b: { x: number; y: number; width: number; height: number }) =>
    p.x > b.x && p.x < b.x + b.width && p.y > b.y && p.y < b.y + b.height

  it('L7 a compact box holds its caption; edge labels sit clear of every node box (TB and LR)', () => {
    for (const dir of ['TB', 'LR'] as const) {
      const l = layoutDefinition(purchase(), dir, label)
      const amount = l.nodes.find((n) => n.id === 'amount')!
      expect(amount.shape).toBe(COMPACT_SHAPE.EXCLUSIVE_GATEWAY)
      // Left to right the caption space is kept above the shape too, so the shape lines up with its rank.
      expect(amount.height).toBe(COMPACT_SHAPE.EXCLUSIVE_GATEWAY + (dir === 'LR' ? 2 : 1) * CAPTION_HEIGHT)
      const labelled = l.edges.filter((e) => e.condition || e.isDefault)
      expect(labelled).toHaveLength(2)
      for (const e of labelled) {
        expect(typeof e.labelX).toBe('number')
        const box = { x: e.labelX! - 40, y: e.labelY! - 12, width: 80, height: 24 }
        for (const n of l.nodes) expect(overlaps(box, n)).toBe(false)
      }
      if (dir === 'TB') {
        const e = l.edges.find((x) => x.condition)!
        expect(e.labelY! - 12).toBeGreaterThanOrEqual(amount.y + amount.height)
        expect(e.exitBelowCaption).toBe(true)
        expect(e.points[0]).toEqual({ x: amount.x + amount.width / 2, y: amount.y + amount.height })
      }
    }
  })

  it('L8 an edge that skips ranks is routed around the nodes between its ends', () => {
    for (const dir of ['TB', 'LR'] as const) {
      const l = layoutDefinition(purchase(), dir, label)
      for (const e of l.edges) {
        const others = l.nodes.filter((n) => n.id !== e.source && n.id !== e.target)
        expect(e.points.length).toBeGreaterThanOrEqual(2)
        for (let i = 1; i < e.points.length; i++) {
          const [a, b] = [e.points[i - 1], e.points[i]]
          for (let t = 0; t <= 1; t += 0.1) {
            const p = { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }
            for (const n of others) expect(inside(p, n), `${dir} ${e.id} crosses ${n.id}`).toBe(false)
          }
        }
      }
      const skip = l.edges.find((e) => e.source === 'amount' && e.target === 'order')!
      expect(skip.points.length).toBeGreaterThan(3)
    }
  })

  it('L9 first view: a small drawing is centred at most 1:1; a large one keeps the readable scale and shows its start', () => {
    const small = initialViewport({ width: 400, height: 300 }, { width: 1000, height: 600 }, 0.9)
    expect(small).toEqual({ x: 300, y: 150, zoom: 1 })
    const big = initialViewport({ width: 800, height: 3000 }, { width: 1000, height: 700 }, 0.9)
    expect(big.zoom).toBe(0.9)
    expect(big.y).toBe(24)
    expect(big.x).toBe(Math.round((1000 - 800 * 0.9) / 2))
    const fits = initialViewport({ width: 1100, height: 600 }, { width: 1048, height: 700 }, 0.9)
    expect(fits.zoom).toBeCloseTo(1000 / 1100, 5)
    expect(initialViewport({ width: 0, height: 0 }, { width: 1000, height: 600 }, 0.9)).toEqual({ x: 0, y: 0, zoom: 1 })
    // An active step far to the right is brought into view (centred); one already in view does not move the view.
    const far = initialViewport({ width: 3000, height: 300 }, { width: 1000, height: 600 }, 0.9, true, { x: 2500, y: 100, width: 200, height: 100 })
    expect(far.x).toBe(Math.round(500 - 2600 * 0.9))
    expect(far.y).toBe(24)
    const near = initialViewport({ width: 3000, height: 300 }, { width: 1000, height: 600 }, 0.9, true, { x: 100, y: 100, width: 200, height: 100 })
    expect(near).toEqual({ x: 24, y: 24, zoom: 0.9 })
  })

  it('L10 visibleShare: 1 for a drawing that fits, less for one that is panned at the readable scale', () => {
    const ids = Array.from({ length: 8 }, (_, i) => `t${i}`)
    const graph = g(
      [['s', 'START'], ...ids.map((id) => [id, 'HUMAN_TASK'] as [string, NodeType]), ['e', 'END']],
      [['s', 't0'], ...ids.slice(1).map((id, i) => [`t${i}`, id] as [string, string]), ['t7', 'e']],
    )
    const canvas = { width: 1100, height: 700 }
    expect(visibleShare({ width: 500, height: 400 }, canvas, 0.9)).toBe(1)
    const lr = layoutDefinition(graph, 'LR')
    const share = visibleShare(lr, canvas, 0.9)
    expect(share).toBeLessThan(1)
    expect(share).toBeCloseTo((1100 - 48) / (lr.width * 0.9), 5)
  })

})
