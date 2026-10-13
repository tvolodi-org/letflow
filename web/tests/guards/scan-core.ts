// GH #2451 / Q-1089: the scan logic shared by source-scan.spec.ts and bundle-scan.spec.ts.
// Pure functions over already-read content (no file system, no network), so meta-control.spec.ts
// can run exactly the code the two scan specs run, on the fixtures. The failure message is built
// here too: the matched token is kept beside each Violation, never inside it.

import { matchedToken, describeViolation, type Violation } from './reporter'
import type { GuardPattern } from './forbidlist'

export interface ScanFile {
  /** Workspace-relative, forward-slash path, e.g. 'web/src/x.ts'. */
  wsPath: string
  content: string
}

export interface ScanResult {
  violations: Violation[]
  /** Matched token per violation, for the failure MESSAGE only (undefined when none). */
  tokens: Map<Violation, string | undefined>
}

export function isAllowed(filePath: string, allowedPaths: string[]): boolean {
  const lc = filePath.toLowerCase()
  return allowedPaths.some(a => lc.startsWith(a.toLowerCase()))
}

// Whole-file test, then the first individually matching line for the line number.
function findInSource(
  content: string,
  lines: string[],
  pattern: GuardPattern,
  filePath: string,
): Violation | null {
  // Test whole-file content — required for multi-line patterns (e.g. missing-query-state-boundary)
  pattern.regex.lastIndex = 0
  if (!pattern.regex.test(content)) return null

  // literal-colour's comment exemption can span lines (a multi-line block comment), so its line
  // is the line of the first match in the WHOLE file, not the first line that matches alone
  if (pattern.name === 'literal-colour') {
    pattern.regex.lastIndex = 0
    const m = pattern.regex.exec(content)
    if (m) {
      return { file: filePath, line: content.slice(0, m.index).split('\n').length, patternName: pattern.name }
    }
  }

  // Violation confirmed — find the first line that individually matches for accurate line number
  for (let i = 0; i < lines.length; i++) {
    pattern.regex.lastIndex = 0
    if (pattern.regex.test(lines[i])) {
      return { file: filePath, line: i + 1, patternName: pattern.name }
    }
  }

  // Multi-line pattern: no single line matches — report line 1
  return { file: filePath, line: 1, patternName: pattern.name }
}

/** Scans source files (GRD-UI-02). Token recorded for literal-colour only. */
export function scanSource(files: ScanFile[], patterns: GuardPattern[]): ScanResult {
  const violations: Violation[] = []
  const tokens = new Map<Violation, string | undefined>()

  for (const { wsPath, content } of files) {
    const lines = content.split('\n')
    for (const pattern of patterns) {
      if (isAllowed(wsPath, pattern.allowedPaths)) continue

      const violation = findInSource(content, lines, pattern, wsPath)
      if (violation) {
        violations.push(violation)
        if (pattern.name === 'literal-colour') {
          // the same whole-file match that located the violation (see findInSource)
          tokens.set(violation, matchedToken(content, pattern.regex))
        }
      }
    }
  }

  return { violations, tokens }
}

/** Scans built bundle assets (GRD-UI-03). Minified, so line 0; token recorded for literal-colour. */
export function scanBundle(assets: ScanFile[], patterns: GuardPattern[]): ScanResult {
  const violations: Violation[] = []
  const tokens = new Map<Violation, string | undefined>()

  for (const { wsPath, content } of assets) {
    for (const pattern of patterns) {
      if (isAllowed(wsPath, pattern.allowedPaths)) continue

      pattern.regex.lastIndex = 0
      if (pattern.regex.test(content)) {
        // Bundle assets are minified — report line 0 (not applicable)
        const violation: Violation = { file: wsPath, line: 0, patternName: pattern.name }
        violations.push(violation)
        if (pattern.name === 'literal-colour') {
          tokens.set(violation, matchedToken(content, pattern.regex))
        }
      }
    }
  }

  return { violations, tokens }
}

/**
 * The failure-message lines for a scan (first 10, as the scan specs print them).
 * `locate` gives the location text: 'file:line' for sources, 'file' for bundles.
 */
export function summaryLines(result: ScanResult, locate: (v: Violation) => string): string[] {
  return result.violations
    .slice(0, 10)
    .map(v => describeViolation(v, result.tokens.get(v), locate(v)))
}
