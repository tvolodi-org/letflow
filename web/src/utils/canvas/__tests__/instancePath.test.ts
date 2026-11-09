/** T-1520 instance path derivation: the worked cases of the design (P1..P16, P3b..P3j, P5a..P5f).
 *  Fixtures use the real API shapes: a GraphNode with a JSON-string `attributes`, timeline items as
 *  `Instances.timeline_item/2` returns them (EXECUTION_ERROR and SUB_PROCESS_COMPLETED carry `node_id: null`). */
import { describe, expect, it } from 'vitest'
import type { DefinitionGraph, NodeType, TimelineEntry } from '@/types/api'
import { deriveInstancePath, timelineEvidence, type PathInstance } from '../instancePath'

/** `g('S:START', 'G:EXCLUSIVE_GATEWAY', ...)(['S>G', 'G>A'])` — edge ids are `S>G`. */
function graph(nodes: string[], edges: string[]): DefinitionGraph {
  return {
    nodes: nodes.map((spec) => {
      const [id, type] = spec.split(':')
      return { id, node_type: (type ?? 'HUMAN_TASK') as NodeType, label: id, attributes: '{}' }
    }),
    edges: edges.map((spec) => {
      const [source, target] = spec.split('>')
      return { id: spec, source, target }
    }),
  }
}

let seq = 0
function ev(event_type: string, node_id: string | null): TimelineEntry {
  seq += 1
  return {
    event_id: `ev-${seq}`,
    event_type,
    sequence_num: seq,
    instance_id: 'i-1',
    timestamp: '2026-11-09T10:00:00Z',
    node_id,
    task_id: null,
    metadata: {},
    actor_display_name: 'Tester',
    description: event_type,
  }
}

function completed(...ids: string[]): TimelineEntry[] {
  return [ev('INSTANCE_STARTED', null), ...ids.map((id) => ev('TASK_COMPLETED', id))]
}

function run(g: DefinitionGraph, inst: PathInstance, entries: TimelineEntry[], complete = true) {
  const p = deriveInstancePath(g, inst, timelineEvidence(entries, { complete }))
  return {
    n: (id: string) => p.nodes.get(id)?.state,
    basis: (id: string) => p.nodes.get(id)?.basis,
    e: (id: string) => p.edges.get(id),
    notes: p.notes,
    path: p,
  }
}

const active = (...current: string[]): PathInstance => ({ status: 'ACTIVE', current_nodes: current })
const COMPLETED: PathInstance = { status: 'COMPLETED', current_nodes: [] }

