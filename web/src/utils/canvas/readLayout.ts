/**
 * readLayout — automatic layout of a process definition for the READ-ONLY diagram (T-1520, D-114 item 2).
 *
 * The definition is the single source of truth: the picture is computed from its nodes and edges only. A persisted
 * editor `position` attribute is ignored on purpose, so an agent-written definition (no positions) and an
 * editor-saved one look the same. Node boxes are sized for reading at 1:1 (a label up to the edge-label length is
 * not cut) and a compact shape's box includes its caption, so dagre keeps edges, edge labels and other nodes clear
 * of the caption. Edge routes and label positions come from dagre too (edge labels get their own space), so a long
 * edge bends around the nodes between its ends instead of running through them.
 * See docs/design/process-designer.md.
 */

import dagre from '@dagrejs/dagre'
import type { DefinitionGraph } from '@/types/api'

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
  /** Compact shapes (START, END, gateways, TIMER): the size of the shape itself, drawn at the top of the box above
   *  its caption. Absent for task boxes. */
  shape?: number
}

export interface Point {
  x: number
  y: number
}

export interface LaidOutEdge {
  id: string
  source: string
  target: string
  condition?: string
  isDefault: boolean
  /** The dagre route (flow coordinates), first and last point on the node boxes. When `exitBelowCaption` is set (a
   *  compact source in a top-to-bottom drawing) the first point is the bottom centre of the source box: the edge
   *  leaves the shape, runs straight down behind the caption and must pass through that point. */
  points: Point[]
  exitBelowCaption?: boolean
  /** Centre of the edge label, when the edge has one (dagre reserves its space). */
  labelX?: number
  labelY?: number
}

export interface ReadLayout {
  nodes: LaidOutNode[]
  edges: LaidOutEdge[]
  width: number
  height: number
  /** Edges dropped because their source or target is not a node of the graph. */
  droppedEdges: number
}

/** Shape size of the compact node types (px). */
export const COMPACT_SHAPE: Readonly<Record<string, number>> = {
  START: 48,
  END: 48,
  EXCLUSIVE_GATEWAY: 56,
  PARALLEL_GATEWAY: 56,
  TIMER: 56,
}
/** A compact node's caption below the shape: its width (= --field-w-s) and the height kept free for it (gap, a label
 *  of up to two lines, a sub-line and a state pill). */
export const CAPTION_WIDTH = 160
export const CAPTION_HEIGHT = 88
const TASK_DIMS = { width: 248, height: 100 }
const BOX_DIMS: Readonly<Record<string, { width: number; height: number }>> = {
  HUMAN_TASK: TASK_DIMS,
  SERVICE_TASK: TASK_DIMS,
  SUB_PROCESS: { width: 264, height: 104 },
}
/** Edge label pill: height, and width per character of the mono label font plus padding, capped like the CSS. */
const LABEL_HEIGHT = 24
const LABEL_CHAR = 7.5
const LABEL_PAD = 20
const LABEL_MAX_WIDTH = 200

/** Box of a node. A compact box holds the shape and its caption; left to right, the caption space is kept above the
 *  shape as well, so the shape's centre is the box centre and lines up with the task boxes of its rank. */
export function nodeDims(nodeType: string, direction: LayoutDirection = 'TB'): { width: number; height: number; shape?: number } {
  const shape = COMPACT_SHAPE[nodeType]
  if (shape !== undefined) {
    return { width: CAPTION_WIDTH, height: shape + (direction === 'LR' ? 2 : 1) * CAPTION_HEIGHT, shape }
  }
  return BOX_DIMS[nodeType] ?? TASK_DIMS
}

