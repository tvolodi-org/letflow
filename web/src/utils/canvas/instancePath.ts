/**
 * instancePath — which nodes and edges of a definition an instance has run (T-1520, D-114 item 2).
 *
 * Drawn from instance data the web already has: `status`, `current_nodes`, `error_detail.affected` and the
 * timeline. The event store has no node-entered event, so gateways, sub-processes and END are inferred. The rule
 * ("segment attribution", docs/design/process-designer.md) is sound, not complete: it asserts only what holds in
 * every execution that agrees with the evidence; anything it cannot decide is `unclear` ("Not certain").
 *
 * - Sources (certainly left): START once started, every evidenced node with a completion, and — while the instance
 *   is not COMPLETED — every parallel join with two or more incoming edges (a "relay": the engine fires the join
 *   and moves the token on in the same transaction, req051 §4, and no API exposes whether it fired).
 * - Stops: reached evidenced nodes, current nodes, ENDs, relay joins.
 * - A segment (S, T) is a path S → T whose intermediates are all interior (pass-through, not current, not relay).
 * - One integer unknown per segment (how often the token travelled it), constrained by completions and entries,
 *   then tightened by interval propagation: lo ≥ 1 → proven, hi = 0 → excluded, else open.
 * - Cut vertices of proven segments are done, bridges are taken; the rest of a proven/open segment is unclear.
 * - Skipped needs positive proof: a done exclusive gateway with a taken branch that no live token can reach again.
 */

import type { DefinitionGraph, InstanceStatus, TimelineEntry } from '@/types/api'
import { normaliseGraph } from './readLayout'

export type NodeState = 'done' | 'active' | 'error' | 'skipped' | 'pending' | 'unclear'
export type EdgeState = 'taken' | 'untaken' | 'unclear'
export type PathNote = 'errorNotAttributed' | 'notReconciled' | 'historyIncomplete' | 'cancelled'

export interface NodePathState {
  state: NodeState
  basis: 'evidence' | 'inferred'
}

export interface InstancePath {
  nodes: Map<string, NodePathState>
  edges: Map<string, EdgeState>
  notes: PathNote[]
}

export interface PathEvidence {
  completions: Map<string, number>
  started: boolean
  /** False when timeline pages are missing (a failed page or the page cap). */
  complete: boolean
}

export interface PathInstance {
  status: InstanceStatus | string
  current_nodes?: string[] | null
  error_detail?: Record<string, unknown> | null
}

/** The only timeline events that carry a top-level `node_id` and mean "this node completed". */
export const COMPLETION_EVENTS: ReadonlySet<string> = new Set([
  'TASK_COMPLETED',
  'SERVICE_TASK_COMPLETED',
  'SCRIPT_TASK_COMPLETED',
  'TIMER_FIRED',
])

/** Node types with no event of their own. */
const PASS_THROUGH: ReadonlySet<string> = new Set(['START', 'END', 'EXCLUSIVE_GATEWAY', 'PARALLEL_GATEWAY', 'SUB_PROCESS'])

/** Build the evidence from an accumulated timeline. Duplicates (same `event_id`) count once. */
export function timelineEvidence(entries: readonly TimelineEntry[], opts: { complete: boolean }): PathEvidence {
  const completions = new Map<string, number>()
  const seen = new Set<string>()
  let started = false
  for (const e of entries) {
    if (!e) continue
    if (e.event_id) {
      if (seen.has(e.event_id)) continue
      seen.add(e.event_id)
    }
    if (e.event_type === 'INSTANCE_STARTED') started = true
    if (COMPLETION_EVENTS.has(e.event_type) && typeof e.node_id === 'string' && e.node_id !== '') {
      completions.set(e.node_id, (completions.get(e.node_id) ?? 0) + 1)
    }
  }
  return { completions, started, complete: opts.complete }
}

interface Segment {
  source: string
  target: string
  subNodes: Set<string>
  subEdges: Set<string>
  parallel: boolean
}

type Cmp = 'eq' | 'ge' | 'le'
interface Constraint {
  segs: number[]
  cmp: Cmp
  n: number
}

