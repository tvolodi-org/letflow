/** T-1635 (REQ-799) instanceReplay: steps from NODE_ENTERED entries and the path after step k. The parallel graph and
 *  its entry sequence copy the engine's pinned test T-793-3 (test/letflow/engine/node_entered_test.exs). */
import { describe, expect, it } from 'vitest'
import type { DefinitionGraph, NodeEnteredItem } from '@/types/api'
import { durationParts, replayCoverage, replayPath, replaySteps } from '../instanceReplay'

const entry = (seq: number, node_id: string, node_type: string, via_edge_id: string | null, at?: string): NodeEnteredItem => ({
  event_id: `ev-${seq}`,
  sequence_number: seq,
  created_at: at ?? `2026-11-09T10:00:${String(seq).padStart(2, '0')}Z`,
  payload: { node_id, node_type, via_edge_id },
})

const node = (id: string, node_type: string, label: string | null = null) => ({ id, node_type, label, attributes: null })

const LINEAR = {
  nodes: [node('start', 'START'), node('g', 'EXCLUSIVE_GATEWAY', 'Check'), node('c', 'HUMAN_TASK', 'Approve'), node('end', 'END')],
  edges: [
    { id: 'l1', source: 'start', target: 'g' },
    { id: 'l2', source: 'g', target: 'c' },
    { id: 'l3', source: 'c', target: 'end' },
  ],
} as DefinitionGraph

// T-793-3: start→split e1, split→x e2, split→y e3, x→join e4, y→join e5, join→end e6.
const PARALLEL = {
  nodes: [
    node('start', 'START'),
    node('split', 'PARALLEL_GATEWAY'),
    node('x', 'HUMAN_TASK', 'X'),
    node('y', 'HUMAN_TASK', 'Y'),
    node('join', 'PARALLEL_GATEWAY', 'Join'),
    node('end', 'END'),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'split' },
    { id: 'e2', source: 'split', target: 'x' },
    { id: 'e3', source: 'split', target: 'y' },
    { id: 'e4', source: 'x', target: 'join' },
    { id: 'e5', source: 'y', target: 'join' },
    { id: 'e6', source: 'join', target: 'end' },
  ],
} as DefinitionGraph

const T793_3 = [
  entry(1, 'start', 'START', null),
  entry(2, 'split', 'PARALLEL_GATEWAY', 'e1'),
  entry(3, 'x', 'HUMAN_TASK', 'e2'),
  entry(4, 'y', 'HUMAN_TASK', 'e3'),
  entry(5, 'join', 'PARALLEL_GATEWAY', 'e4'),
  entry(6, 'join', 'PARALLEL_GATEWAY', 'e5'),
  entry(7, 'end', 'END', 'e6'),
]

const states = (graph: DefinitionGraph, entries: NodeEnteredItem[], k: number) => {
  const p = replayPath(replaySteps(entries, graph), k, graph)
  return {
    nodes: Object.fromEntries([...p.nodes].map(([id, s]) => [id, s.state])),
    taken: [...p.edges.keys()].sort(),
    basis: [...p.nodes.values()].map((s) => s.basis),
  }
}

describe('T-1635 replaySteps', () => {
  it('R1 lists every entry in recorded order, gateway and END included', () => {
    const steps = replaySteps(
      [entry(1, 'start', 'START', null), entry(2, 'g', 'EXCLUSIVE_GATEWAY', 'l1'), entry(3, 'c', 'HUMAN_TASK', 'l2'), entry(4, 'end', 'END', 'l3')],
      LINEAR,
    )
    expect(steps.map((s) => [s.nodeId, s.nodeType])).toEqual([
      ['start', 'START'],
      ['g', 'EXCLUSIVE_GATEWAY'],
      ['c', 'HUMAN_TASK'],
      ['end', 'END'],
    ])
    expect(steps.map((s) => s.label)).toEqual([null, 'Check', 'Approve', null])
    expect(steps.every((s) => s.known)).toBe(true)
  })

  it('R2 the T-793-3 sequence gives 7 steps; the two join arrivals are separate steps from x and from y', () => {
    const steps = replaySteps(T793_3, PARALLEL)
    expect(steps).toHaveLength(7)
    expect(steps.map((s) => s.nodeId)).toEqual(['start', 'split', 'x', 'y', 'join', 'join', 'end'])
    expect([steps[4]!.fromNodeId, steps[4]!.fromLabel]).toEqual(['x', 'X'])
    expect([steps[5]!.fromNodeId, steps[5]!.fromLabel]).toEqual(['y', 'Y'])
    expect(steps[0]!.fromNodeId).toBeNull()
  })

  it('R3 sorts out-of-order input by sequence number; an unknown node keeps its id and is marked unknown', () => {
    const steps = replaySteps([entry(3, 'gone', 'HUMAN_TASK', 'zz'), entry(1, 'start', 'START', null), entry(2, 'g', 'EXCLUSIVE_GATEWAY', 'l1')], LINEAR)
    expect(steps.map((s) => s.seq)).toEqual([1, 2, 3])
    expect(steps.map((s) => s.index)).toEqual([0, 1, 2])
    expect(steps[2]).toMatchObject({ nodeId: 'gone', known: false, fromNodeId: null })
  })

  it('R6 sincePreviousMs is the gap to the previous step, null for the first', () => {
    const steps = replaySteps(
      [entry(1, 'start', 'START', null, '2026-11-09T10:00:00Z'), entry(2, 'g', 'EXCLUSIVE_GATEWAY', 'l1', '2026-11-09T10:01:05Z')],
      LINEAR,
    )
    expect(steps.map((s) => s.sincePreviousMs)).toEqual([null, 65_000])
    expect(durationParts(65_000)).toEqual({ h: 0, m: 1, s: 5 })
    expect(durationParts(3_725_000)).toEqual({ h: 1, m: 2, s: 5 })
    expect(durationParts(400)).toBeNull()
  })
})

