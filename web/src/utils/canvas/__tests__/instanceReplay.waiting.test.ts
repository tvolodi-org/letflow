/** T-1705 (REQ-812) waitingSince / elapsedParts. U-W2-*: which nodes wait; U-W3-*: since when and in which order;
 *  U-W4-elapsed: the elapsed parts. Graphs copy the shapes of instanceReplay.test.ts (T-793-3 parallel graph). */
import { describe, expect, it } from 'vitest'
import type { DefinitionGraph, NodeEnteredItem } from '@/types/api'
import { elapsedParts, replaySteps, waitingSince } from '../instanceReplay'

const entry = (seq: number, node_id: string, node_type: string, via_edge_id: string | null, created_at: string): NodeEnteredItem => ({
  event_id: `ev-${seq}`,
  sequence_number: seq,
  created_at,
  payload: { node_id, node_type, via_edge_id },
})
const node = (id: string, node_type: string, label: string | null = null) => ({ id, node_type, label, attributes: null })
const T = (s: string) => `2026-11-09T10:${s}Z`

const LINEAR = {
  nodes: [node('start', 'START'), node('g', 'EXCLUSIVE_GATEWAY', 'Check'), node('c', 'HUMAN_TASK', 'Approve'), node('end', 'END')],
  edges: [
    { id: 'l1', source: 'start', target: 'g' },
    { id: 'l2', source: 'g', target: 'c' },
    { id: 'l3', source: 'c', target: 'end' },
  ],
} as DefinitionGraph

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

const rows = (g: DefinitionGraph, entries: NodeEnteredItem[]) => waitingSince(replaySteps(entries, g), g)