describe('deriveInstancePath', () => {
  it('P1 active node', () => {
    const r = run(graph(['S:START', 'A', 'E:END'], ['S>A', 'A>E']), active('A'), completed())
    expect(r.n('A')).toBe('active')
    expect(r.n('S')).toBe('done')
    expect(r.e('S>A')).toBe('taken')
    expect(r.n('E')).toBe('pending')
    expect(r.e('A>E')).toBe('untaken')
  })

  it('P2 START and gateway inferred done', () => {
    const r = run(graph(['S:START', 'G:EXCLUSIVE_GATEWAY', 'A', 'B'], ['S>G', 'G>A', 'G>B']), active('A'), completed())
    expect(r.n('G')).toBe('done')
    expect(r.basis('G')).toBe('inferred')
    expect(r.e('G>A')).toBe('taken')
    expect(r.e('G>B')).toBe('untaken')
    expect(r.n('B')).toBe('skipped')
  })

  it('P3 reconverged exclusive branch', () => {
    const g = graph(
      ['S:START', 'X:EXCLUSIVE_GATEWAY', 'A', 'B', 'J:EXCLUSIVE_GATEWAY', 'C'],
      ['S>X', 'X>A', 'X>B', 'A>J', 'B>J', 'J>C'],
    )
    const r = run(g, active('C'), completed('A'))
    expect(r.n('A')).toBe('done')
    expect(r.n('B')).toBe('skipped')
    expect(r.n('J')).toBe('done')
    expect([r.e('X>A'), r.e('A>J')]).toEqual(['taken', 'taken'])
    expect([r.e('X>B'), r.e('B>J')]).toEqual(['untaken', 'untaken'])
  })

  it('P3b gateway-only reconvergence stays unclear, never two taken', () => {
    const g = graph(
      ['S:START', 'G:EXCLUSIVE_GATEWAY', 'H1:EXCLUSIVE_GATEWAY', 'H2:EXCLUSIVE_GATEWAY', 'C', 'E:END'],
      ['S>G', 'G>H1', 'G>H2', 'H1>C', 'H2>C', 'C>E'],
    )
    const r = run(g, active('C'), completed())
    expect(r.n('G')).toBe('done')
    expect([r.n('H1'), r.n('H2')]).toEqual(['unclear', 'unclear'])
    expect(r.e('S>G')).toBe('taken')
    for (const id of ['G>H1', 'G>H2', 'H1>C', 'H2>C']) expect(r.e(id)).toBe('unclear')
  })

  it('P3c parallel fork with pass-through branches, COMPLETED', () => {
    const g = graph(
      ['S:START', 'P:PARALLEL_GATEWAY', 'X1:EXCLUSIVE_GATEWAY', 'X2:EXCLUSIVE_GATEWAY', 'J:PARALLEL_GATEWAY', 'E:END'],
      ['S>P', 'P>X1', 'P>X2', 'X1>J', 'X2>J', 'J>E'],
    )
    const r = run(g, COMPLETED, completed())
    expect([r.n('P'), r.n('J'), r.n('E')]).toEqual(['done', 'done', 'done'])
    expect([r.n('X1'), r.n('X2')]).toEqual(['unclear', 'unclear'])
  })

  it("P3c' same shape ACTIVE with J → C active", () => {
    const g = graph(
      ['S:START', 'P:PARALLEL_GATEWAY', 'X1:EXCLUSIVE_GATEWAY', 'X2:EXCLUSIVE_GATEWAY', 'J:PARALLEL_GATEWAY', 'C'],
      ['S>P', 'P>X1', 'P>X2', 'X1>J', 'X2>J', 'J>C'],
    )
    const r = run(g, active('C'), completed())
    expect([r.n('P'), r.n('J')]).toEqual(['done', 'done'])
    expect(r.e('J>C')).toBe('taken')
    expect([r.n('X1'), r.n('X2')]).toEqual(['unclear', 'unclear'])
    expect(r.notes).toEqual([])
  })

  it('P3d two competing paths share only a cut vertex', () => {
    const g = graph(
      ['S:START', 'G:EXCLUSIVE_GATEWAY', 'H1:EXCLUSIVE_GATEWAY', 'H2:EXCLUSIVE_GATEWAY', 'M:EXCLUSIVE_GATEWAY', 'C'],
      ['S>G', 'G>H1', 'G>H2', 'H1>M', 'H2>M', 'M>C'],
    )
    const r = run(g, active('C'), completed())
    expect([r.n('G'), r.n('M')]).toEqual(['done', 'done'])
    expect([r.n('H1'), r.n('H2')]).toEqual(['unclear', 'unclear'])
    expect(r.e('M>C')).toBe('taken')
  })

  const p3e = () => graph(['S:START', 'G:EXCLUSIVE_GATEWAY', 'A', 'C', 'E:END'], ['S>G', 'G>A', 'A>C', 'G>C', 'C>E'])

  it('P3e (gate case) the direct G→C edge is untaken', () => {
    const r = run(p3e(), active('C'), completed('A'))
    expect([r.e('S>G'), r.e('G>A'), r.e('A>C')]).toEqual(['taken', 'taken', 'taken'])
    expect(r.n('G')).toBe('done')
    expect(r.e('G>C')).toBe('untaken')
  })

  it("P3e' no completion for A: G→C taken, A skipped", () => {
    const r = run(p3e(), active('C'), completed())
    expect([r.e('S>G'), r.e('G>C')]).toEqual(['taken', 'taken'])
    expect(r.e('G>A')).toBe('untaken')
    expect(r.n('A')).toBe('skipped')
  })

  it('P3f contradiction: two sole segments into C with entries 1', () => {
    const g = graph(['S:START', 'P:PARALLEL_GATEWAY', 'A', 'B', 'C'], ['S>P', 'P>A', 'P>B', 'A>C', 'B>C'])
    const r = run(g, active('C'), completed('A', 'B'))
    expect(r.notes).toContain('notReconciled')
    expect(r.e('A>C')).toBe('unclear')
    expect(r.n('P')).toBe('unclear')
  })

  const p3h = (extra: string[] = [], extraEdges: string[] = ['J>C', 'C>E']) =>
    graph(
      ['S:START', 'P:PARALLEL_GATEWAY', 'A', 'B', 'J:PARALLEL_GATEWAY', 'C', 'E:END', ...extra],
      ['S>P', 'P>A', 'P>B', 'A>J', 'B>J', ...extraEdges],
    )

  it('P3g parallel join still waiting', () => {
    const r = run(p3h(), active('B'), completed('A'))
    expect(r.e('A>J')).toBe('taken')
    expect(r.n('J')).toBe('pending')
    expect(r.e('J>C')).toBe('untaken')
    expect(r.notes).toEqual([])
  })

  it('P3h (gate case) fired join is attributed from downstream evidence', () => {
    const r = run(p3h(), active('C'), completed('A', 'B'))
    expect(r.n('P')).toBe('done')
    for (const id of ['S>P', 'P>A', 'P>B', 'A>J', 'B>J', 'J>C']) expect(r.e(id)).toBe('taken')
    expect(r.n('J')).toBe('done')
    expect(r.basis('J')).toBe('inferred')
    expect(r.n('C')).toBe('active')
    expect(r.n('E')).toBe('pending')
    expect(r.notes).toEqual([])
  })

  it("P3h' C completed and D active", () => {
    const r = run(p3h(['D'], ['J>C', 'C>D', 'D>E']), active('D'), completed('A', 'B', 'C'))
    expect(r.n('J')).toBe('done')
    expect([r.e('J>C'), r.e('C>D')]).toEqual(['taken', 'taken'])
  })

  it('P3h-SP sub-process between the join and the next node', () => {
    const g = p3h(['SP:SUB_PROCESS'], ['J>SP', 'SP>C', 'C>E'])
    const running = run(g, active('SP'), completed('A', 'B'))
    expect(running.n('J')).toBe('done')
    expect(running.e('J>SP')).toBe('taken')
    const finished = run(g, active('C'), [...completed('A', 'B'), ev('SUB_PROCESS_COMPLETED', null)])
    expect(finished.n('SP')).toBe('done')
    expect([finished.e('J>SP'), finished.e('SP>C')]).toEqual(['taken', 'taken'])
    expect(finished.n('J')).toBe('done')
  })

  it('P3h-TM timer between the join and the next node', () => {
    const g = p3h(['TM:TIMER'], ['J>TM', 'TM>C', 'C>E'])
    const waiting = run(g, active('TM'), completed('A', 'B'))
    expect(waiting.n('J')).toBe('done')
    expect(waiting.e('J>TM')).toBe('taken')
    const fired = run(g, active('C'), [...completed('A', 'B'), ev('TIMER_FIRED', 'TM')])
    expect(fired.n('J')).toBe('done')
    expect([fired.e('J>TM'), fired.e('TM>C')]).toEqual(['taken', 'taken'])
  })

  it('P3i zero-segment contradiction', () => {
    const g = graph(['S:START', 'G:EXCLUSIVE_GATEWAY', 'D', 'C'], ['S>G', 'G>D', 'D>C'])
    const r = run(g, active('C'), completed())
    expect(r.notes).toContain('notReconciled')
    expect(r.n('G')).toBe('unclear')
    expect(r.e('S>G')).toBe('unclear')
  })

  it('P3j ERROR on the P3h shape', () => {
    const inst: PathInstance = {
      status: 'ERROR',
      current_nodes: ['C'],
      error_detail: { error_type: 'script_error', affected: { kind: 'node', node_id: 'C' }, reason: 'boom' },
    }
    const r = run(p3h(), inst, completed('A', 'B'))
    for (const id of ['S>P', 'P>A', 'P>B', 'A>J', 'B>J', 'J>C']) expect(r.e(id)).toBe('taken')
    expect(r.n('J')).toBe('done')
    expect(r.n('C')).toBe('error')
  })

  it('P4 parallel fork: completed branches done, an unreached branch is pending', () => {
    const g = graph(
      ['S:START', 'P:PARALLEL_GATEWAY', 'A', 'B', 'K', 'J:PARALLEL_GATEWAY', 'E:END'],
      ['S>P', 'P>A', 'P>B', 'P>K', 'A>J', 'B>J', 'K>J', 'J>E'],
    )
    const r = run(g, active('B'), completed('A'))
    expect(r.n('A')).toBe('done')
    expect(r.n('K')).toBe('pending')
    const done = run(g, COMPLETED, completed('A', 'B', 'K'))
    expect([done.n('J'), done.n('E')]).toEqual(['done', 'done'])
    expect(done.e('J>E')).toBe('taken')
  })

  const loop = () => graph(['S:START', 'A', 'G:EXCLUSIVE_GATEWAY', 'E:END'], ['S>A', 'A>G', 'G>A', 'G>E'])

  it('P5a loop ran once, COMPLETED', () => {
    const r = run(loop(), COMPLETED, completed('A'))
    expect([r.n('G'), r.n('E')]).toEqual(['done', 'done'])
    expect([r.e('A>G'), r.e('G>E')]).toEqual(['taken', 'taken'])
    expect(r.e('G>A')).toBe('untaken')
  })

  it('P5b loop ran twice, COMPLETED', () => {
    const r = run(loop(), COMPLETED, completed('A', 'A'))
    expect([r.e('G>A'), r.e('G>E')]).toEqual(['taken', 'taken'])
  })

  it('P5c re-entry while ACTIVE', () => {
    const r = run(loop(), active('A'), completed('A'))
    expect(r.e('G>A')).toBe('taken')
    expect(r.e('G>E')).toBe('untaken')
    expect(r.n('E')).toBe('pending')
  })

  it('P5d two loop-back candidates stay unclear', () => {
    const g = graph(
      ['S:START', 'A', 'G1:EXCLUSIVE_GATEWAY', 'G2:EXCLUSIVE_GATEWAY', 'E:END'],
      ['S>A', 'A>G1', 'G1>A', 'G1>G2', 'G2>A', 'G2>E'],
    )
    const r = run(g, COMPLETED, completed('A', 'A'))
    expect([r.e('G1>A'), r.e('G2>A')]).toEqual(['unclear', 'unclear'])
    expect([r.e('A>G1'), r.e('G1>G2'), r.e('G2>E')]).toEqual(['taken', 'taken', 'taken'])
  })

  it('P5e incomplete evidence makes every segment edge unclear', () => {
    const r = run(loop(), COMPLETED, completed('A'), false)
    expect([r.e('A>G'), r.e('G>A'), r.e('G>E')]).toEqual(['unclear', 'unclear', 'unclear'])
    expect(r.notes).toContain('historyIncomplete')
  })

  const p5f = () => graph(['S:START', 'G:EXCLUSIVE_GATEWAY', 'A', 'E:END'], ['S>G', 'G>A', 'A>G', 'G>E'])

  it('P5f task-sourced back edge into a gateway', () => {
    const twice = run(p5f(), COMPLETED, completed('A', 'A'))
    for (const id of ['S>G', 'G>A', 'A>G', 'G>E']) expect(twice.e(id)).toBe('taken')
    const once = run(p5f(), COMPLETED, completed('A'))
    for (const id of ['S>G', 'G>A', 'A>G', 'G>E']) expect(once.e(id)).toBe('taken')
  })

  it('P6 COMPLETED with a single END: END done (inferred)', () => {
    const r = run(graph(['S:START', 'A', 'E:END'], ['S>A', 'A>E']), COMPLETED, completed('A'))
    expect(r.n('E')).toBe('done')
    expect(r.basis('E')).toBe('inferred')
  })

  it('P7 COMPLETED with two ENDs and no evidence: both unclear', () => {
    const g = graph(['S:START', 'X:EXCLUSIVE_GATEWAY', 'E1:END', 'E2:END'], ['S>X', 'X>E1', 'X>E2'])
    const r = run(g, COMPLETED, completed())
    expect([r.n('E1'), r.n('E2')]).toEqual(['unclear', 'unclear'])
    expect([r.e('X>E1'), r.e('X>E2')]).toEqual(['unclear', 'unclear'])
  })

  const two = () => graph(['S:START', 'P:PARALLEL_GATEWAY', 'A', 'B'], ['S>P', 'P>A', 'P>B'])

  it('P8 ERROR attributed to a node among two current nodes', () => {
    const inst: PathInstance = {
      status: 'ERROR',
      current_nodes: ['A', 'B'],
      error_detail: { affected: { kind: 'node', node_id: 'B' }, reason: 'x' },
    }
    const r = run(two(), inst, completed())
    expect(r.n('B')).toBe('error')
    expect(r.n('A')).toBe('pending')
  })

  it('P9 ERROR on a field or with no affected: no error node, current nodes unclear, note', () => {
    for (const detail of [{ affected: { kind: 'field', key: 'amount' } }, {}]) {
      const r = run(two(), { status: 'ERROR', current_nodes: ['A', 'B'], error_detail: detail }, completed())
      expect([r.n('A'), r.n('B')]).toEqual(['unclear', 'unclear'])
      expect(r.notes).toContain('errorNotAttributed')
    }
  })

  it('P10 an EXECUTION_ERROR timeline entry (node_id null) is not used for attribution', () => {
    const evidence = timelineEvidence([ev('INSTANCE_STARTED', null), ev('EXECUTION_ERROR', null)], { complete: true })
    expect(evidence.completions.size).toBe(0)
  })

  it('P11 CANCELLED: current nodes are not drawn active', () => {
    const r = run(graph(['S:START', 'A', 'E:END'], ['S>A', 'A>E']), { status: 'CANCELLED', current_nodes: ['A'] }, completed())
    expect(r.n('A')).toBe('pending')
    expect(r.notes).toContain('cancelled')
  })

  it('P12 no timeline, only current_nodes', () => {
    const r = run(graph(['S:START', 'A', 'B'], ['S>A', 'A>B']), active('A'), [])
    expect(r.n('S')).toBe('done')
    expect(r.e('S>A')).toBe('taken')
    expect(r.n('B')).toBe('pending')
  })

  it('P13 unknown ids are ignored', () => {
    const r = run(graph(['S:START', 'A'], ['S>A']), active('A', 'ghost'), [...completed(), ev('TASK_COMPLETED', 'nope')])
    expect(r.path.nodes.has('ghost')).toBe(false)
    expect(r.n('A')).toBe('active')
  })

  it('P14 incomplete evidence downgrades inferred states, evidence stays', () => {
    const g = graph(['S:START', 'G:EXCLUSIVE_GATEWAY', 'A', 'B'], ['S>G', 'G>A', 'A>B'])
    const r = run(g, active('B'), completed('A'), false)
    expect(r.n('G')).toBe('unclear')
    expect(r.n('A')).toBe('done')
    expect(r.n('B')).toBe('active')
  })

  it('P15 SUB_PROCESS between two evidenced nodes is done (inferred)', () => {
    const g = graph(['S:START', 'A', 'SP:SUB_PROCESS', 'B'], ['S>A', 'A>SP', 'SP>B'])
    const r = run(g, active('B'), [...completed('A'), ev('SUB_PROCESS_COMPLETED', null)])
    expect(r.n('SP')).toBe('done')
    expect(r.basis('SP')).toBe('inferred')
  })

  it('P16 a 400-node graph with a 50-way fan derives quickly', () => {
    const nodes = ['S:START', 'G:EXCLUSIVE_GATEWAY']
    const edges: string[] = []
    for (let i = 0; i < 50; i++) {
      nodes.push(`F${i}`)
      edges.push(`G>F${i}`, `F${i}>M`)
    }
    nodes.push('M:EXCLUSIVE_GATEWAY')
    edges.push('S>G', 'M>C0')
    for (let i = 0; i < 345; i++) {
      nodes.push(`C${i}`)
      if (i > 0) edges.push(`C${i - 1}>C${i}`)
    }
    const g = graph(nodes, edges)
    const done = Array.from({ length: 200 }, (_, i) => `C${i}`)
    const t0 = performance.now()
    const r = run(g, active('C200'), completed('F7', ...done))
    expect(performance.now() - t0).toBeLessThan(300)
    expect(r.e('G>F7')).toBe('taken')
    expect(r.n('F8')).toBe('skipped')
  })
})
