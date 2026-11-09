/**
 * graphEdit — T-1563 (process designer, slice 2). Pure, immutable edits of a DefinitionGraph: the definition format is
 * the single source of truth, there is no second canvas model. Every function returns a NEW graph (or a refusal);
 * keys the diagram does not edit (`form_schema`, `module_writes`, `interface`, `distinct_from`, unknown keys) are carried
 * through byte-for-byte. Position lives in `attributes.position {x, y}`, the key `flowToGraph` already writes.
 *
 * Wire note: the server stores `attributes` as an object; the web type says `string | null` and older code writes a JSON
 * string. This module reads both and WRITES an object (what `Graph.from_map` validates).
 */
import type { DefinitionGraph, GraphEdge, GraphNode, NodeType } from '@/types/api'
import { layoutDefinition } from './readLayout'

/** Mirrors `@max_nodes` / `@max_edges` in lib/letflow/definitions/graph.ex (a test pins the numbers to that source). */
export const MAX_NODES = 500
export const MAX_EDGES = 2000

/** Mirrors `Letflow.Scripts.Validation.key?/1` (`^[a-z][a-z0-9_]{0,63}$`); pinned to the Elixir source by a test. */
export const SCRIPT_KEY_RE = /^[a-z][a-z0-9_]{0,63}$/

export type EditRefusal =
  | 'self_loop'
  | 'duplicate_edge'
  | 'into_start'
  | 'out_of_end'
  | 'second_start'
  | 'delete_start'
  | 'too_many_nodes'
  | 'too_many_edges'
  | 'unknown_node'
  | 'unknown_edge'
  | 'saving'

export type EditResult = { ok: true; graph: DefinitionGraph; id?: string } | { ok: false; reason: EditRefusal }

type Attrs = Record<string, unknown>

export function readAttrs(node: GraphNode): Attrs {
  const raw: unknown = node.attributes
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return { ...(raw as Attrs) }
  if (typeof raw === 'string' && raw.trim() !== '') {
    try {
      const parsed: unknown = JSON.parse(raw)
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed as Attrs
    } catch {
      /* not JSON: treated as no attributes by the reader; writers refuse via attributesEditable */
    }
  }
  return {}
}

/** False when `attributes` is a non-empty string that is not a JSON object: the node is shown, its properties are not edited. */
export function attributesEditable(node: GraphNode): boolean {
  const raw: unknown = node.attributes
  if (raw == null || typeof raw === 'object') return true
  if (typeof raw !== 'string' || raw.trim() === '') return true
  try {
    const parsed: unknown = JSON.parse(raw)
    return !!parsed && typeof parsed === 'object' && !Array.isArray(parsed)
  } catch {
    return false
  }
}

function withAttrs(node: GraphNode, attrs: Attrs): GraphNode {
  const out = { ...node, attributes: (Object.keys(attrs).length ? attrs : null) as unknown as GraphNode['attributes'] }
  return out
}

const ok = (graph: DefinitionGraph, id?: string): EditResult => ({ ok: true, graph, id })
const refuse = (reason: EditRefusal): EditResult => ({ ok: false, reason })

function mapNode(g: DefinitionGraph, id: string, f: (n: GraphNode) => GraphNode): EditResult {
  if (!g.nodes.some((n) => n.id === id)) return refuse('unknown_node')
  return ok({ ...g, nodes: g.nodes.map((n) => (n.id === id ? f(n) : n)) })
}

function nextId(prefix: string, taken: Set<string>): string {
  let i = 1
  while (taken.has(`${prefix}${i}`)) i += 1
  return `${prefix}${i}`
}

export function addNode(g: DefinitionGraph, type: NodeType, at: { x: number; y: number }): EditResult {
  if (type === 'START' && g.nodes.some((n) => n.node_type === 'START')) return refuse('second_start')
  if (g.nodes.length >= MAX_NODES) return refuse('too_many_nodes')
  const id = nextId(`n_${type.toLowerCase()}_`, new Set(g.nodes.map((n) => n.id)))
  const node: GraphNode = withAttrs({ id, node_type: type, label: null, attributes: null }, {
    position: { x: Math.round(at.x), y: Math.round(at.y) },
  })
  return ok({ ...g, nodes: [...g.nodes, node] }, id)
}

export function moveNode(g: DefinitionGraph, id: string, to: { x: number; y: number }): EditResult {
  return mapNode(g, id, (n) => withAttrs(n, { ...readAttrs(n), position: { x: Math.round(to.x), y: Math.round(to.y) } }))
}

export function positionOf(node: GraphNode): { x: number; y: number } | null {
  const p = readAttrs(node).position as { x?: unknown; y?: unknown } | undefined
  return p && typeof p.x === 'number' && typeof p.y === 'number' ? { x: p.x, y: p.y } : null
}

/** Why `source → target` may not be drawn, or null when it may. Used by `connect` and by React Flow's isValidConnection. */
export function connectionRefusal(g: DefinitionGraph, source: string, target: string): EditRefusal | null {
  const s = g.nodes.find((n) => n.id === source)
  const t = g.nodes.find((n) => n.id === target)
  if (!s || !t) return 'unknown_node'
  if (source === target) return 'self_loop'
  if (t.node_type === 'START') return 'into_start'
  if (s.node_type === 'END') return 'out_of_end'
  if (g.edges.some((e) => e.source === source && e.target === target)) return 'duplicate_edge'
  if (g.edges.length >= MAX_EDGES) return 'too_many_edges'
  return null
}