describe('T-1705 waitingSince', () => {
  it('U-W2-empty no steps, no rows', () => {
    expect(rows(PARALLEL, [])).toEqual([])
  })

  it('U-W2-one-task a task entered and not left waits; a finished run waits nowhere', () => {
    const run = [entry(1, 'start', 'START', null, T('00:00')), entry(2, 'g', 'EXCLUSIVE_GATEWAY', 'l1', T('00:01')), entry(3, 'c', 'HUMAN_TASK', 'l2', T('00:02'))]
    expect(rows(LINEAR, run).map((r) => r.nodeId)).toEqual(['c'])
    expect(rows(LINEAR, [...run, entry(4, 'end', 'END', 'l3', T('05:00'))])).toEqual([])
  })

  it('U-W2-two-branches two open branches give two rows; a branch that reached the join is replaced by the join', () => {
    const run = [
      entry(1, 'start', 'START', null, T('00:00')),
      entry(2, 'split', 'PARALLEL_GATEWAY', 'e1', T('00:00')),
      entry(3, 'x', 'HUMAN_TASK', 'e2', T('00:00')),
      entry(4, 'y', 'HUMAN_TASK', 'e3', T('00:00')),
    ]
    expect(rows(PARALLEL, run).map((r) => r.nodeId)).toEqual(['x', 'y'])
    const xDone = [...run, entry(5, 'join', 'PARALLEL_GATEWAY', 'e4', T('05:30'))]
    expect(rows(PARALLEL, xDone).map((r) => r.nodeId).sort()).toEqual(['join', 'y'])
  })

  it('U-W2-join-one-arrival / U-W3-join-time a join with two arrivals is one row at its first arrival', () => {
    const run = [
      entry(1, 'start', 'START', null, T('00:00')),
      entry(2, 'split', 'PARALLEL_GATEWAY', 'e1', T('00:00')),
      entry(3, 'x', 'HUMAN_TASK', 'e2', T('00:00')),
      entry(4, 'y', 'HUMAN_TASK', 'e3', T('00:00')),
      entry(5, 'join', 'PARALLEL_GATEWAY', 'e4', T('05:30')),
      entry(6, 'join', 'PARALLEL_GATEWAY', 'e5', T('09:00')),
    ]
    // After the second arrival the join has not fired yet (no departure): still waiting, since its first arrival.
    const join = rows(PARALLEL, run).filter((r) => r.nodeId === 'join')
    expect(join).toHaveLength(1)
    expect(join[0]!.at.toISOString()).toBe('2026-11-09T10:05:30.000Z')
    expect(join[0]!.seq).toBe(5)
  })

  it('U-W3-join-time a join that fired and is entered again takes the first entry after its last departure', () => {
    const g = {
      nodes: [node('start', 'START'), node('j', 'PARALLEL_GATEWAY', 'J'), node('t', 'HUMAN_TASK', 'T')],
      edges: [
        { id: 'a', source: 'start', target: 'j' },
        { id: 'b', source: 'j', target: 't' },
        { id: 'c', source: 't', target: 'j' },
      ],
    } as DefinitionGraph
    const run = [
      entry(1, 'start', 'START', null, T('00:00')),
      entry(2, 'j', 'PARALLEL_GATEWAY', 'a', T('00:01')),
      entry(3, 't', 'HUMAN_TASK', 'b', T('00:02')),
      entry(4, 'j', 'PARALLEL_GATEWAY', 'c', T('09:00')),
      entry(5, 'j', 'PARALLEL_GATEWAY', 'c', T('09:30')),
    ]
    const r = rows(g, run)
    expect(r.map((x) => x.nodeId)).toEqual(['j'])
    expect(r[0]!.seq).toBe(4)
  })

  it('U-W2-loop / U-W3-loop-time a task entered again after being left is one row at its last entry', () => {
    const g = {
      nodes: [node('start', 'START'), node('t', 'HUMAN_TASK', 'T'), node('u', 'HUMAN_TASK', 'U')],
      edges: [
        { id: 'a', source: 'start', target: 't' },
        { id: 'b', source: 't', target: 'u' },
        { id: 'c', source: 'u', target: 't' },
      ],
    } as DefinitionGraph
    const run = [
      entry(1, 'start', 'START', null, T('00:00')),
      entry(2, 't', 'HUMAN_TASK', 'a', T('00:01')),
      entry(3, 'u', 'HUMAN_TASK', 'b', T('01:00')),
      entry(4, 't', 'HUMAN_TASK', 'c', T('02:00')),
    ]
    const r = rows(g, run)
    expect(r.map((x) => x.nodeId)).toEqual(['t'])
    expect(r[0]!.seq).toBe(4)
  })

  it('U-W3-order oldest first, equal times by sequence number, unparseable time last, unknown node known=false', () => {
    const run = [
      entry(1, 'start', 'START', null, T('00:00')),
      entry(2, 'split', 'PARALLEL_GATEWAY', 'e1', T('00:00')),
      entry(3, 'y', 'HUMAN_TASK', 'e3', T('07:00')),
      entry(4, 'x', 'HUMAN_TASK', 'e2', T('07:00')),
      entry(5, 'ghost', 'HUMAN_TASK', null, 'not a date'),
    ]
    const r = rows(PARALLEL, run)
    expect(r.map((x) => x.nodeId)).toEqual(['y', 'x', 'ghost'])
    expect(r[2]!.known).toBe(false)
  })

  it('U-W4-elapsed whole hours and minutes, clamped, hours never fold into days', () => {
    expect(elapsedParts(0)).toEqual({ h: 0, m: 0 })
    expect(elapsedParts(59_999)).toEqual({ h: 0, m: 0 })
    expect(elapsedParts(59 * 60_000)).toEqual({ h: 0, m: 59 })
    expect(elapsedParts(60 * 60_000)).toEqual({ h: 1, m: 0 })
    expect(elapsedParts(25 * 3_600_000)).toEqual({ h: 25, m: 0 })
    expect(elapsedParts((2 * 60 + 5) * 60_000)).toEqual({ h: 2, m: 5 })
    expect(elapsedParts(-5000)).toEqual({ h: 0, m: 0 })
    expect(elapsedParts(Number.NaN)).toEqual({ h: 0, m: 0 })
  })
})
