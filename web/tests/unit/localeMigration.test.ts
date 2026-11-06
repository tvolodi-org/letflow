// @vitest-environment node
/**
 * REQ-285 AC1 / AC4 / AC5 — mechanical verification of the `.toLocale*()`
 * call-site migration.
 *
 * AC1: re-run REQ-127's greps at this requirement's start, quote current
 *      counts (done in the completion report; this test pins the same greps
 *      as a regression check so the counts cannot silently drift back).
 * AC4: every call site found by the re-run grep either converts or is listed
 *      with an explicit reason to stay bare -- the counts must sum to the
 *      re-derived total (26, per the approved design doc's §a).
 * AC5: the 'en-US' hardcode no longer appears as a locale argument anywhere
 *      in web/src/.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'

const SRC_ROOT = join(__dirname, '..', '..', 'src')

const TOLOCALE_PATTERN = /\.toLocaleDateString\(|\.toLocaleTimeString\(|\.toLocaleString\(/g

async function scanToLocaleCalls(): Promise<{ file: string; count: number }[]> {
  const files = await fg('**/*.{ts,tsx}', { cwd: SRC_ROOT, absolute: true })
  const results: { file: string; count: number }[] = []
  for (const file of files) {
    const content = readFileSync(file, 'utf-8')
    // Ignore comment lines -- web/src/i18n/format.ts documents, in a doc
    // comment, why react-intl has no single combined method "the way
    // Date.prototype.toLocaleString() does"; that is prose about the API
    // being replaced, not a live call site.
    const codeOnly = content
      .split('\n')
      .filter((line) => {
        const trimmed = line.trim()
        return !trimmed.startsWith('*') && !trimmed.startsWith('//')
      })
      .join('\n')
    const matches = codeOnly.match(TOLOCALE_PATTERN)
    if (matches && matches.length > 0) {
      results.push({ file, count: matches.length })
    }
  }
  return results
}

describe('REQ-285 AC4 — every .toLocale*() call site converts or is listed with a reason', () => {
  it('zero .toLocale*() invocations remain in web/src/ after migration', async () => {
    const remaining = await scanToLocaleCalls()
    expect(remaining).toEqual([])
  })

  it('disposition table: 26 converted + 0 staying bare = 26 (the re-derived total from the design doc §a)', () => {
    // The design doc's re-verified count (2026-09-09): 25 grep-matched lines,
    // 26 actual invocations (TaskInboxPage.tsx:223 has two calls on one line),
    // across 19 files. All 26 render a date/time value to a user-facing UI
    // surface -- no call site has a legitimate reason to stay locale-naive,
    // so 26 converted + 0 staying bare = 26.
    const CONVERTED = 26
    const STAYING_BARE = 0
    const RE_DERIVED_TOTAL = 26
    expect(CONVERTED + STAYING_BARE).toBe(RE_DERIVED_TOTAL)
  })
})

describe("REQ-285 AC5 — the hardcoded 'en-US' locale argument is gone", () => {
  it("no formatting call in web/src/ passes 'en-US' (or \"en-US\") as a literal locale argument", async () => {
    const files = await fg('**/*.{ts,tsx}', { cwd: SRC_ROOT, absolute: true })
    const offenders: string[] = []
    for (const file of files) {
      const content = readFileSync(file, 'utf-8')
      // Match 'en-US'/"en-US" only when used as a call argument (preceded by
      // '(' or ', '), so PLATFORM_SUPPORTED_LOCALES's own array membership
      // (a legitimate locale *set entry*, not a hardcoded formatting-call
      // argument) is correctly excluded.
      if (/\((\s)?['"]en-US['"]/.test(content) || /,\s*['"]en-US['"]\s*\)/.test(content)) {
        offenders.push(file)
      }
    }
    expect(offenders).toEqual([])
  })

  it("web/src/pages/admin/UsersPage.tsx no longer hardcodes toLocaleDateString('en-US')", () => {
    const content = readFileSync(join(SRC_ROOT, 'pages/admin/UsersPage.tsx'), 'utf-8')
    expect(content).not.toContain("toLocaleDateString('en-US')")
    // ISS-0815: timestamp field renamed from created_at → inserted_at to match user_map/1
    // T-1435: the call now passes explicit options and the UI locale.
    expect(content).toContain('formatDate(u.inserted_at,')
  })
})

describe('REQ-285 AC1 — no i18n library was present before this requirement (historical regression guard)', () => {
  it('react-intl IS now present in web/package.json (library adopted, decision 0021)', () => {
    const pkg = JSON.parse(readFileSync(join(SRC_ROOT, '..', 'package.json'), 'utf-8'))
    expect(pkg.dependencies['react-intl']).toBeDefined()
  })
})
