/**
 * graphDiff — T-1588 (process designer slice 3A). A pure, read-only comparison of two versions of a process graph.
 *
 * Result: one MERGED graph holding both versions (all steps and connections of `to`, plus the ones only `from` has),
 * and a per-step and per-connection kind (added / removed / changed / unchanged), so the diagram can draw both on
 * one picture.
 *
 * - Steps are matched by id (a step id survives a new version: the version is copied from the previous graph).
 *   Changed = `node_type`, `label` or an attribute differs. `position` is ignored (layout is computed). Only field
 *   NAMES are reported, never values (endpoints, form schemas and script arguments may be sensitive).
 * - Connections are matched by their ENDPOINTS (source, target), never by id alone: the editor reuses the lowest
 *   free `e_N`, so an id can come back with other endpoints. A moved connection is one removed plus one added.
 *   Connections with the same endpoints are changed / unchanged by `condition` and `is_default`.
 * - Every connection of the merged graph gets a fresh diagram id (`d_<kind>_<index>`); the input ids are kept in
 *   `origin`, so two connections that shared an input id cannot collapse into one.
 */
import type { DefinitionGraph, GraphEdge, GraphNode } from '@/types/api'
import { parseAttributes } from './readLayout'

export type DiffKind = 'added' | 'removed' | 'changed' | 'unchanged'

export interface DiffEntry {
  kind: DiffKind
  /** Names of the fields that differ (changed entries only). */
  fields: string[]
}

export interface EdgeDiffEntry extends DiffEntry {
  origin: { fromId?: string; toId?: string }
}

export interface DiffCounts {
  added: number
  removed: number
  changed: number
}

