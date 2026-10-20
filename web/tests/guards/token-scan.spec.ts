// @vitest-environment node
/**
 * GH #2470: every var(--x) in web/src/** (no fallback) must name a token defined in
 * web/src/styles/tokens.css. An undefined token makes the declaration silently
 * invalid at runtime (e.g. border-radius not rendering).
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'
import { TOKEN_REF_REGEX, TOKEN_DEF_REGEX } from './forbidlist'

const WEB_ROOT = join(__dirname, '..', '..')

export function definedTokens(css: string): Set<string> {
  return new Set([...css.matchAll(TOKEN_DEF_REGEX)].map(m => m[1]))
}

export function undefinedRefs(content: string, defined: Set<string>): string[] {
  return [...content.matchAll(TOKEN_REF_REGEX)].map(m => m[1]).filter(name => !defined.has(name))
}

describe('token-scan', () => {
  const defined = definedTokens(readFileSync(join(WEB_ROOT, 'src', 'styles', 'tokens.css'), 'utf8'))

  it('tokens.css defines --radius-md', () => {
    expect(defined.has('--radius-md')).toBe(true)
  })

  it('meta: flags an undefined reference, accepts defined and fallback ones', () => {
    expect(undefinedRefs('a: var(--nope); b: var( --radius-md )', defined)).toEqual(['--nope'])
    expect(undefinedRefs('a: var(--nope, 4px)', defined)).toEqual([])
  })

  it('web/src/**/*.{ts,tsx,css} references only tokens defined in tokens.css', async () => {
    const files = await fg('src/**/*.{ts,tsx,css}', { cwd: WEB_ROOT })
    const problems: string[] = []
    for (const rel of files) {
      for (const name of undefinedRefs(readFileSync(join(WEB_ROOT, rel), 'utf8'), defined)) {
        problems.push(`web/${rel}: var(${name})`)
      }
    }
    expect(problems).toEqual([])
  })
})