export function edgeLabelWidth(label: string): number {
  return Math.min(LABEL_MAX_WIDTH, Math.round(LABEL_PAD + LABEL_CHAR * label.length))
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

/**
 * Layout of a definition. `edgeLabel` gives the (already cut) label text of an edge, or null; dagre reserves space
 * for it. Without it, the condition (cut to `labelMax`) or nothing is assumed.
 */
export function layoutDefinition(
  graph: DefinitionGraph | null | undefined,
  direction: LayoutDirection = 'TB',
  edgeLabel?: (edge: { condition?: string; isDefault: boolean }) => string | null,
): ReadLayout {
  const { nodes, edges, droppedEdges } = normaliseGraph(graph)
  if (nodes.length === 0) return { nodes: [], edges: [], width: 0, height: 0, droppedEdges }

  const g = new dagre.graphlib.Graph({ multigraph: true })
  g.setDefaultEdgeLabel(() => ({}))
  g.setGraph({ rankdir: direction, nodesep: 48, edgesep: 24, ranksep: 56, marginx: 24, marginy: 24 })
  for (const n of nodes) {
    const { width, height } = nodeDims(n.node_type, direction)
    g.setNode(n.id, { width, height })
  }
  const plain = edges.map((e) => ({
    e,
    condition: typeof e.condition === 'string' && e.condition !== '' ? e.condition : undefined,
    isDefault: e.is_default === true,
  }))
  for (const { e, condition, isDefault } of plain) {
    const text = edgeLabel ? edgeLabel({ condition, isDefault }) : condition ?? null
    g.setEdge(e.source, e.target, text ? { width: edgeLabelWidth(text), height: LABEL_HEIGHT, labelpos: 'c' } : {}, e.id)
  }
  dagre.layout(g)

  let width = 0
  let height = 0
  const laidOut: LaidOutNode[] = nodes.map((n) => {
    const dims = nodeDims(n.node_type, direction)
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
  const byId = new Map(laidOut.map((n) => [n.id, n]))
  const laidEdges: LaidOutEdge[] = plain.map(({ e, condition, isDefault }) => {
    const de = g.edge({ v: e.source, w: e.target, name: e.id }) as
      | { points?: Point[]; x?: number; y?: number; width?: number }
      | undefined
    const points = (de?.points ?? []).map((p) => ({ x: Math.round(p.x), y: Math.round(p.y) }))
    const src = byId.get(e.source)
    const exitBelowCaption = direction === 'TB' && src?.shape !== undefined && points.length >= 2
    if (exitBelowCaption) points[0] = { x: src!.x + src!.width / 2, y: src!.y + src!.height }
    for (const p of points) {
      width = Math.max(width, p.x)
      height = Math.max(height, p.y)
    }
    const hasLabel = typeof de?.width === 'number' && de.width > 0 && typeof de.x === 'number' && typeof de.y === 'number'
    if (hasLabel) {
      width = Math.max(width, de!.x! + de!.width! / 2)
      height = Math.max(height, de!.y! + LABEL_HEIGHT / 2)
    }
    return {
      id: e.id,
      source: e.source,
      target: e.target,
      condition,
      isDefault,
      points,
      ...(exitBelowCaption ? { exitBelowCaption } : {}),
      ...(hasLabel ? { labelX: Math.round(de!.x!), labelY: Math.round(de!.y!) } : {}),
    }
  })
  width = Math.ceil(width)
  height = Math.ceil(height)
  return { nodes: laidOut, edges: laidEdges, width, height, droppedEdges }
}

export interface Viewport {
  x: number
  y: number
  zoom: number
}

/** Space kept between the drawing and the canvas edge in the first view (px). */
const VIEW_PAD = 24

/**
 * The first view of a laid-out drawing in a canvas: the whole drawing when it fits at a readable scale, otherwise
 * the readable scale (`minReadable`, text stays legible) with the start of the drawing (top or left) in view and the
 * rest reached by panning. Never above 1:1. A drawing smaller than the canvas is centred.
 */
export function initialViewport(
  drawing: { width: number; height: number },
  canvas: { width: number; height: number },
  minReadable: number,
  /** Keep the drawing at the top (the space below is left to the minimap). */
  alignTop = false,
  /** A box that must be in the first view (an instance's active or failed step): when the start-aligned view does
   *  not show it, the view is moved to centre it. */
  focus?: { x: number; y: number; width: number; height: number },
): Viewport {
  if (drawing.width <= 0 || drawing.height <= 0 || canvas.width <= 0 || canvas.height <= 0) return { x: 0, y: 0, zoom: 1 }
  const availW = Math.max(canvas.width - 2 * VIEW_PAD, 1)
  const availH = Math.max(canvas.height - 2 * VIEW_PAD, 1)
  const fit = Math.min(availW / drawing.width, availH / drawing.height)
  const zoom = Math.min(1, Math.max(minReadable, fit))
  const w = drawing.width * zoom
  const h = drawing.height * zoom
  let x = w <= availW ? (canvas.width - w) / 2 : VIEW_PAD
  let y = h <= availH && !alignTop ? (canvas.height - h) / 2 : VIEW_PAD
  if (focus) {
    const fx = focus.x * zoom + x
    const fy = focus.y * zoom + y
    if (fx < 0 || fx + focus.width * zoom > canvas.width) x = canvas.width / 2 - (focus.x + focus.width / 2) * zoom
    if (fy < 0 || fy + focus.height * zoom > canvas.height) y = canvas.height / 2 - (focus.y + focus.height / 2) * zoom
  }
  return { x: Math.round(x), y: Math.round(y), zoom }
}

/** Share (0..1] of the drawing visible in the first view: used to pick the direction that shows the most of it. */
export function visibleShare(drawing: { width: number; height: number }, canvas: { width: number; height: number }, minReadable: number): number {
  if (drawing.width <= 0 || drawing.height <= 0) return 1
  const { zoom } = initialViewport(drawing, canvas, minReadable)
  const availW = Math.max(canvas.width - 2 * VIEW_PAD, 1)
  const availH = Math.max(canvas.height - 2 * VIEW_PAD, 1)
  return Math.min(1, availW / (drawing.width * zoom)) * Math.min(1, availH / (drawing.height * zoom))
}
