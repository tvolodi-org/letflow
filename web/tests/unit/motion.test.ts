// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { prefersReducedMotion } from '../../src/lib/motion'

const SRC = join(__dirname, '../../src')

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) {
      if (name !== '__tests__') walk(p, out)
    } else if (/\.(ts|tsx)$/.test(name) && !/\.test\./.test(name)) out.push(p)
  }
  return out
}

afterEach(() => vi.unstubAllGlobals())

describe('reduced motion', () => {
  it('M1: prefersReducedMotion follows the media query and tolerates a missing matchMedia', () => {
    vi.stubGlobal('matchMedia', (q: string) => ({ matches: q.includes('reduce') }))
    expect(prefersReducedMotion()).toBe(true)
    vi.stubGlobal('matchMedia', () => ({ matches: false }))
    expect(prefersReducedMotion()).toBe(false)
    vi.stubGlobal('matchMedia', undefined)
    expect(prefersReducedMotion()).toBe(false)
  })

  it('M2: the stylesheet kills transitions and animations under reduce, and JS durations ask first', () => {
    const css = readFileSync(join(SRC, 'styles/components.css'), 'utf8')
    const reduce = css.slice(css.indexOf('prefers-reduced-motion: reduce'))
    expect(reduce).toContain('animation: none !important')
    expect(reduce).toContain('transition: none !important')
    for (const f of readdirSync(join(SRC, 'styles')).filter((n) => n.endsWith('.css') && n !== 'components.css' && n !== 'tokens.css')) {
      const s = readFileSync(join(SRC, 'styles', f), 'utf8')
      if (/@keyframes|animation:/.test(s)) expect(s, f).toContain('prefers-reduced-motion')
    }
    for (const file of walk(SRC)) {
      const s = readFileSync(file, 'utf8')
      if (/\bduration:\s*\d/.test(s) || /\bduration:\s*[a-zA-Z(]/.test(s.replace(/prefersReducedMotion\(\) \? 0 : \d+/g, ''))) {
        expect(s, file).toContain('prefersReducedMotion')
      }
    }
  })

  it('M3: the canvas fit call passes 0 when motion is reduced', () => {
    const s = readFileSync(join(SRC, 'components/canvas/ProcessCanvas.tsx'), 'utf8')
    expect(s).toContain('fitView({ duration: prefersReducedMotion() ? 0 : 300 })')
  })
})
