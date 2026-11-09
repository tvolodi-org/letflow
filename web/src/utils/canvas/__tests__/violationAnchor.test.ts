import { describe, expect, it } from 'vitest'
import type { DefinitionGraph } from '@/types/api'
import { anchorViolation } from '../violationAnchor'

const g: DefinitionGraph = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'gw', node_type: 'EXCLUSIVE_GATEWAY', label: null, attributes: null },
    { id: 'x', node_type: 'HUMAN_TASK', label: null, attributes: null },
  ],
  edges: [{ id: 'e1', source: 'gw', target: 'x' }],
}
const v = (message: string) => ({ code: 'c', message })

describe('anchorViolation', () => {
  it('M1 the gateway-condition message anchors to edge and node (existing mapper)', () => {
    const r = anchorViolation(v("Edge 'e1' (from EXCLUSIVE_GATEWAY node 'gw') condition references 'q'"), g)
    expect(r).toMatchObject({ edgeId: 'e1', nodeId: 'gw' })
  })
  it('M2 a node message anchors to the node', () => {
    expect(anchorViolation(v("Node 'x' (HUMAN_TASK) is missing a non-empty 'role' attribute"), g).nodeId).toBe('x')
  })
  it('M3 an edge message anchors to the edge', () => {
    expect(anchorViolation(v("Edge 'e1' has dangling target 'ghost'"), g).edgeId).toBe('e1')
  })
  it('M4 a cycle message anchors to its source node', () => {
    expect(anchorViolation(v("Cycle detected: edge from node 'gw' to node 'x'"), g).nodeId).toBe('gw')
  })
  it('M5 an id that is not in the draft is not anchored (and the message is kept)', () => {
    const r = anchorViolation(v("Node 'zzz' (HUMAN_TASK) is odd"), g)
    expect(r.nodeId).toBeUndefined()
    expect(r.message).toContain('zzz')
  })
  it('M6 graph-level messages are unanchored', () => {
    const r = anchorViolation(v('Graph has no END node'), g)
    expect(r.nodeId).toBeUndefined()
    expect(r.edgeId).toBeUndefined()
  })
})
