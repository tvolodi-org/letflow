// @vitest-environment jsdom
/** REQ-631 part A — A1/A2: the overrides client calls only the four REQ-596 paths, with no tenant id. */
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('../client', () => ({
  client: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

import { client } from '../client'
import { solutionPacksApi } from '../solutionPacks'

const c = vi.mocked(client)

afterEach(() => vi.clearAllMocks())

describe('REQ-631 solutionPacksApi overrides', () => {
  it('A1 listOverrides is GET /overrides', async () => {
    c.get.mockResolvedValue({ overrides: [] })
    await solutionPacksApi.listOverrides('pack-a')
    expect(c.get).toHaveBeenCalledWith('/api/v1/solution-packs/pack-a/overrides')
  })

  it('A1 createOverride is POST /overrides with the body', async () => {
    c.post.mockResolvedValue({})
    const body = { artefact_type: 'process_definition', artefact_id: 'd1', patch: { a: 1 }, reason: 'why' }
    await solutionPacksApi.createOverride('pack-a', body)
    expect(c.post).toHaveBeenCalledWith('/api/v1/solution-packs/pack-a/overrides', body)
  })

  it('A1 newOverrideVersion is POST /:id/versions', async () => {
    c.post.mockResolvedValue({})
    const body = { patch: { a: 2 }, reason: 'again', base_version: 1 }
    await solutionPacksApi.newOverrideVersion('pack-a', 'o1', body)
    expect(c.post).toHaveBeenCalledWith('/api/v1/solution-packs/pack-a/overrides/o1/versions', body)
  })

  it('A1 retireOverride is POST /:id/retire', async () => {
    c.post.mockResolvedValue({})
    const body = { reason: 'done', base_version: 2 }
    await solutionPacksApi.retireOverride('pack-a', 'o1', body)
    expect(c.post).toHaveBeenCalledWith('/api/v1/solution-packs/pack-a/overrides/o1/retire', body)
  })

  it('A2 ids are URL-encoded and no request carries a tenant id', async () => {
    c.get.mockResolvedValue({ overrides: [] })
    c.post.mockResolvedValue({})
    await solutionPacksApi.listOverrides('a/b c')
    await solutionPacksApi.createOverride('a/b c', { artefact_type: 't', artefact_id: 'x', patch: {}, reason: 'r' })
    await solutionPacksApi.newOverrideVersion('a/b c', 'o/1', { patch: {}, reason: 'r' })
    await solutionPacksApi.retireOverride('a/b c', 'o/1', { reason: 'r' })
    const calls = [...c.get.mock.calls, ...c.post.mock.calls]
    expect(calls).toHaveLength(4)
    for (const call of calls) {
      expect(call[0]).toContain('/solution-packs/a%2Fb%20c/overrides')
      expect(JSON.stringify(call)).not.toMatch(/tenant/i)
    }
    expect(c.post.mock.calls[1][0]).toContain('/overrides/o%2F1/versions')
  })

  it('A2 the module uses no put, patch or delete', () => {
    const src = readFileSync(path.join(__dirname, '..', 'solutionPacks.ts'), 'utf-8')
    expect(src).not.toMatch(/client\.(put|patch|delete)\b/)
  })
})