export function connect(g: DefinitionGraph, source: string, target: string): EditResult {
  const reason = connectionRefusal(g, source, target)
  if (reason) return refuse(reason)
  const id = nextId('e_', new Set(g.edges.map((e) => e.id)))
  return ok({ ...g, edges: [...g.edges, { id, source, target }] }, id)
}

export function deleteNodes(g: DefinitionGraph, ids: string[]): EditResult {
  const drop = new Set(ids)
  if (g.nodes.some((n) => drop.has(n.id) && n.node_type === 'START')) return refuse('delete_start')
  return ok({
    nodes: g.nodes.filter((n) => !drop.has(n.id)),
    edges: g.edges.filter((e) => !drop.has(e.source) && !drop.has(e.target)),
  })
}

export function deleteEdges(g: DefinitionGraph, ids: string[]): EditResult {
  const drop = new Set(ids)
  return ok({ ...g, edges: g.edges.filter((e) => !drop.has(e.id)) })
}

export function setNodeLabel(g: DefinitionGraph, id: string, label: string): EditResult {
  return mapNode(g, id, (n) => ({ ...n, label: label === '' ? null : label }))
}

/** Sets (or, for '' / undefined, removes) ONE attribute key; every other key is untouched. */
export function setNodeAttr(g: DefinitionGraph, id: string, key: string, value: unknown): EditResult {
  return mapNode(g, id, (n) => {
    if (!attributesEditable(n)) return n
    const attrs = readAttrs(n)
    if (value === undefined || value === '') delete attrs[key]
    else attrs[key] = value
    return withAttrs(n, attrs)
  })
}

/** script_key + script_version as ONE unit (Graph.check_service_task_script_reference needs both). A new key starts at version 1; an empty key removes both. */
export function setScriptBinding(g: DefinitionGraph, id: string, binding: { key: string; version?: number }): EditResult {
  return mapNode(g, id, (n) => {
    if (!attributesEditable(n)) return n
    const attrs = readAttrs(n)
    if (binding.key === '') {
      delete attrs.script_key
      delete attrs.script_version
    } else {
      attrs.script_key = binding.key
      attrs.script_version = binding.version ?? (typeof attrs.script_version === 'number' ? attrs.script_version : 1)
    }
    return withAttrs(n, attrs)
  })
}

/** "Use script instead": the explicit action that replaces a service binding (service_id / endpoint) by a script pair in one step. */
export function replaceServiceWithScript(g: DefinitionGraph, id: string, key: string): EditResult {
  return mapNode(g, id, (n) => {
    if (!attributesEditable(n)) return n
    const attrs = readAttrs(n)
    delete attrs.service_id
    delete attrs.endpoint
    attrs.script_key = key
    attrs.script_version = 1
    return withAttrs(n, attrs)
  })
}

export function hasServiceBinding(node: GraphNode): boolean {
  const a = readAttrs(node)
  return (typeof a.service_id === 'string' && a.service_id !== '') || (typeof a.endpoint === 'string' && a.endpoint !== '')
}

/** Inline hints from the pure rules; the server check stays the authority. */
export function scriptBindingHint(key: string, version: unknown): 'bad_key' | 'bad_version' | null {
  if (key === '') return null
  if (!SCRIPT_KEY_RE.test(key)) return 'bad_key'
  if (typeof version !== 'number' || !Number.isInteger(version) || version < 1) return 'bad_version'
  return null
}

export function setEdge(g: DefinitionGraph, id: string, patch: { condition?: string; is_default?: boolean }): EditResult {
  if (!g.edges.some((e) => e.id === id)) return refuse('unknown_edge')
  return ok({
    ...g,
    edges: g.edges.map((e): GraphEdge => {
      if (e.id !== id) return e
      const next: GraphEdge = { ...e }
      if ('condition' in patch) {
        if (patch.condition) next.condition = patch.condition
        else delete next.condition
      }
      if ('is_default' in patch) {
        if (patch.is_default) next.is_default = true
        else delete next.is_default
      }
      return next
    }),
  })
}

/** The next draft version: increments the last numeric segment of a dotted version; a non-numeric version gets `.1`. */
export function nextDraftVersion(version: string): string {
  const m = /^(.*?)(\d+)$/.exec(version)
  if (!m) return `${version}.1`
  return `${m[1]}${Number(m[2]) + 1}`
}

/** The graph with a position for every node: nodes that have none get the automatic (dagre) layout position, so a
 *  "move" is real and the saved definition keeps the drawing. Nodes with a position are untouched. */
export function withLayoutPositions(g: DefinitionGraph): DefinitionGraph {
  if (g.nodes.every((n) => positionOf(n) !== null)) return g
  const laid = layoutDefinition(g, 'LR')
  const at = new Map(laid.nodes.map((n) => [n.id, { x: n.x, y: n.y }]))
  return {
    ...g,
    nodes: g.nodes.map((n) => {
      if (positionOf(n) !== null || !attributesEditable(n)) return n
      const p = at.get(n.id)
      return p ? withAttrs(n, { ...readAttrs(n), position: { x: Math.round(p.x), y: Math.round(p.y) } }) : n
    }),
  }
}
