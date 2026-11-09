/** T-1588 graphDiff: G1 added step, G2 removed step, G3 changed step, G4 merged graph holds both sides, G5 position
 *  and attribute key order are not changes, G6..G9 connections, G10 reused edge id with new endpoints, G11 several
 *  connections with the same endpoints. */
import { describe, expect, it } from 'vitest'
import type { DefinitionGraph, GraphEdge, GraphNode } from '@/types/api'
import { diffGraphs } from '../graphDiff'

const n = (id: string, node_type: GraphNode['node_type'] = 'HUMAN_TASK', label: string | null = id, attributes: GraphNode['attributes'] = null): GraphNode => ({
  id,
  node_type,
  label,
  attributes,
})
const e = (id: string, source: string, target: string, extra: Partial<GraphEdge> = {}): GraphEdge => ({ id, source, target, ...extra })
const g = (nodes: GraphNode[], edges: GraphEdge[] = []): DefinitionGraph => ({ nodes, edges })

const BASE = g([n('s', 'START'), n('a'), n('z', 'END')], [e('e_1', 's', 'a'), e('e_2', 'a', 'z')])

describe('diffGraphs', () => {
  it('G1 a step only in `to` is added', () => {
    const d = diffGraphs(BASE, g([...BASE.nodes, n('b')], BASE.edges))
    expect(d.nodes.get('b')?.kind).toBe('added')
    expect(d.counts.nodes).toEqual({ added: 1, removed: 0, changed: 0 })
  })

  it('G2 a step only in `from` is removed and stays in the merged graph', () => {
    const d = diffGraphs(g([...BASE.nodes, n('b')]), BASE)
    expect(d.nodes.get('b')?.kind).toBe('removed')
    expect(d.graph.nodes.map((x) => x.id)).toContain('b')
  })

  it('G3 label, type and attribute changes name the fields, not the values', () => {
    const from = g([n('a', 'HUMAN_TASK', 'Review', { role: 'clerk', note: 'x' })])
    const to = g([n('a', 'SERVICE_TASK', 'Check', { role: 'boss', note: 'x', extra: 1 })])
    const d = diffGraphs(from, to)
    expect(d.nodes.get('a')).toEqual({ kind: 'changed', fields: ['node_type', 'label', 'extra', 'role'] })
    expect(JSON.stringify([...d.nodes.values()])).not.toContain('boss')
  })

  it('G4 the merged graph holds every step of both versions once', () => {
    const d = diffGraphs(g([n('a'), n('old')]), g([n('a'), n('new')]))
    expect(d.graph.nodes.map((x) => x.id).sort()).toEqual(['a', 'new', 'old'])
  })

  it('G5 position, key order and the legacy string form are not changes; null graphs are empty', () => {
    const from = g([n('a', 'HUMAN_TASK', 'a', { role: 'r', position: { x: 1, y: 1 }, form: { b: 1, a: 2 } })])
    const to = g([n('a', 'HUMAN_TASK', 'a', JSON.stringify({ form: { a: 2, b: 1 }, role: 'r', position: { x: 9, y: 9 } }))])
    expect(diffGraphs(from, to).nodes.get('a')?.kind).toBe('unchanged')
    const empty = diffGraphs(null, undefined)
    expect(empty.graph).toEqual({ nodes: [], edges: [] })
  })

  it('G6 a new connection is added', () => {
    const d = diffGraphs(BASE, g(BASE.nodes, [...BASE.edges, e('e_3', 's', 'z')]))
    expect(d.counts.edges).toEqual({ added: 1, removed: 0, changed: 0 })
  })

  it('G7 a deleted connection is removed and kept in the merged graph', () => {
    const d = diffGraphs(BASE, g(BASE.nodes, [BASE.edges[0]]))
    expect(d.counts.edges).toEqual({ added: 0, removed: 1, changed: 0 })
    expect(d.graph.edges).toHaveLength(2)
  })

  it('G8 a changed condition or default flag is a changed connection', () => {
    const from = g(BASE.nodes, [e('e_1', 's', 'a', { condition: 'x > 1' }), e('e_2', 'a', 'z')])
    const to = g(BASE.nodes, [e('e_1', 's', 'a', { condition: 'x > 2' }), e('e_2', 'a', 'z', { is_default: true })])
    const d = diffGraphs(from, to)
    expect(d.counts.edges.changed).toBe(2)
    expect([...d.edges.values()].map((x) => x.fields).sort()).toEqual([['condition'], ['is_default']])
  })

  it('G9 regenerated edge ids with the same endpoints are unchanged', () => {
    const d = diffGraphs(BASE, g(BASE.nodes, [e('x1', 's', 'a'), e('x2', 'a', 'z')]))
    expect(d.counts.edges).toEqual({ added: 0, removed: 0, changed: 0 })
    expect(d.graph.edges).toHaveLength(2)
  })

  it('G10 a reused edge id with other endpoints is one removed plus one added, with distinct diagram ids', () => {
    const from = g(BASE.nodes, [e('e_1', 's', 'a')])
    const to = g(BASE.nodes, [e('e_1', 'a', 'z')])
    const d = diffGraphs(from, to)
    expect(d.counts.edges).toEqual({ added: 1, removed: 1, changed: 0 })
    const ids = d.graph.edges.map((x) => x.id)
    expect(new Set(ids).size).toBe(2)
    expect([...d.edges.values()].map((x) => x.origin.fromId ?? x.origin.toId)).toEqual(['e_1', 'e_1'])
    expect(d.graph.edges.find((x) => d.edges.get(x.id)?.kind === 'removed')).toMatchObject({ source: 's', target: 'a' })
  })

  it('G11 several connections with the same endpoints pair in order; leftovers are removed or added', () => {
    const from = g(BASE.nodes, [e('p', 's', 'a', { condition: 'c1' }), e('q', 's', 'a', { condition: 'c2' })])
    const same = diffGraphs(from, g(BASE.nodes, [e('r', 's', 'a', { condition: 'c2' }), e('t', 's', 'a', { condition: 'c1' })]))
    expect(same.counts.edges).toEqual({ added: 0, removed: 0, changed: 0 })
    const more = diffGraphs(from, g(BASE.nodes, [e('r', 's', 'a', { condition: 'c1' })]))
    expect(more.counts.edges.removed).toBe(1)
    const fewer = diffGraphs(g(BASE.nodes, [e('r', 's', 'a', { condition: 'c1' })]), from)
    expect(fewer.counts.edges.added).toBe(1)
  })
})
