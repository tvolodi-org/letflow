// @vitest-environment node
/** T-2042: a harness fixture can answer real bytes (a Blob) and keeps the JSON default. Node env: jsdom's Blob is not one Response can read. */
import { describe, expect, it } from 'vitest'
import { makeFixtureFetch } from '../fixtureFetch'
import type { FixtureRoute } from '../types'

const svg = new Blob(['<svg xmlns="http://www.w3.org/2000/svg"/>'], { type: 'image/svg+xml' })
const routes: FixtureRoute[] = [
  { match: (p) => p === '/img', reply: () => ({ status: 200, body: svg }) },
  { match: (p) => p === '/json', reply: () => ({ status: 200, body: { a: 1 } }) },
]

describe('fixtureFetch binary reply', () => {
  it('returns a Blob body as its own content type, and JSON as before', async () => {
    const f = makeFixtureFetch(routes, 'default')
    const img = await f('/img')
    expect(img.headers.get('Content-Type')).toBe('image/svg+xml')
    expect((await img.blob()).size).toBe(svg.size)
    const json = await f('/json')
    expect(json.headers.get('Content-Type')).toBe('application/json')
    expect(await json.json()).toEqual({ a: 1 })
  })
})
