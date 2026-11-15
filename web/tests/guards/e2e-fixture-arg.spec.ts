// @vitest-environment node
/**
 * Guard: the first parameter of a Playwright test/hook callback must be an object destructuring pattern
 * (`async ({ page }, testInfo)` or `async ({}, testInfo)`). `async (_fixtures, testInfo)` makes Playwright refuse the
 * whole spec file at load ("First argument must use the object destructuring pattern").
 */
import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const E2E_DIR = join(__dirname, '..', 'e2e')

// test(...), test.only(...), test.beforeAll(...), test.step is excluded (it takes no fixtures) ...
const CALLBACK = /(?<![\w.])(?:test|it)(?:\.(?:only|skip|fixme|fail|slow))?\(\s*(?:'[^'\n]*'|"[^"\n]*"|`[^`\n]*`)\s*,\s*(?:\{[^}\n]*\}\s*,\s*)?async\s*\(\s*([^)\s,][^),]*)|(?<![\w.])test\.(?:beforeAll|beforeEach|afterAll|afterEach)\(\s*async\s*\(\s*([^)\s,][^),]*)/g

export function badFirstArgs(source: string): string[] {
  const bad: string[] = []
  for (const m of source.matchAll(CALLBACK)) {
    const first = (m[1] ?? m[2] ?? '').trim()
    if (!first.startsWith('{')) bad.push(first)
  }
  return bad
}

function specFiles(dir: string): string[] {
  const out: string[] = []
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) out.push(...specFiles(p))
    else if (/\.spec\.ts$/.test(name)) out.push(p)
  }
  return out
}

describe('e2e fixture argument guard', () => {
  it('flags a non-destructured first argument (offender)', () => {
    expect(badFirstArgs("test('x', async (_fixtures, testInfo) => {})")).toEqual(['_fixtures'])
    expect(badFirstArgs("test.beforeAll(async (browser) => {})")).toEqual(['browser'])
  })

  it('accepts destructuring patterns, including the empty one (bystander)', () => {
    expect(badFirstArgs("test('x', async ({}, testInfo) => {})")).toEqual([])
    expect(badFirstArgs("test('x', async ({ page }) => {})")).toEqual([])
    expect(badFirstArgs("test('x', async () => {})")).toEqual([])
  })

  it('no e2e spec has a non-destructured first parameter', () => {
    const offenders = specFiles(E2E_DIR).flatMap(f => badFirstArgs(readFileSync(f, 'utf8')).map(a => `${f}: ${a}`))
    expect(offenders).toEqual([])
  })
})
