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
import { describeViolation, LITERAL_COLOUR_HINT } from './reporter'
import { scanBundle, scanSource, summaryLines } from './scan-core'

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

// GH #2451 (Q-1089): the scan functions the two scan specs run, applied to the fixtures and to
// the inline cases that pin the literal-colour comment exemption and its documented limits.
const literalColourPattern = PATTERNS.filter(p => p.name === 'literal-colour')
const fixtureText = (kind: string) => readFileSync(join(FIXTURES_DIR, kind, 'literal-colour.txt'), 'utf8')
const scanLiteralColour = (content: string) =>
  scanSource([{ wsPath: 'web/src/fixture.ts', content }], literalColourPattern)

describe('meta-control: literal-colour exemption (GH #2451)', () => {
  it('bystander fixture (block and line comments citing GH numbers): no violation', () => {
    expect(scanLiteralColour(fixtureText('bystander')).violations).toHaveLength(0)
  })

  it('offender fixture (colours in code, including digit-only #000): violations', () => {
    expect(scanLiteralColour(fixtureText('offender')).violations.length).toBeGreaterThan(0)
  })

  it('a single-line /* GH #NNNN */ comment is exempt; a colour after it is not', () => {
    expect(scanLiteralColour('/* GH #2431 */').violations).toHaveLength(0)
    expect(scanLiteralColour("/* x */ const c = '#000';").violations).toHaveLength(1)
  })

  it("a '/*' inside a string does not exempt a colour after it (image/* in an attribute)", () => {
    const src = `<input accept="image/*" style={{ color: '#000' }} />`
    expect(scanLiteralColour(src).violations).toHaveLength(1)
  })

  it('a CSS universal selector line is not exempt (the JSDoc exemption is removed)', () => {
    expect(scanLiteralColour('* { color: #fff }').violations).toHaveLength(1)
    expect(scanLiteralColour('*color:#fff').violations).toHaveLength(1)
  })

  it('a multi-line block comment body with an issue reference is exempt (whole-file opener)', () => {
    expect(scanLiteralColour('/*\n  see GH #2431\n*/').violations).toHaveLength(0)
  })

  it('after a multi-line block comment, a real colour is reported on ITS line, not the comment body', () => {
    const result = scanLiteralColour("/*\n  see GH #2431\n*/\nconst c = '#000';")
    expect(result.violations).toHaveLength(1)
    expect(result.violations[0].line).toBe(4)
  })

  it("a colour after a URL's '//' is matched (the '//' is not a comment opener)", () => {
    expect(scanLiteralColour(`<a href="https://x.test" style={{ color: '#fa5252' }}>`).violations).toHaveLength(1)
  })

  it('the opener boundary: a "/*" inside a string after a word character is not an opener (image/*)', () => {
    expect(scanLiteralColour(`const s = "image/*"; const c = '#000'; const e = " */";`).violations).toHaveLength(1)
  })

  it('a colour after a closed block comment is matched even when a later */ exists', () => {
    expect(scanLiteralColour(`/* x */ const c = '#000'; const e = " */";`).violations).toHaveLength(1)
  })

  it('a line comment exempts its own line only: a colour on the next line is matched and located there', () => {
    const result = scanLiteralColour("// see GH #2431\nconst c = '#000';")
    expect(result.violations).toHaveLength(1)
    expect(result.violations[0].line).toBe(2)
  })

  it('a JSX comment {/* GH #NNNN */} is an opener (the boundary includes "{")', () => {
    expect(scanLiteralColour('{/* GH #2431 */}').violations).toHaveLength(0)
  })

  it('an allowed path is not scanned (the allow branch of isAllowed)', () => {
    const result = scanSource(
      [{ wsPath: 'web/src/styles/tokens.css', content: '.a{color:#000}' }],
      literalColourPattern,
    )
    expect(result.violations).toHaveLength(0)
  })

  it("a colour after url(//cdn) is matched ('(//' is not a comment opener)", () => {
    expect(scanLiteralColour('url(//cdn.x/a.png);color:#fff').violations).toHaveLength(1)
  })

  it('documented limit: a comment-like // after whitespace inside a string on the same line hides a later colour', () => {
    expect(scanLiteralColour(fixtureText('limit').split('\n')[0]).violations).toHaveLength(0)
  })

  it('documented limit: a three-line " /* " / colour / " */" sequence is not flagged (the closer is later in the file)', () => {
    expect(scanLiteralColour('const s = " /* ";\nconst c = \'#000\';\nconst e = " */";').violations).toHaveLength(0)
  })

  it('the offender fixture\'s digit-only line alone is flagged (#000 in code)', () => {
    expect(scanLiteralColour("const digitsOnly = { color: '#000' };").violations).toHaveLength(1)
  })

  it('the ";" opener boundary: "x;/* GH #NNNN */" is a comment, not a colour', () => {
    expect(scanLiteralColour('x = 1;/* see GH #2431 */').violations).toHaveLength(0)
  })

  it('the "}" opener boundary: "x}/* GH #NNNN */" is a comment, not a colour', () => {
    expect(scanLiteralColour('x}/* see GH #2431 */').violations).toHaveLength(0)
  })

  it('documented limit: a "//" inside a block comment that closes on the same line hides a later colour', () => {
    expect(scanLiteralColour("/* see // x */ const c = '#fff';").violations).toHaveLength(0)
  })

  it('documented limit: a "/*" opened in a line comment hides a colour until a later "*/"', () => {
    expect(scanLiteralColour("// see /* x\nconst c = '#fff';\n*/").violations).toHaveLength(0)
  })

  it('a second "/*" between a match and its "*/" refuses the exemption (conservative)', () => {
    expect(scanLiteralColour('/* see #2431 /* inner */').violations).toHaveLength(1)
  })

  it('documented limit: a comment-like /* ... */ inside a string on the same line hides a later colour', () => {
    expect(scanLiteralColour(fixtureText('limit').split('\n')[1]).violations).toHaveLength(0)
  })
})

