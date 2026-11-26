import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { DESIGNER_ERROR_MESSAGES, designerErrorKey } from '../designerErrorMessages'
import { processDiagramMessages } from '../processDiagramMessages'

const DIR = join(__dirname, '../../../../lib/letflow/definitions')

function serverCodes(): string[] {
  const found = new Set<string>()
  for (const f of readdirSync(DIR).filter((n) => n.endsWith('.ex'))) {
    const text = readFileSync(join(DIR, f), 'utf8')
    for (const m of text.matchAll(/:((?:platform_call|notify)_[a-z_]+)\b/g)) found.add(m[1]!)
  }
  return [...found]
}

describe('designer error messages', () => {
  it('reads codes from the server and finds some', () => {
    expect(serverCodes().length).toBeGreaterThan(20)
  })

  it('every platform_call_* / notify_* code the server can answer has a message in en, ru and kk', () => {
    const missing = serverCodes().filter((c) => !DESIGNER_ERROR_MESSAGES[c])
    // A new server code with no entry in designerErrorMessages.ts fails here.
    expect(missing).toEqual([])
  })

  it('no message is empty, shows a raw code or an HTTP status name, in any language', () => {
    for (const [key, triple] of Object.entries(DESIGNER_ERROR_MESSAGES)) {
      expect(triple).toHaveLength(3)
      for (const t of triple) {
        expect(t.trim().length, key).toBeGreaterThan(0)
        expect(t, key).not.toMatch(/Unprocessable|_malformed|_unknown|\b4\d\d\b/)
      }
      for (const loc of ['en', 'ru', 'kk'] as const) {
        expect(processDiagramMessages[loc][`processDiagram.edit.err.${key}`], `${loc} ${key}`).toBeTruthy()
      }
    }
  })

  it('falls back by status class, then to the generic sentence', () => {
    expect(designerErrorKey('notify_malformed')).toBe('notify_malformed')
    expect(designerErrorKey('brand_new_code', 409)).toBe('http_409')
    expect(designerErrorKey(undefined, 422)).toBe('http_422')
    expect(designerErrorKey('x', 500)).toBe('fallback')
  })
})
