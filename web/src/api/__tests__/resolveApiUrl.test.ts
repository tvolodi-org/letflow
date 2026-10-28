// @vitest-environment jsdom
/**
 * REQ-591 (GH #3337): resolveApiUrl prefixes the build-time API origin onto /api/ paths
 * (the uploaded-logo `logo_url`) and leaves every other URL unchanged.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'

async function loadResolve(base: string) {
  vi.resetModules()
  vi.stubEnv('VITE_API_BASE_URL', base)
  return (await import('../client')).resolveApiUrl
}

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('resolveApiUrl', () => {
  it('V1: an empty base leaves the path unchanged', async () => {
    const resolve = await loadResolve('')
    expect(resolve('/api/tenant-config/logo?slug=a')).toBe('/api/tenant-config/logo?slug=a')
  })

  it('V2: a set base is prefixed onto an /api/ path', async () => {
    const resolve = await loadResolve('http://localhost:4000')
    expect(resolve('/api/tenant-config/logo?slug=a')).toBe(
      'http://localhost:4000/api/tenant-config/logo?slug=a',
    )
  })

  it('V3: an absolute URL is unchanged whatever the base', async () => {
    const resolve = await loadResolve('http://localhost:4000')
    expect(resolve('https://cdn.example/x.png')).toBe('https://cdn.example/x.png')
  })
})