interface E {
  id: string
  source: string
  target: string
}

/** Is `target` reachable from `source` over `edges` (inside a segment), skipping a node or an edge? */
function reachesInside(
  seg: Segment,
  outBy: Map<string, E[]>,
  skipNode: string | null,
  skipEdge: string | null,
): boolean {
  const visited = new Set<string>()
  const queue: string[] = [seg.source]
  while (queue.length > 0) {
    const u = queue.shift()!
    for (const e of outBy.get(u) ?? []) {
      if (!seg.subEdges.has(e.id) || e.id === skipEdge) continue
      const v = e.target
      if (v === seg.target) return true
      if (v === skipNode || !seg.subNodes.has(v) || visited.has(v)) continue
      visited.add(v)
      queue.push(v)
    }
  }
  return false
}

/** Dominator sets from the first START (iterative data-flow; n is at most a few hundred nodes). */
function dominators(startId: string | undefined, inBy: Map<string, E[]>, outBy: Map<string, E[]>) {
  const dom = new Map<string, Set<string>>()
  if (!startId) return dom
  // reverse post-order of the nodes reachable from START
  const order: string[] = []
  const seen = new Set<string>([startId])
  const stack: Array<{ id: string; i: number }> = [{ id: startId, i: 0 }]
  while (stack.length > 0) {
    const top = stack[stack.length - 1]
    const outs = outBy.get(top.id) ?? []
    if (top.i < outs.length) {
      const next = outs[top.i++].target
      if (!seen.has(next)) {
        seen.add(next)
        stack.push({ id: next, i: 0 })
      }
    } else {
      order.push(top.id)
      stack.pop()
    }
  }
  order.reverse()
  const reachable = new Set(order)
  for (const id of order) dom.set(id, id === startId ? new Set([startId]) : new Set(order))
  let changed = true
  while (changed) {
    changed = false
    for (const id of order) {
      if (id === startId) continue
      let acc: Set<string> | null = null
      for (const e of inBy.get(id) ?? []) {
        if (!reachable.has(e.source)) continue
        const d = dom.get(e.source)!
        if (acc === null) acc = new Set(d)
        else for (const x of acc) if (!d.has(x)) acc.delete(x)
      }
      const next = acc ?? new Set<string>()
      next.add(id)
      const cur = dom.get(id)!
      if (next.size !== cur.size) {
        dom.set(id, next)
        changed = true
      }
    }
  }
  return dom
}

/** Bounds tightening over integer intervals. Returns null on a contradiction (an empty interval). */
function propagate(count: number, constraints: Constraint[]): Array<[number, number]> | null {
  const lo = new Array<number>(count).fill(0)
  const hi = new Array<number>(count).fill(Infinity)
  // Empty sums: "= n" or ">= n" with n >= 1 over zero segments can never hold.
  for (const c of constraints) {
    if (c.segs.length === 0 && c.cmp !== 'le' && c.n >= 1) return null
  }
  const maxRounds = 4 * count + 10
  for (let round = 0; round < maxRounds; round++) {
    let changed = false
    for (const c of constraints) {
      for (const s of c.segs) {
        let otherLo = 0
        let otherHi = 0
        for (const o of c.segs) {
          if (o === s) continue
          otherLo += lo[o]
          otherHi += hi[o]
        }
        if (c.cmp !== 'le' && Number.isFinite(otherHi) && c.n - otherHi > lo[s]) {
          lo[s] = c.n - otherHi
          changed = true
        }
        if (c.cmp !== 'ge' && c.n - otherLo < hi[s]) {
          hi[s] = c.n - otherLo
          changed = true
        }
        if (lo[s] > hi[s]) return null
      }
    }
    if (!changed) break
  }
  return lo.map((l, i) => [l, hi[i]] as [number, number])
}

