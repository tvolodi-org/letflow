// @vitest-environment node
/**
 * GRD-UI-04: Meta-control — two-sided fixture test for every pattern.
 *
 * For each pattern in PATTERNS:
 *   - offender fixture must exist and the regex must match its content
 *   - bystander fixture must exist and the regex must NOT match its content
 *
 * Also enforces the single-source invariant: no RegExp literals may appear
 * in source-scan.spec.ts or bundle-scan.spec.ts.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { PATTERNS } from './forbidlist'
import { describeViolation, LITERAL_COLOUR_HINT, matchedToken } from './reporter'

const FIXTURES_DIR = join(__dirname, 'fixtures')

describe('meta-control: fixture coverage', () => {
  for (const pattern of PATTERNS) {
    const offenderPath = join(FIXTURES_DIR, 'offender', `${pattern.name}.txt`)
    const bystanderPath = join(FIXTURES_DIR, 'bystander', `${pattern.name}.txt`)

    describe(pattern.name, () => {
      it('offender fixture exists', () => {
        expect(() => readFileSync(offenderPath)).not.toThrow()
      })

      it('bystander fixture exists', () => {
        expect(() => readFileSync(bystanderPath)).not.toThrow()
      })

      it('regex matches offender', () => {
        const content = readFileSync(offenderPath, 'utf8')
        pattern.regex.lastIndex = 0
        expect(pattern.regex.test(content)).toBe(true)
      })

      it('regex does NOT match bystander', () => {
        const content = readFileSync(bystanderPath, 'utf8')
        pattern.regex.lastIndex = 0
        expect(pattern.regex.test(content)).toBe(false)
      })
    })
  }
})

// GH #2451 (Q-1089): the documented limit of the literal-colour comment exemption. A colour
// after '//' inside a string on the same line is NOT seen by the pattern. This fixture makes
// that limit explicit: if the exemption is ever widened or narrowed, this test changes too.
describe('meta-control: literal-colour known limit (GH #2451)', () => {
  it('a colour that follows // inside a string on the same line is not matched (documented limit)', () => {
    const content = readFileSync(join(FIXTURES_DIR, 'limit', 'literal-colour.txt'), 'utf8')
    const literalColour = PATTERNS.find(p => p.name === 'literal-colour')!
    literalColour.regex.lastIndex = 0
    expect(literalColour.regex.test(content)).toBe(false)
  })
})

// GH #2451: the failure message names the matched token and the hint for literal-colour only.
// The Violation itself stays redacted (file, line, patternName).
describe('meta-control: literal-colour failure message (GH #2451)', () => {
  it('a literal-colour line names the matched token, the file:line and the GH hint', () => {
    const literalColour = PATTERNS.find(p => p.name === 'literal-colour')!
    const line = "const x = { color: '#000' }; // see GH #2431"
    const token = matchedToken(line, literalColour.regex)
    expect(token).toBe('#000')
    const text = describeViolation({ file: 'web/src/x.ts', line: 3, patternName: 'literal-colour' }, token, 'web/src/x.ts:3')
    expect(text).toContain("matched '#000'")
    expect(text).toContain(LITERAL_COLOUR_HINT)
    expect(text).toContain('write GH NNNN')
  })

  it('other patterns keep the plain message (no token, no hint)', () => {
    const text = describeViolation({ file: 'web/src/x.ts', line: 3, patternName: 'native-confirm' }, 'window.confirm(', 'web/src/x.ts:3')
    expect(text).toBe('  native-confirm @ web/src/x.ts:3')
  })
})

describe('meta-control: single-source regex invariant', () => {
  const scanFiles = [
    join(__dirname, 'source-scan.spec.ts'),
    join(__dirname, 'bundle-scan.spec.ts'),
  ]

  for (const filePath of scanFiles) {
    const fileName = filePath.split(/[/\\]/).pop() ?? filePath

    it(`${fileName} contains no RegExp literals`, () => {
      const source = readFileSync(filePath, 'utf8')
      // Detects /pattern/ regex literals — skip the shebang comment line
      const lines = source.split('\n')
      for (const line of lines) {
        const trimmed = line.trim()
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue
        // Match a regex literal: / followed by at least one non-space char, closing /
        expect(trimmed).not.toMatch(/(?<![a-zA-Z0-9_$])\/.+\/[gimsuy]*(?=[^a-zA-Z0-9_$]|$)/)
      }
    })

    it(`${fileName} contains no new RegExp(`, () => {
      const source = readFileSync(filePath, 'utf8')
      expect(source).not.toContain('new RegExp(')
    })
  }
})
