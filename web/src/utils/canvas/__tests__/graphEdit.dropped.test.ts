import { describe, it, expect } from 'vitest'
import { droppedTargets } from '../graphEdit'
import type { DefinitionGraph } from '@/types/api'

const g = {
  nodes: [{ id: 's' }, { id: 'a' }, { id: 'e' }],
  edges: [{ id: 'e1', source: 's', target: 'e' }],
} as unknown as DefinitionGraph

describe('T-2815 D9 droppedTargets', () => {
  it('names a target that the result no longer connects', () => {
    const after = { ok: true as const, graph: { ...g, edges: [{ id: 'e2', source: 's', target: 'a' }] } }
    expect(droppedTargets(g, after, 's')).toEqual(['e'])
  })
  it('is empty when the old connection stays or the edit was refused', () => {
    const kept = { ok: true as const, graph: { ...g, edges: [...g.edges, { id: 'e2', source: 's', target: 'a' }] } }
    expect(droppedTargets(g, kept, 's')).toEqual([])
    expect(droppedTargets(g, { ok: false as const, reason: 'self_loop' }, 's')).toEqual([])
  })
})
