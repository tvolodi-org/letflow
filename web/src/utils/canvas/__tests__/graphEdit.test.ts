import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import type { DefinitionGraph, GraphNode } from '@/types/api'
import {
  MAX_EDGES, MAX_NODES, SCRIPT_KEY_RE, addNode, connect, connectionRefusal, deleteEdges, deleteNodes, hasServiceBinding,
  moveNode, nextDraftVersion, positionOf, readAttrs, replaceServiceWithScript, scriptBindingHint, setEdge, setNodeAttr,
  setNodeLabel, setScriptBinding,
} from '../graphEdit'

const root = resolve(__dirname, '../../../../..')
const fixture = (name: string) => JSON.parse(readFileSync(resolve(root, 'test/fixtures/process_designer', name), 'utf8'))

const attrs = (o: object) => o as unknown as GraphNode['attributes']
const base = (): DefinitionGraph => ({
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    {
      id: 'task', node_type: 'HUMAN_TASK', label: 'Review',
      attributes: attrs({ role: 'approver', form_schema: { a: [1, 2] }, module_writes: ['x'], interface: { i: 1 }, unknown_key: true }),
    },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'task' }, { id: 'e2', source: 'task', target: 'end' }],
})
const must = (r: ReturnType<typeof addNode>) => { if (!r.ok) throw new Error(r.reason); return r }

describe('graphEdit', () => {
  it('G1 structured keys survive add / move / relabel byte-for-byte', () => {
    const g0 = base()
    const before = JSON.stringify(readAttrs(g0.nodes[1] as GraphNode), ['role', 'form_schema', 'module_writes', 'interface', 'unknown_key', 'a'])
    let g = must(addNode(g0, 'TIMER', { x: 1, y: 2 })).graph
    g = must(moveNode(g, 'task', { x: 10.4, y: 20.6 })).graph
    g = must(setNodeLabel(g, 'task', 'Renamed')).graph
    const task = g.nodes.find((n) => n.id === 'task') as GraphNode
    const { position, ...rest } = readAttrs(task)
    expect(position).toEqual({ x: 10, y: 21 })
    expect(JSON.stringify(rest, ['role', 'form_schema', 'module_writes', 'interface', 'unknown_key', 'a'])).toBe(before)
    expect(g0.nodes[1]?.label).toBe('Review') // input never mutated
  })

  it('G1b reads a JSON-string attributes value and writes an object', () => {
    const g: DefinitionGraph = { nodes: [{ id: 'n', node_type: 'HUMAN_TASK', label: null, attributes: '{"role":"a"}' }], edges: [] }
    const out = must(setNodeAttr(g, 'n', 'role', 'b')).graph.nodes[0] as GraphNode
    expect(typeof out.attributes).toBe('object')
    expect(readAttrs(out).role).toBe('b')
  })

  it('G2 an unparsable attributes string is left unchanged', () => {
    const g: DefinitionGraph = { nodes: [{ id: 'n', node_type: 'HUMAN_TASK', label: null, attributes: '{oops' }], edges: [] }
    expect(must(setNodeAttr(g, 'n', 'role', 'b')).graph.nodes[0]?.attributes).toBe('{oops')
  })

  it('G3 self-loop, duplicate edge, into START and out of END are refused', () => {
    const g = base()
    expect(connectionRefusal(g, 'task', 'task')).toBe('self_loop')
    expect(connectionRefusal(g, 'start', 'task')).toBe('duplicate_edge')
    expect(connectionRefusal(g, 'task', 'start')).toBe('into_start')
    expect(connectionRefusal(g, 'end', 'task')).toBe('out_of_end')
    expect(connect(g, 'start', 'end').ok).toBe(true)
  })

  it('G4 a second START is refused; generated ids never collide', () => {
    let g = base()
    expect(addNode(g, 'START', { x: 0, y: 0 })).toEqual({ ok: false, reason: 'second_start' })
    g = must(addNode(g, 'TIMER', { x: 0, y: 0 })).graph
    const second = must(addNode(g, 'TIMER', { x: 0, y: 0 }))
    expect(new Set(second.graph.nodes.map((n) => n.id)).size).toBe(second.graph.nodes.length)
    expect(must(connect(second.graph, 'start', 'end')).id).toBe('e_1')
  })

  it('G5 deleting nodes drops their edges; START cannot be deleted', () => {
    const g = base()
    const out = must(deleteNodes(g, ['task'])).graph
    expect(out.edges).toEqual([])
    expect(deleteNodes(g, ['start'])).toEqual({ ok: false, reason: 'delete_start' })
    expect(must(deleteEdges(g, ['e1'])).graph.edges.map((e) => e.id)).toEqual(['e2'])
  })

  it('G6 edge condition and default flag set and clear', () => {
    let g = must(setEdge(base(), 'e2', { condition: 'a == 1', is_default: true })).graph
    expect(g.edges[1]).toMatchObject({ condition: 'a == 1', is_default: true })
    g = must(setEdge(g, 'e2', { condition: '', is_default: false })).graph
    expect(g.edges[1]).not.toHaveProperty('condition')
    expect(g.edges[1]).not.toHaveProperty('is_default')
    expect(setEdge(g, 'nope', {})).toEqual({ ok: false, reason: 'unknown_edge' })
  })

  it('G7 caps mirror graph.ex', () => {
    const src = readFileSync(resolve(root, 'lib/letflow/definitions/graph.ex'), 'utf8')
    expect(src).toContain(`@max_nodes ${MAX_NODES}`)
    expect(src).toContain(`@max_edges ${MAX_EDGES}`)
    const v = readFileSync(resolve(root, 'lib/letflow/scripts/validation.ex'), 'utf8')
    expect(v).toContain(SCRIPT_KEY_RE.source)
  })

  it('G8 position round trip and nextDraftVersion', () => {
    const g = must(addNode(base(), 'TIMER', { x: 5, y: 6 }))
    expect(positionOf(g.graph.nodes.find((n) => n.id === g.id) as GraphNode)).toEqual({ x: 5, y: 6 })
    expect(nextDraftVersion('1.0.3')).toBe('1.0.4')
    expect(nextDraftVersion('v9')).toBe('v10')
    expect(nextDraftVersion('beta')).toBe('beta.1')
  })
})

