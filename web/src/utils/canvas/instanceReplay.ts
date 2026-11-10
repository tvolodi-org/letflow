/**
 * instanceReplay — the recorded path of one instance, step by step (T-1635, REQ-799).
 *
 * Built only from the NODE_ENTERED events the engine writes (REQ-793), one per node a token enters, so gateways, joins
 * and END are facts, not inferences (compare `instancePath`, which infers them from completion events).
 *
 * Writer facts the state rule relies on (`Letflow.Engine.NodeEntries.entries/4`, pinned by T-793-3):
 * - every hop that puts a token on a node writes one entry, `via_edge_id` = the edge from the node it left;
 * - each branch arriving at a parallel join writes a join entry, also while the join still waits;
 * - the join's firing (also when the other branches were cancelled) writes the successor's entry via the join's
 *   outgoing edge; a cancelled branch writes nothing.
 *
 * State of node n after step k (only nodes with an entry at or before k are in the map; the rest stay neutral):
 * - END → done;
 * - a gateway → recency rule: done iff its last departure is later than its last entry, else active (a waiting join
 *   is active from its first arrival and done at the step that fires it);
 * - any other node → count rule: done iff departures ≥ entries.
 * A departure from n is a step whose `via_edge_id` is a graph edge with source n; an unknown edge is no departure.
 */

import type { DefinitionGraph, NodeEnteredItem } from '@/types/api'
import type { InstancePath, NodePathState, EdgeState } from './instancePath'
import { normaliseGraph } from './readLayout'

/** The two gateway types of `Letflow.Definitions.Graph` (`@gateway_types`). */
const GATEWAYS: ReadonlySet<string> = new Set(['PARALLEL_GATEWAY', 'EXCLUSIVE_GATEWAY'])

export interface ReplayStep {
  index: number
  seq: number
  nodeId: string
  nodeType: string
  viaEdgeId: string | null
  /** Source node of `viaEdgeId` when that edge is in the graph. */
  fromNodeId: string | null
  /** Label of `fromNodeId` (its type name is filled in by the screen when the node has no label). */
  fromLabel: string | null
  at: Date
  /** The node's label from the graph, or null when it has none (the screen shows the type name). */
  label: string | null
  sincePreviousMs: number | null
  /** False when the node is not in the graph (the definition changed). */
  known: boolean
}

export type ReplayCoverage = 'none' | 'partial' | 'full'

/** One step per entry, in `sequence_number` order; nothing merged or dropped. */
export function replaySteps(entries: readonly NodeEnteredItem[], graph: DefinitionGraph | null | undefined): ReplayStep[] {
  const { nodes, edges } = normaliseGraph(graph)
  const nodeById = new Map(nodes.map((n) => [n.id, n]))
  const edgeById = new Map(edges.map((e) => [e.id, e]))
  const sorted = [...entries].sort((a, b) => a.sequence_number - b.sequence_number)
  const steps: ReplayStep[] = []
  sorted.forEach((e, index) => {
    const nodeId = e.payload?.node_id ?? ''
    const node = nodeById.get(nodeId)
    const viaEdgeId = e.payload?.via_edge_id ?? null
    const edge = viaEdgeId ? edgeById.get(viaEdgeId) : undefined
    const from = edge ? nodeById.get(edge.source) : undefined
    const at = new Date(e.created_at)
    const prev = steps[index - 1]
    steps.push({
      index,
      seq: e.sequence_number,
      nodeId,
      nodeType: e.payload?.node_type || node?.node_type || '',
      viaEdgeId,
      fromNodeId: edge ? edge.source : null,
      fromLabel: from ? from.label ?? null : null,
      at,
      label: node?.label ?? null,
      sincePreviousMs: prev ? at.getTime() - prev.at.getTime() : null,
      known: !!node,
    })
  })
  return steps
}

/** The path after step `k` (0-based, clamped). */
export function replayPath(steps: readonly ReplayStep[], k: number, graph: DefinitionGraph | null | undefined): InstancePath {
  const nodes = new Map<string, NodePathState>()
  const edges = new Map<string, EdgeState>()
  if (steps.length === 0 || k < 0) return { nodes, edges, notes: [] }
  const last = Math.min(k, steps.length - 1)
  const edgeSource = new Map(normaliseGraph(graph).edges.map((e) => [e.id, e.source]))

  const entries = new Map<string, number>()
  const departures = new Map<string, number>()
  const lastEntry = new Map<string, number>()
  const lastDeparture = new Map<string, number>()
  const typeOf = new Map<string, string>()
  for (let i = 0; i <= last; i++) {
    const s = steps[i]!
    entries.set(s.nodeId, (entries.get(s.nodeId) ?? 0) + 1)
    lastEntry.set(s.nodeId, i)
    typeOf.set(s.nodeId, s.nodeType)
    if (s.viaEdgeId) {
      edges.set(s.viaEdgeId, 'taken')
      const source = edgeSource.get(s.viaEdgeId)
      if (source !== undefined) {
        departures.set(source, (departures.get(source) ?? 0) + 1)
        lastDeparture.set(source, i)
      }
    }
  }
  for (const [id, count] of entries) {
    const type = typeOf.get(id) ?? ''
    let done: boolean
    if (type === 'END') done = true
    else if (GATEWAYS.has(type)) done = (lastDeparture.get(id) ?? -1) > (lastEntry.get(id) ?? -1)
    else done = (departures.get(id) ?? 0) >= count
    nodes.set(id, { state: done ? 'done' : 'active', basis: 'evidence' })
  }
  return { nodes, edges, notes: [] }
}

/** `none`: nothing recorded; `partial`: the first entry is not START (the instance ran before REQ-793 shipped, no
 *  backfill exists); `full` otherwise. */
export function replayCoverage(steps: readonly ReplayStep[]): ReplayCoverage {
  if (steps.length === 0) return 'none'
  return steps[0]!.nodeType === 'START' ? 'full' : 'partial'
}

/** "+1 min 5 s" style duration parts for the step list; null under one second. */
export function durationParts(ms: number): { h: number; m: number; s: number } | null {
  if (!Number.isFinite(ms) || ms < 1000) return null
  const total = Math.floor(ms / 1000)
  return { h: Math.floor(total / 3600), m: Math.floor((total % 3600) / 60), s: total % 60 }
}
