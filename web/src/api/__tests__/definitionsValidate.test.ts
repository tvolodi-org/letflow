import { beforeEach, describe, expect, it, vi } from 'vitest'

const post = vi.fn()
vi.mock('../client', () => ({ client: { post: (...a: unknown[]) => post(...a), get: vi.fn(), patch: vi.fn(), put: vi.fn(), delete: vi.fn() } }))

import { definitionsApi } from '../definitions'

describe('definitionsApi.validate', () => {
  beforeEach(() => post.mockReset())
  it('sends no body for the stored graph', async () => {
    await definitionsApi.validate('d1')
    expect(post).toHaveBeenCalledWith('/api/v1/definitions/d1/validate')
  })
  it('sends {graph} for a draft graph', async () => {
    const graph = { nodes: [], edges: [] }
    await definitionsApi.validate('d1', graph)
    expect(post).toHaveBeenCalledWith('/api/v1/definitions/d1/validate', { graph })
  })
})
