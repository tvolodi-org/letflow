// GRD-UI-05: Redacted violation reporter and YAML writer.
// Report files serialise { file, line, patternName } only: no matched content. Failure MESSAGES
// may name a literal-colour token and the GH hint (GH #2451); those never enter a report.

import { writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { dump } from 'js-yaml'

export interface Violation {
  file: string
  line: number
  patternName: string
}

/**
 * Hint printed in the failure MESSAGE for a literal-colour violation (GH #2451).
 * Message text only: it and the matched token never enter a Violation or a report file.
 */
export const LITERAL_COLOUR_HINT =
  'an issue reference like #NNNN in a comment matches the hex-colour pattern: write GH NNNN'

/** The text the pattern matched, for the failure message only; undefined if no match. */
export function matchedToken(text: string, regex: RegExp): string | undefined {
  const m = text.match(regex)
  return m ? m[0] : undefined
}

/**
 * True for a '#' followed only by decimal digits (e.g. '#2431', '#000'): the shape of an issue
 * reference, so the hint applies to it. Hex colours with letters ('#fa5252') get no hint.
 * A character check, not a regex literal: forbidlist.ts is the only file with regex literals.
 */
function isDigitOnlyHashToken(token: string): boolean {
  if (token.length < 2 || token[0] !== '#') return false
  for (const c of token.slice(1)) {
    if (c < '0' || c > '9') return false
  }
  return true
}

/**
 * One failure-message line for a violation (GH #2451). For literal-colour the matched token is
 * named, and the issue-reference hint is added when the token is digit-only; every other pattern
 * keeps the plain form. `location` is 'file:line' for source files and 'file' for bundle assets.
 */
export function describeViolation(
  v: Violation,
  token: string | undefined,
  location: string,
): string {
  const base = `  ${v.patternName} @ ${location}`
  if (v.patternName !== 'literal-colour') return base
  const tokenPart = token === undefined ? '' : `: matched '${token}'`
  const hint = token !== undefined && isDigitOnlyHashToken(token) ? ` -- ${LITERAL_COLOUR_HINT}` : ''
  return `${base}${tokenPart}${hint}`
}

interface RunReport {
  runId: string
  date: string
  evaluatedPatterns: string[]
  violations: Violation[]
}

const REQUIRED_KEYS: (keyof Violation)[] = ['file', 'line', 'patternName']

/**
 * Assert that every entry in violations has exactly the keys: file, line, patternName.
 * Throws if any entry carries an additional key or is missing a required key.
 */
export function assertRedacted(violations: Violation[]): void {
  for (const v of violations) {
    const keys = Object.keys(v)
    for (const required of REQUIRED_KEYS) {
      if (!keys.includes(required)) {
        throw new Error(`Violation missing required key "${required}": ${JSON.stringify(v)}`)
      }
    }
    for (const key of keys) {
      if (!(REQUIRED_KEYS as string[]).includes(key)) {
        throw new Error(`Violation has forbidden key "${key}" (must only contain file, line, patternName): ${JSON.stringify(v)}`)
      }
    }
  }
}

/**
 * Write violations to tests/reports/report-<date>-<runId>.yaml.
 * Serialises RunReport as YAML. No matched content is written.
 */
export function writeViolations(
  violations: Violation[],
  evaluatedPatterns: string[],
  runId: string,
): void {
  const date = new Date().toISOString().slice(0, 10)
  const effectiveRunId = process.env.GUARD_RUN_ID ?? runId

  const report: RunReport = {
    runId: effectiveRunId,
    date,
    evaluatedPatterns,
    violations,
  }

  const reportsDir = join(process.cwd(), 'tests', 'reports')
  mkdirSync(reportsDir, { recursive: true })

  const fileName = `report-${date}-${effectiveRunId}.yaml`
  const filePath = join(reportsDir, fileName)
  writeFileSync(filePath, dump(report, { lineWidth: 120 }), 'utf8')
}
