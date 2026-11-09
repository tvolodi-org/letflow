// @vitest-environment node
/** T-1520 read-only layout (L1..L6). L1 uses the shipped definitions of `priv/modules/*\/pack.json`, normalised to
 *  the API shape (`attributes` as a JSON string, `label` null). */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'
import type { DefinitionGraph, NodeType } from '@/types/api'
import { isChain, layoutDefinition } from '../readLayout'

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
})