export interface GraphDiff {
  /** By step id. */
  nodes: Map<string, DiffEntry>
  /** By diagram id (`graph.edges[i].id`). */
  edges: Map<string, EdgeDiffEntry>
  counts: { nodes: DiffCounts; edges: DiffCounts }
  /** Both versions on one graph. */
  graph: DefinitionGraph
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  if (value && typeof value === 'object') {
    const o = value as Record<string, unknown>
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${stable(o[k])}`)
      .join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

function uniqueNodes(graph: DefinitionGraph | null | undefined): GraphNode[] {
  const raw = Array.isArray(graph?.nodes) ? graph!.nodes : []
  const seen = new Set<string>()
  return raw.filter((n) => {
    if (!n || typeof n.id !== 'string' || seen.has(n.id)) return false
    seen.add(n.id)
    return true
  })
}

function edgesOf(graph: DefinitionGraph | null | undefined): GraphEdge[] {
  const raw = Array.isArray(graph?.edges) ? graph!.edges : []
  return raw.filter((e) => e && typeof e.source === 'string' && typeof e.target === 'string')
}

const cond = (e: GraphEdge) => (typeof e.condition === 'string' ? e.condition : '')
const dflt = (e: GraphEdge) => e.is_default === true

function nodeFields(a: GraphNode, b: GraphNode): string[] {
  const fields: string[] = []
  if (a.node_type !== b.node_type) fields.push('node_type')
  if ((a.label ?? null) !== (b.label ?? null)) fields.push('label')
  const pa = parseAttributes(a.attributes)
  const pb = parseAttributes(b.attributes)
  const keys = [...new Set([...Object.keys(pa), ...Object.keys(pb)])].filter((k) => k !== 'position').sort()
  for (const k of keys) if (stable(pa[k]) !== stable(pb[k])) fields.push(k)
  return fields
}

function groupByEndpoints(edges: GraphEdge[]): Map<string, GraphEdge[]> {
  const m = new Map<string, GraphEdge[]>()
  for (const e of edges) {
    const key = `${e.source}\u0000${e.target}`
    m.set(key, [...(m.get(key) ?? []), e])
  }
  // Same-endpoint connections are matched in this order, so equal ones pair with each other.
  for (const list of m.values()) {
    list.sort((x, y) => cond(x).localeCompare(cond(y)) || Number(dflt(x)) - Number(dflt(y)) || String(x.id).localeCompare(String(y.id)))
  }
  return m
}

const zero = (): DiffCounts => ({ added: 0, removed: 0, changed: 0 })

export function diffGraphs(from: DefinitionGraph | null | undefined, to: DefinitionGraph | null | undefined): GraphDiff {
  const fromNodes = uniqueNodes(from)
  const toNodes = uniqueNodes(to)
  const fromById = new Map(fromNodes.map((n) => [n.id, n]))
  const toIds = new Set(toNodes.map((n) => n.id))

  const nodeDiff = new Map<string, DiffEntry>()
  const nodeCounts = zero()
  const mergedNodes: GraphNode[] = []
  for (const n of toNodes) {
    const before = fromById.get(n.id)
    if (!before) {
      nodeDiff.set(n.id, { kind: 'added', fields: [] })
      nodeCounts.added++
    } else {
      const fields = nodeFields(before, n)
      if (fields.length > 0) {
        nodeDiff.set(n.id, { kind: 'changed', fields })
        nodeCounts.changed++
      } else nodeDiff.set(n.id, { kind: 'unchanged', fields: [] })
    }
    mergedNodes.push(n)
  }
  for (const n of fromNodes) {
    if (toIds.has(n.id)) continue
    nodeDiff.set(n.id, { kind: 'removed', fields: [] })
    nodeCounts.removed++
    mergedNodes.push(n)
  }

  const fromGroups = groupByEndpoints(edgesOf(from))
  const toGroups = groupByEndpoints(edgesOf(to))
  const edgeDiff = new Map<string, EdgeDiffEntry>()
  const edgeCounts = zero()
  const mergedEdges: GraphEdge[] = []
  const push = (e: GraphEdge, kind: DiffKind, fields: string[], origin: EdgeDiffEntry['origin']) => {
    const id = `d_${kind}_${mergedEdges.length}`
    mergedEdges.push({ ...e, id })
    edgeDiff.set(id, { kind, fields, origin })
    if (kind !== 'unchanged') edgeCounts[kind]++
  }
  const usedByKey = new Map<string, Set<number>>()
  // `to` order first (pairs and additions), then what only `from` has.
  for (const [key, toList] of toGroups) {
    const fromList = fromGroups.get(key) ?? []
    // Equal connections pair first; only the leftovers pair up as changes (in order), then add/remove.
    const same = (a: GraphEdge, b: GraphEdge) => cond(a) === cond(b) && dflt(a) === dflt(b)
    const used = new Set<number>()
    const match = new Map<number, GraphEdge>()
    toList.forEach((e, i) => {
      const j = fromList.findIndex((f, k) => !used.has(k) && same(f, e))
      if (j >= 0) {
        used.add(j)
        match.set(i, fromList[j])
      }
    })
    toList.forEach((_, i) => {
      if (match.has(i)) return
      const j = fromList.findIndex((_f, k) => !used.has(k))
      if (j >= 0) {
        used.add(j)
        match.set(i, fromList[j])
      }
    })
    usedByKey.set(key, used)
    toList.forEach((e, i) => {
      const before = match.get(i)
      if (!before) return push(e, 'added', [], { toId: e.id })
      const fields: string[] = []
      if (cond(before) !== cond(e)) fields.push('condition')
      if (dflt(before) !== dflt(e)) fields.push('is_default')
      push(e, fields.length > 0 ? 'changed' : 'unchanged', fields, { fromId: before.id, toId: e.id })
    })
  }
  for (const [key, fromList] of fromGroups) {
    const used = usedByKey.get(key)
    fromList.forEach((e, k) => {
      if (!used?.has(k)) push(e, 'removed', [], { fromId: e.id })
    })
  }

  return {
    nodes: nodeDiff,
    edges: edgeDiff,
    counts: { nodes: nodeCounts, edges: edgeCounts },
    graph: { nodes: mergedNodes, edges: mergedEdges },
  }
}

export function diffIsEmpty(d: GraphDiff): boolean {
  const c = [d.counts.nodes, d.counts.edges]
  return c.every((x) => x.added + x.removed + x.changed === 0)
}
