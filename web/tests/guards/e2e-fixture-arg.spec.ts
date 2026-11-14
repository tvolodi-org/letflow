// @vitest-environment node
/**
 * GH T-1992 — Playwright refuses a test callback whose first parameter is not an object
 * destructuring pattern ("First argument must use the object destructuring pattern: _fixtures"),
 * and the whole spec file then fails at load. This scan keeps `async (_x, testInfo)` and
 * `async (fixtures) =>` out of tests/e2e: write `async ({}, testInfo)` or `async ({ page }) =>`.
 */

import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const E2E_DIR = join(__dirname, '..', 'e2e')

// test(...)/test.only(...)/test.beforeEach(...) etc. whose callback's first parameter is a bare name.
export const BAD_FIXTURE_ARG =
  /\btest(?:\.\w+)*\s*\((?:[^()]|\([^()]*\))*?\basync\s*\(\s*[A-Za-z_$][\w$]*\s*[,)]/

describe('e2e specs: first callback argument is a destructuring pattern', () => {
  it('detects the bad shape and accepts the good ones', () => {
    expect(BAD_FIXTURE_ARG.test("test('x', async (_fixtures, testInfo) => {})")).toBe(true)
    expect(BAD_FIXTURE_ARG.test("test('x', async (page) => {})")).toBe(true)
    expect(BAD_FIXTURE_ARG.test("test('x', async ({}, testInfo) => {})")).toBe(false)
    expect(BAD_FIXTURE_ARG.test("test('x', async ({ page }, testInfo) => {})")).toBe(false)
    expect(BAD_FIXTURE_ARG.test("test('x', async () => {})")).toBe(false)
  })

  it('no spec under tests/e2e uses a non-destructured first fixture argument', () => {
    const offenders: string[] = []
    for (const name of readdirSync(E2E_DIR)) {
      if (!/\.spec\.tsx?$/.test(name)) continue
      const lines = readFileSync(join(E2E_DIR, name), 'utf8').split('\n')
      lines.forEach((line, i) => {
        if (BAD_FIXTURE_ARG.test(line)) offenders.push(`${name}:${i + 1}`)
      })
    }
    expect(offenders).toEqual([])
  })
})
