/** Drift guard: the Playwright copy of the R1 no-uuid check equals src/test-utils/noUuidInDom.ts (T-1383). */
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { UUID_PATTERN } from '@/test-utils/noUuidInDom'
import { READABLE_ATTRIBUTES, UUID_PATTERN_SOURCE } from '../e2e/support/noUuid'

describe('e2e no-uuid helper', () => {
  it('uses the same pattern as the vitest helper', () => {
    expect(UUID_PATTERN_SOURCE).toBe(UUID_PATTERN.source)
  })

  it('reads the same attributes as the vitest helper', () => {
    const src = readFileSync('src/test-utils/noUuidInDom.ts', 'utf8')
    const m = /const ATTRIBUTES = \[([^\]]*)\]/.exec(src)
    expect(m).not.toBeNull()
    const attrs = (m?.[1] ?? '').split(',').map((s) => s.trim().replace(/^'|'$/g, ''))
    expect(READABLE_ATTRIBUTES).toEqual(attrs)
  })

  it('matches a uuid and ignores plain text', () => {
    const re = new RegExp(UUID_PATTERN_SOURCE, 'i')
    expect(re.test('x 0b1c2d3e-1111-4222-8333-444455556666 y')).toBe(true)
    expect(re.test('Central warehouse 2026-11-06')).toBe(false)
  })
})