describe('script binding (P5)', () => {
  const svc = (a: object): DefinitionGraph => ({ nodes: [{ id: 's', node_type: 'SERVICE_TASK', label: null, attributes: attrs(a) }], edges: [] })
  const node = (g: DefinitionGraph) => g.nodes[0] as GraphNode

  it('a key alone yields version 1; clearing the key removes both', () => {
    let g = must(setScriptBinding(svc({}), 's', { key: 'calc' })).graph
    expect(readAttrs(node(g))).toMatchObject({ script_key: 'calc', script_version: 1 })
    g = must(setScriptBinding(g, 's', { key: '' })).graph
    expect(node(g).attributes).toBeNull()
  })

  it('replaceServiceWithScript drops service_id and endpoint in one step', () => {
    const g0 = svc({ service_id: 'x', endpoint: 'http://e', timeout_ms: 5 })
    expect(hasServiceBinding(node(g0))).toBe(true)
    const a = readAttrs(node(must(replaceServiceWithScript(g0, 's', 'calc')).graph))
    expect(a).toEqual({ timeout_ms: 5, script_key: 'calc', script_version: 1 })
  })

  it('inline hints', () => {
    expect(scriptBindingHint('Bad Key', 1)).toBe('bad_key')
    expect(scriptBindingHint('calc', 0)).toBe('bad_version')
    expect(scriptBindingHint('calc', 1)).toBeNull()
    expect(scriptBindingHint('', undefined)).toBeNull()
  })

  it('produces exactly the pair the server fixture accepts (shared fixture)', () => {
    const g = must(setScriptBinding(svc({}), 's', { key: 'calc', version: 1 })).graph
    const fx = fixture('edited_graph_script.json') as DefinitionGraph
    expect(readAttrs(node(g))).toEqual(readAttrs(fx.nodes.find((n) => n.node_type === 'SERVICE_TASK') as GraphNode))
  })
})
