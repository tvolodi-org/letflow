// @vitest-environment jsdom
/** T-1964: guards for the GATE B browser specs (web/tests/e2e/gate-b-*.e2e.spec.ts). They only run against the Keycloak
 *  stack in CI, so a wrong locator or a wrong read order shows up as a 2-minute timeout plus a cascade of later specs.
 *  Rules checked here, without a browser:
 *   1. a date-and-time field is never filled through `getByLabel('<label>')` (it matches four elements: strict-mode
 *      violation); the specs call `fillDateTime`, whose "<label>, date" / "<label>, time" labels exist in the component;
 *   2. a document number is read only after `issueDocument` (a draft has none: the gap-free number is allocated at Issue);
 *   3. a spec that creates a record with a unique key does not build the key from the run tag alone (a retry in the same
 *      run would meet "already in register"). */
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { DateTimeField } from '@/components/ui/DateField'

const E2E_DIR = join(__dirname, '..', '..', 'tests', 'e2e')
const SPECS = readdirSync(E2E_DIR).filter((f) => /^gate-b-.*\.e2e\.spec\.ts$/.test(f))

function lines(file: string): string[] {
  return readFileSync(join(E2E_DIR, file), 'utf8').split('\n')
}

describe('GATE B e2e specs: rules that only fail in CI', () => {
  it('finds the specs', () => {
    expect(SPECS).toContain('gate-b-assets-print.e2e.spec.ts')
    expect(SPECS).toContain('gate-b-stock.e2e.spec.ts')
    expect(SPECS).toContain('gate-b-stock-print.e2e.spec.ts')
  })

  it('never fills a DateTimeField through its bare group label', () => {
    const bad: string[] = []
    for (const f of SPECS) {
      lines(f).forEach((l, i) => {
        if (/getByLabel\('(Time|Event time)'\)\s*\.fill\(/.test(l)) bad.push(`${f}:${i + 1}: ${l.trim()}`)
      })
    }
    expect(bad, 'use fillDateTime(form, label, value) from support/gateB').toEqual([])
  })

  it('reads a document number only after the document is issued', () => {
    const bad: string[] = []
    for (const f of SPECS) {
      const ls = lines(f)
      ls.forEach((l, i) => {
        if (!/await headerNumber\(/.test(l)) return
        // walk back to the nearest save/issue call in the same test: it must be issueDocument
        for (let j = i - 1; j >= 0; j -= 1) {
          if (/^test\(/.test(ls[j])) break
          if (/await issueDocument\(/.test(ls[j])) return
          if (/await saveDocument\(/.test(ls[j]) || /getByRole\('button', \{ name: 'Save'/.test(ls[j])) {
            bad.push(`${f}:${i + 1}: headerNumber after a save, before issueDocument`)
            return
          }
        }
      })
    }
    expect(bad).toEqual([])
  })

  it('makes the asset inventory number unique per attempt', () => {
    const src = readFileSync(join(E2E_DIR, 'gate-b-assets-print.e2e.spec.ts'), 'utf8')
    expect(src).toMatch(/inventoryNumber = `E2E-\$\{ENV\.runTag\}-\$\{testInfo\.retry\}`/)
  })
})

describe('DateTimeField labels the e2e helper relies on', () => {
  it('the group label is ambiguous, the "<label>, date" and "<label>, time" inputs are not', () => {
    render(<DateTimeField label="Time" value="2026-11-14T18:35" onChange={() => {}} />)
    expect(screen.getAllByLabelText(/Time/).length).toBeGreaterThan(1)
    expect(screen.getByLabelText('Time, date', { exact: true })).toBeTruthy()
    expect(screen.getByLabelText('Time, time', { exact: true })).toBeTruthy()
  })
})