// GH #2451: the failure message names the matched token and the hint for literal-colour only,
// produced by the same functions the two scan specs use. The Violation stays redacted.
describe('meta-control: literal-colour failure message (GH #2451)', () => {
  it('a source violation names the matched token, file:line and the GH hint', () => {
    const result = scanLiteralColour("const d = { color: '#000' }; // see GH #2431")
    expect(result.violations).toHaveLength(1)
    const [violation] = result.violations
    expect(Object.keys(violation).sort()).toEqual(['file', 'line', 'patternName'])
    const [line] = summaryLines(result, v => `${v.file}:${v.line}`)
    expect(line).toContain("literal-colour @ web/src/fixture.ts:1: matched '#000'")
    expect(line).toContain(LITERAL_COLOUR_HINT)
    expect(line).toContain('write GH NNNN')
  })

  it('a bundle violation names the matched token (line 0, file only); a hex colour gets no hint', () => {
    const result = scanBundle(
      [{ wsPath: 'web/dist/assets/x.js', content: '.btn{color:#ff0000;}' }],
      literalColourPattern,
    )
    expect(result.violations).toHaveLength(1)
    const [line] = summaryLines(result, v => v.file)
    expect(line).toContain("literal-colour @ web/dist/assets/x.js: matched '#ff0000'")
    expect(line).not.toContain(LITERAL_COLOUR_HINT)
  })

  it('a digit-only token (an issue-reference shape) gets the hint', () => {
    const result = scanBundle(
      [{ wsPath: 'web/dist/assets/y.js', content: '.btn{color:#000;}' }],
      literalColourPattern,
    )
    const [line] = summaryLines(result, v => v.file)
    expect(line).toContain(LITERAL_COLOUR_HINT)
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
    join(__dirname, 'scan-core.ts'),
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
