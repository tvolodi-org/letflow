// @vitest-environment node
/**
 * GRD-UI-02: Static source scan — web/src/** /*.{ts,tsx,css}
 *
 * Applies every source-applicable pattern from PATTERNS to all files under
 * web/src/. Violations are written to tests/reports/. Fails if any are found.
 * Timeout: 30 000 ms.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'
import { PATTERNS } from './forbidlist'
import { writeViolations, assertRedacted } from './reporter'
import { scanSource, summaryLines, type ScanFile } from './scan-core'

const WEB_PREFIX = 'web/'

function toForwardSlash(p: string): string {
  return p.split('\\').join('/')
}

function normToWsPath(relFile: string): string {
  return WEB_PREFIX + toForwardSlash(relFile)
}

describe('source-scan', () => {
  it(
    'web/src/**/*.{ts,tsx,css} has no guard violations',
    async () => {
      const sourcePatterns = PATTERNS.filter(p => p.appliesTo === 'source' || p.appliesTo === 'both')
      const evaluatedPatterns = sourcePatterns.map(p => p.name)

      // Glob relative to web/ directory
      const files = await fg('src/**/*.{ts,tsx,css}', { cwd: join(__dirname, '..', '..') })

      const scanFiles: ScanFile[] = files.map(relFile => ({
        wsPath: normToWsPath(relFile),
        content: readFileSync(join(__dirname, '..', '..', relFile), 'utf8'),
      }))
      const result = scanSource(scanFiles, sourcePatterns)
      const { violations } = result

      const ts = new Date().toISOString().slice(0, 19).split(':').join('-')
      const runId = process.env.GUARD_RUN_ID ?? ts
      assertRedacted(violations)
      writeViolations(violations, evaluatedPatterns, runId)

      if (violations.length > 0) {
        const summary = summaryLines(result, v => `${v.file}:${v.line}`).slice(0, 10).join('\n')
        const more = violations.length > 10 ? `\n  ... and ${violations.length - 10} more` : ''
        expect.fail(
          `Source scan found ${violations.length} violation(s):\n${summary}${more}`,
        )
      }

      expect(violations).toHaveLength(0)
    },
    30_000,
  )
})