describe('T-1635 replayPath', () => {
  it('R4 entered but not left is active, left is done, END is done, edges taken by via_edge_id, the rest absent', () => {
    const entries = [entry(1, 'start', 'START', null), entry(2, 'g', 'EXCLUSIVE_GATEWAY', 'l1'), entry(3, 'c', 'HUMAN_TASK', 'l2')]
    let s = states(LINEAR, entries, 2)
    expect(s.nodes).toEqual({ start: 'done', g: 'done', c: 'active' })
    expect(s.taken).toEqual(['l1', 'l2'])
    expect(s.basis.every((b) => b === 'evidence')).toBe(true)
    s = states(LINEAR, [...entries, entry(4, 'end', 'END', 'l3')], 3)
    expect(s.nodes).toEqual({ start: 'done', g: 'done', c: 'done', end: 'done' })
    expect(s.taken).toEqual(['l1', 'l2', 'l3'])
    // Arrival alone is never completion.
    expect(states(LINEAR, entries, 0).nodes).toEqual({ start: 'active' })
    expect(replayPath([], 0, LINEAR).nodes.size).toBe(0)
  })

  it('R4b parallel split: after both branches are entered they are both active and the split is done', () => {
    const s = states(PARALLEL, T793_3, 3)
    expect(s.nodes).toEqual({ start: 'done', split: 'done', x: 'active', y: 'active' })
  })

  it('R4c every row of the worked example (k = 0..6)', () => {
    const table: Record<string, string>[] = [
      { start: 'active' },
      { start: 'done', split: 'active' },
      { start: 'done', split: 'done', x: 'active' },
      { start: 'done', split: 'done', x: 'active', y: 'active' },
      { start: 'done', split: 'done', x: 'done', y: 'active', join: 'active' },
      { start: 'done', split: 'done', x: 'done', y: 'done', join: 'active' },
      { start: 'done', split: 'done', x: 'done', y: 'done', join: 'done', end: 'done' },
    ]
    const taken = [[], ['e1'], ['e1', 'e2'], ['e1', 'e2', 'e3'], ['e1', 'e2', 'e3', 'e4'], ['e1', 'e2', 'e3', 'e4', 'e5'], ['e1', 'e2', 'e3', 'e4', 'e5', 'e6']]
    table.forEach((row, k) => {
      const s = states(PARALLEL, T793_3, k)
      expect(s.nodes, `k=${k}`).toEqual(row)
      expect(s.taken, `k=${k}`).toEqual(taken[k])
    })
  })

  it('R4c2 a join fired by cancelling the other branch is done; the cancelled branch stays active', () => {
    const entries = [...T793_3.slice(0, 5), entry(6, 'end', 'END', 'e6')]
    const s = states(PARALLEL, entries, 5)
    expect(s.nodes).toEqual({ start: 'done', split: 'done', x: 'done', y: 'active', join: 'done', end: 'done' })
  })

  it('R4d a via_edge_id not in the graph is no departure: the node stays active', () => {
    const entries = [entry(1, 'start', 'START', null), entry(2, 'c', 'HUMAN_TASK', 'l2'), entry(3, 'end', 'END', 'nope')]
    const s = states(LINEAR, entries, 2)
    expect(s.nodes.c).toBe('active')
    expect(s.taken).toContain('nope')
  })

  it('R5 loop re-entry makes a gateway (recency rule) and an activity (count rule) active again', () => {
    const LOOP = {
      nodes: [node('start', 'START'), node('a', 'HUMAN_TASK', 'A'), node('g', 'EXCLUSIVE_GATEWAY', 'Again?'), node('end', 'END')],
      edges: [
        { id: 'p1', source: 'start', target: 'a' },
        { id: 'p2', source: 'a', target: 'g' },
        { id: 'p3', source: 'g', target: 'a' },
        { id: 'p4', source: 'g', target: 'end' },
      ],
    } as DefinitionGraph
    const entries = [
      entry(1, 'start', 'START', null),
      entry(2, 'a', 'HUMAN_TASK', 'p1'),
      entry(3, 'g', 'EXCLUSIVE_GATEWAY', 'p2'),
      entry(4, 'a', 'HUMAN_TASK', 'p3'),
      entry(5, 'g', 'EXCLUSIVE_GATEWAY', 'p2'),
      entry(6, 'end', 'END', 'p4'),
    ]
    expect(states(LOOP, entries, 3).nodes).toEqual({ start: 'done', a: 'active', g: 'done' })
    expect(states(LOOP, entries, 4).nodes).toEqual({ start: 'done', a: 'done', g: 'active' })
    expect(states(LOOP, entries, 5).nodes).toEqual({ start: 'done', a: 'done', g: 'done', end: 'done' })
  })
})

describe('T-1635 replayCoverage', () => {
  it('R7 none without entries, partial when the first entry is not START, full otherwise', () => {
    expect(replayCoverage(replaySteps([], LINEAR))).toBe('none')
    expect(replayCoverage(replaySteps([entry(5, 'c', 'HUMAN_TASK', 'l2'), entry(6, 'end', 'END', 'l3')], LINEAR))).toBe('partial')
    expect(replayCoverage(replaySteps(T793_3, PARALLEL))).toBe('full')
  })

  it('R7b partial coverage: a node with a departure but no recorded entry stays neutral, its edge is taken', () => {
    const s = states(LINEAR, [entry(5, 'c', 'HUMAN_TASK', 'l2')], 0)
    expect(s.nodes).toEqual({ c: 'active' })
    expect(s.taken).toEqual(['l2'])
  })
})
