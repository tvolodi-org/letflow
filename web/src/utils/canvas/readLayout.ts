/**
 * readLayout — automatic layout of a process definition for the READ-ONLY diagram (T-1520, D-114 item 2).
 *
 * The definition is the single source of truth: the picture is computed from its nodes and edges only. A persisted
 * editor `position` attribute is ignored on purpose, so an agent-written definition (no positions) and an
 * editor-saved one look the same. Node sizes are shared with the editor's auto-layout (`NODE_DIMS`).
 * See docs/design/process-designer.md.
 */

import dagre from '@dagrejs/dagre'
import type { DefinitionGraph } from '@/types/api'
import { NODE_DIMS } from './autoLayout'

export type LayoutDirection = 'TB' | 'LR'

export interface LaidOutNode {
  id: string
  nodeType: string
  label: string | null
  attributes: Record<string, unknown>
  x: number
  y: number
  width: number
  height: number
}

export interface LaidOutEdge {
  id: string
  source: string
  target: string
  condition?: string
  isDefault: boolean
}

export interface ReadLayout {
  nodes: LaidOutNode[]
  edges: LaidOutEdge[]
  width: number
  height: number
  /** Edges dropped because their source or target is not a node of the graph. */
  droppedEdges: number
}

const DEFAULT_DIMS = { width: 180, height: 72 }

export function nodeDims(nodeType: string): { width: number; height: number } {
  return NODE_DIMS[nodeType] ?? DEFAULT_DIMS
}

/** Parse a node's `attributes` defensively: JSON string, object, null or malformed (→ `{}`). */
export function parseAttributes(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw as Record<string, unknown>
  if (typeof raw !== 'string' || raw.trim() === '') return {}
  try {
    const parsed: unknown = JSON.parse(raw)
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

/** The graph with duplicate node ids removed (first wins) and edges to unknown nodes dropped. */
export function normaliseGraph(graph: DefinitionGraph | null | undefined): {
  nodes: DefinitionGraph['nodes']
  edges: DefinitionGraph['edges']
  droppedEdges: number
} {
  const rawNodes = Array.isArray(graph?.nodes) ? graph!.nodes : []
  const rawEdges = Array.isArray(graph?.edges) ? graph!.edges : []
  const seen = new Set<string>()
  const nodes = rawNodes.filter((n) => {
    if (!n || typeof n.id !== 'string' || seen.has(n.id)) return false
    seen.add(n.id)
    return true
  })
  const edgeIds = new Set<string>()
  const edges: DefinitionGraph['edges'] = []
  rawEdges.forEach((e, i) => {
    if (!e || !seen.has(e.source) || !seen.has(e.target)) return
    const id = typeof e.id === 'string' && e.id !== '' ? e.id : `e${i}`
    if (edgeIds.has(id)) return
    edgeIds.add(id)
    edges.push({ ...e, id })
  })
  return { nodes, edges, droppedEdges: rawEdges.length - edges.length }
}

/** True when every node has at most one incoming and one outgoing edge (a chain reads best left to right). */
export function isChain(graph: DefinitionGraph): boolean {
  const { nodes, edges } = normaliseGraph(graph)
  const outs = new Map<string, number>()
  const ins = new Map<string, number>()
  for (const e of edges) {
    outs.set(e.source, (outs.get(e.source) ?? 0) + 1)
    ins.set(e.target, (ins.get(e.target) ?? 0) + 1)
  }
  return nodes.every((n) => (outs.get(n.id) ?? 0) <= 1 && (ins.get(n.id) ?? 0) <= 1)
}

export function layoutDefinition(graph: DefinitionGraph | null | undefined, direction: LayoutDirection = 'TB'): ReadLayout {
  const { nodes, edges, droppedEdges } = normaliseGraph(graph)
  if (nodes.length === 0) return { nodes: [], edges: [], width: 0, height: 0, droppedEdges }

  const g = new dagre.graphlib.Graph({ multigraph: true })
  g.setDefaultEdgeLabel(() => ({}))
  g.setGraph({ rankdir: direction, nodesep: 48, ranksep: 72, marginx: 24, marginy: 24 })
  for (const n of nodes) g.setNode(n.id, { ...nodeDims(n.node_type) })
  for (const e of edges) g.setEdge(e.source, e.target, {}, e.id)
  dagre.layout(g)

  let width = 0
  let height = 0
  const laidOut: LaidOutNode[] = nodes.map((n) => {
    const dims = nodeDims(n.node_type)
    const dn = g.node(n.id) as { x: number; y: number } | undefined
    const x = Math.round((dn?.x ?? 0) - dims.width / 2)
    const y = Math.round((dn?.y ?? 0) - dims.height / 2)
    width = Math.max(width, x + dims.width)
    height = Math.max(height, y + dims.height)
    return {
      id: n.id,
      nodeType: n.node_type,
      label: n.label ?? null,
      attributes: parseAttributes(n.attributes),
      x,
      y,
      ...dims,
    }
  })
  const laidEdges: LaidOutEdge[] = edges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    condition: typeof e.condition === 'string' && e.condition !== '' ? e.condition : undefined,
    isDefault: e.is_default === true,
  }))
  return { nodes: laidOut, edges: laidEdges, width, height, droppedEdges }
}