export function deriveInstancePath(
  graph: DefinitionGraph | null | undefined,
  instance: PathInstance,
  evidence: PathEvidence,
): InstancePath {
  const { nodes, edges: rawEdges } = normaliseGraph(graph)
  const edges: E[] = rawEdges.map((e) => ({ id: e.id, source: e.source, target: e.target }))
  const typeOf = new Map(nodes.map((n) => [n.id, n.node_type as string]))
  const ids = nodes.map((n) => n.id)
  const outBy = new Map<string, E[]>()
  const inBy = new Map<string, E[]>()
  for (const id of ids) {
    outBy.set(id, [])
    inBy.set(id, [])
  }
  for (const e of edges) {
    outBy.get(e.source)!.push(e)
    inBy.get(e.target)!.push(e)
  }

  const notes: PathNote[] = []
  const nodeStates = new Map<string, NodePathState>()
  const edgeStates = new Map<string, EdgeState>()
  const status = instance.status
  const isCompleted = status === 'COMPLETED'
  const current = new Set((instance.current_nodes ?? []).filter((id) => typeOf.has(id)))
  const isEvidenced = (id: string) => !PASS_THROUGH.has(typeOf.get(id) ?? '')
  const completionsOf = (id: string) => evidence.completions.get(id) ?? 0

  // ── Rule 1: current nodes ──
  let errorNode: string | null = null
  if (status === 'ERROR') {
    const affected = (instance.error_detail as { affected?: { kind?: unknown; node_id?: unknown } } | null | undefined)?.affected
    if (affected && affected.kind === 'node' && typeof affected.node_id === 'string' && typeOf.has(affected.node_id)) {
      errorNode = affected.node_id
    } else {
      notes.push('errorNotAttributed')
    }
  }
  if (status === 'CANCELLED') notes.push('cancelled')
  for (const id of current) {
    if (status === 'ACTIVE') nodeStates.set(id, { state: 'active', basis: 'evidence' })
    else if (status === 'ERROR') {
      nodeStates.set(id, errorNode === null ? { state: 'unclear', basis: 'evidence' } : { state: 'pending', basis: 'evidence' })
    } else if (status === 'CANCELLED') nodeStates.set(id, { state: 'pending', basis: 'evidence' })
  }
  if (errorNode !== null) nodeStates.set(errorNode, { state: 'error', basis: 'evidence' })
  const isCurrentLike = (id: string) => current.has(id) || id === errorNode

  // ── Rule 2: evidence ──
  for (const id of ids) {
    if (isEvidenced(id) && completionsOf(id) >= 1 && !nodeStates.has(id)) {
      nodeStates.set(id, { state: 'done', basis: 'evidence' })
    }
  }
  const startIds = ids.filter((id) => typeOf.get(id) === 'START')
  const anyReached = ids.some((id) => typeOf.get(id) !== 'START' && (isCurrentLike(id) || (isEvidenced(id) && completionsOf(id) >= 1)))
  const started = evidence.started || anyReached || isCompleted
  if (started) for (const s of startIds) if (!nodeStates.has(s)) nodeStates.set(s, { state: 'done', basis: 'evidence' })

  // ── Rule 3: segment attribution ──
  const isRelay = (id: string) => !isCompleted && typeOf.get(id) === 'PARALLEL_GATEWAY' && (inBy.get(id)?.length ?? 0) >= 2
  const isReachedEvidenced = (id: string) => isEvidenced(id) && (completionsOf(id) >= 1 || isCurrentLike(id))
  const isStop = (id: string) => isReachedEvidenced(id) || isCurrentLike(id) || typeOf.get(id) === 'END' || isRelay(id)
  const isInterior = (id: string) => {
    const t = typeOf.get(id) ?? ''
    return PASS_THROUGH.has(t) && t !== 'START' && t !== 'END' && !isCurrentLike(id) && !isRelay(id)
  }
  const sources: string[] = []
  const exits = new Map<string, number | null>()
  for (const id of ids) {
    if (typeOf.get(id) === 'START' && started) {
      sources.push(id)
      exits.set(id, 1)
    } else if (isEvidenced(id) && completionsOf(id) >= 1) {
      sources.push(id)
      exits.set(id, completionsOf(id))
    } else if (isRelay(id)) {
      sources.push(id)
      exits.set(id, null)
    }
  }

  const segments: Segment[] = []
  for (const s of sources) {
    // forward search over interior nodes
    const fwd = new Set<string>()
    const queue: string[] = [s]
    const stopsHit = new Set<string>()
    while (queue.length > 0) {
      const u = queue.shift()!
      for (const e of outBy.get(u) ?? []) {
        const v = e.target
        if (isStop(v)) stopsHit.add(v)
        if (isInterior(v) && !fwd.has(v)) {
          fwd.add(v)
          queue.push(v)
        }
      }
    }
    for (const t of stopsHit) {
      // backward search from t over interior nodes reached forward
      const bwd = new Set<string>()
      const bq: string[] = [t]
      let sourceHit = false
      while (bq.length > 0) {
        const v = bq.shift()!
        for (const e of inBy.get(v) ?? []) {
          const u = e.source
          if (u === s) sourceHit = true
          if (fwd.has(u) && !bwd.has(u)) {
            bwd.add(u)
            bq.push(u)
          }
        }
      }
      if (!sourceHit) continue
      const subNodes = bwd
      const subEdges = new Set<string>()
      for (const e of edges) {
        const fromOk = e.source === s || subNodes.has(e.source)
        const toOk = e.target === t || subNodes.has(e.target)
        if (fromOk && toOk) subEdges.add(e.id)
      }
      if (s === t && subNodes.size === 0) continue // a self-loop edge with no intermediate is not a segment
      const parallel =
        [...subNodes].some((n) => typeOf.get(n) === 'PARALLEL_GATEWAY') || (isRelay(s) && (outBy.get(s)?.length ?? 0) >= 2)
      segments.push({ source: s, target: t, subNodes, subEdges, parallel })
    }
  }

  const entriesOf = (id: string): number | null => {
    if (typeOf.get(id) === 'END' || isRelay(id)) return null
    if (!isEvidenced(id) && !isCurrentLike(id)) return null
    return completionsOf(id) + (isCurrentLike(id) ? 1 : 0)
  }

  const outcome: Array<'proven' | 'excluded' | 'open'> = segments.map(() => 'open')
  if (!evidence.complete) {
    notes.push('historyIncomplete')
  } else {
    const dom = dominators(startIds[0], inBy, outBy)
    const dominates = (t: string, s: string) => dom.get(s)?.has(t) ?? false
    const constraints: Constraint[] = []
    const fromIdx = new Map<string, number[]>()
    const intoIdx = new Map<string, number[]>()
    segments.forEach((seg, i) => {
      if (!fromIdx.has(seg.source)) fromIdx.set(seg.source, [])
      fromIdx.get(seg.source)!.push(i)
      if (!intoIdx.has(seg.target)) intoIdx.set(seg.target, [])
      intoIdx.get(seg.target)!.push(i)
    })
    for (const s of sources) {
      const ex = exits.get(s)
      if (ex === null || ex === undefined) continue
      const segs = fromIdx.get(s) ?? []
      const par = segs.some((i) => segments[i].parallel)
      constraints.push({ segs, cmp: par ? 'ge' : 'eq', n: par ? 1 : ex })
    }
    for (const t of ids) {
      if (!isStop(t)) continue
      const n = entriesOf(t)
      if (n === null || n < 1) continue
      const segs = intoIdx.get(t) ?? []
      const par = segs.some((i) => segments[i].parallel)
      constraints.push({ segs, cmp: par ? 'ge' : 'eq', n: par ? 1 : n })
      constraints.push({ segs: segs.filter((i) => !dominates(t, segments[i].source)), cmp: 'ge', n: 1 })
      if (!par) constraints.push({ segs: segs.filter((i) => dominates(t, segments[i].source)), cmp: 'le', n: n - 1 })
    }
    if (isCompleted) {
      const segs = segments.map((seg, i) => (typeOf.get(seg.target) === 'END' ? i : -1)).filter((i) => i >= 0)
      constraints.push({ segs, cmp: 'ge', n: 1 })
    }
    const bounds = propagate(segments.length, constraints)
    if (bounds === null) {
      notes.push('notReconciled')
    } else {
      bounds.forEach(([lo, hi], i) => {
        outcome[i] = lo >= 1 ? 'proven' : hi === 0 ? 'excluded' : 'open'
      })
    }
  }

  // 3e / 3f: nodes and edges of proven and open segments
  const inferredDone = new Set<string>()
  const unclearNodes = new Set<string>()
  const taken = new Set<string>()
  const unclearEdges = new Set<string>()
  segments.forEach((seg, i) => {
    if (outcome[i] === 'excluded') return
    if (outcome[i] === 'open') {
      for (const n of seg.subNodes) unclearNodes.add(n)
      for (const e of seg.subEdges) unclearEdges.add(e)
      return
    }
    for (const n of seg.subNodes) {
      if (!reachesInside(seg, outBy, n, null)) inferredDone.add(n)
      else unclearNodes.add(n)
    }
    for (const e of seg.subEdges) {
      if (!reachesInside(seg, outBy, null, e)) taken.add(e)
      else unclearEdges.add(e)
    }
    if (typeOf.get(seg.target) === 'END') inferredDone.add(seg.target)
    if (isRelay(seg.source)) inferredDone.add(seg.source)
  })
  for (const n of inferredDone) if (!nodeStates.has(n)) nodeStates.set(n, { state: 'done', basis: 'inferred' })
  for (const n of unclearNodes) if (!nodeStates.has(n)) nodeStates.set(n, { state: 'unclear', basis: 'inferred' })
  // When the evidence is missing or contradicts the model, no edge is asserted untaken either.
  const noUntaken = notes.includes('notReconciled') || notes.includes('historyIncomplete')
  for (const e of edges) {
    edgeStates.set(e.id, taken.has(e.id) ? 'taken' : unclearEdges.has(e.id) || noUntaken ? 'unclear' : 'untaken')
  }

  // ── Rule 4: skipped (positive proof only, exclusive gateways only) ──
  // A gateway a live token can still reach (a loop) may yet take its other branch, so it proves no skip.
  const reachableFromCurrent = new Set<string>()
  if (status === 'ACTIVE' || status === 'ERROR') {
    const queue = [...current]
    while (queue.length > 0) {
      const u = queue.shift()!
      for (const e of outBy.get(u) ?? []) {
        if (!reachableFromCurrent.has(e.target)) {
          reachableFromCurrent.add(e.target)
          queue.push(e.target)
        }
      }
    }
  }
  const seedEdges = new Set<string>()
  for (const id of ids) {
    if (typeOf.get(id) !== 'EXCLUSIVE_GATEWAY' || nodeStates.get(id)?.state !== 'done') continue
    if (reachableFromCurrent.has(id)) continue
    const outs = outBy.get(id) ?? []
    if (!outs.some((e) => edgeStates.get(e.id) === 'taken')) continue
    for (const e of outs) if (edgeStates.get(e.id) === 'untaken') seedEdges.add(e.id)
  }
  if (seedEdges.size > 0) {
    const skipped = new Set<string>()
    let grew = true
    while (grew) {
      grew = false
      for (const id of ids) {
        if (skipped.has(id) || nodeStates.has(id)) continue
        const ins = inBy.get(id) ?? []
        if (ins.length === 0) continue
        const all = ins.every((e) => seedEdges.has(e.id) || skipped.has(e.source))
        const someSeedOrSkipped = ins.some((e) => seedEdges.has(e.id) || skipped.has(e.source))
        if (all && someSeedOrSkipped) {
          skipped.add(id)
          grew = true
        }
      }
    }
    for (const id of skipped) nodeStates.set(id, { state: 'skipped', basis: 'inferred' })
  }

  // ── Rule 5: everything else ──
  for (const id of ids) {
    if (nodeStates.has(id)) continue
    // Missing or contradicting history: an unreached-looking node may have run, so nothing is asserted pending.
    const modelFailed = notes.includes('notReconciled') || notes.includes('historyIncomplete')
    const pending = !modelFailed && (status === 'ACTIVE' || status === 'CANCELLED')
    nodeStates.set(id, { state: pending ? 'pending' : 'unclear', basis: 'inferred' })
  }

  return { nodes: nodeStates, edges: edgeStates, notes }
}
