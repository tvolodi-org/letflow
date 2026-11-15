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

  // T-1994: `if (await x.isVisible().catch(() => false)) await x.click()` probes once without waiting; in CI it ran before
  // the task panel rendered Claim, skipped the claim, and Complete never appeared (run 43657586709, P1 and G2).
  it('never decides on a one-shot isVisible().catch probe', () => {
    const bad: string[] = []
    for (const f of [...SPECS, join('support', 'gateB.ts')]) {
      lines(f).forEach((l, i) => {
        if (/\.isVisible\(\)\s*\.catch\(/.test(l)) bad.push(`${f}:${i + 1}: ${l.trim()}`)
      })
    }
    expect(bad, 'wait for one of the expected elements first: expect(a.or(b).first()).toBeVisible()').toEqual([])
  })

  // T-1994: `document-header` is the field list of a document; the state word (Cancelled, Posted...) is in the title bar.
  it('never looks for the Cancelled state in the document field list', () => {
    const bad: string[] = []
    for (const f of SPECS) {
      lines(f).forEach((l, i) => {
        if (/getByTestId\('document-header'\)\)\.toContainText\('Cancelled'\)/.test(l)) bad.push(`${f}:${i + 1}`)
      })
    }
    expect(bad).toEqual([])
  })

  // T-1994 (CI run 43665551852, G2): `openRoute` to the document already on screen is an in-app navigation that serves
  // the cached document, so a poll for Posted built on it never fetches again (no document request after the completion).
  it('never polls for Posted by re-routing to the same document', () => {
    const bad: string[] = []
    for (const f of SPECS) {
      const ls = lines(f)
      ls.forEach((l, i) => {
        if (/await openRoute\(/.test(l) && /getByTestId\('document-header'\)\)\.toContainText\(\/Posted/.test(ls[i + 1] ?? '')) {
          bad.push(`${f}:${i + 1}`)
        }
      })
    }
    expect(bad, 'inside toPass, open the list and click the document row so the screen remounts and fetches').toEqual([])
  })

  // T-1994 (CI run 43665551852, P8): the count form reads the typed window in the tenant zone, not the runner's UTC; a
  // count that a spec opens must hold now in every zone (UTC-12..UTC+14), so its window reaches at least 14 h either side.
  it('gives a count that is opened a window around now in every zone', () => {
    const bad: string[] = []
    for (const f of SPECS) {
      const src = readFileSync(join(E2E_DIR, f), 'utf8')
      if (!src.includes("getByTestId('count-open').click()")) continue
      lines(f).forEach((l, i) => {
        const m = /getByLabel\('Planned (start|end)'\)\.fill\(localDateTime\((-?\d+)\)\)/.exec(l)
        if (!m) return
        const hours = Number(m[2])
        if ((m[1] === 'start' && hours > -14) || (m[1] === 'end' && hours < 14)) bad.push(`${f}:${i + 1}: ${l.trim()}`)
      })
    }
    expect(bad).toEqual([])
  })

  // T-1994 (CI run 43665551852, E10): a bare 'Reason' label also matches the optional "Reason details" textarea.
  it('names the Reason select exactly', () => {
    const bad: string[] = []
    for (const f of SPECS) {
      lines(f).forEach((l, i) => {
        if (/getByLabel\('Reason'\)/.test(l)) bad.push(`${f}:${i + 1}`)
      })
    }
    expect(bad, "use getByLabel('Reason', { exact: true })").toEqual([])
  })

  it('makes the asset inventory number unique per attempt', () => {
    const src = readFileSync(join(E2E_DIR, 'gate-b-assets-print.e2e.spec.ts'), 'utf8')
    expect(src).toMatch(/inventoryNumber = `E2E-\$\{ENV\.runTag\}-\$\{testInfo\.retry\}`/)
  })
})

describe('Playwright test callbacks', () => {
  // T-1994: Playwright refuses to load a spec whose test callback takes a plain identifier as its first argument
  // ("First argument must use the object destructuring pattern"), which failed the whole stock e2e job on load.
  it('take an object pattern as their first argument in every e2e spec', () => {
    const all = readdirSync(E2E_DIR).filter((f) => /\.e2e\.spec\.ts$/.test(f))
    const bad: string[] = []
    for (const f of all) {
      lines(f).forEach((l, i) => {
        if (/\btest(?:\.\w+)?\(\s*['"`].*,\s*async\s*\(\s*[A-Za-z_$][\w$]*\s*[,)]/.test(l)) bad.push(`${f}:${i + 1}`)
      })
    }
    expect(bad).toEqual([])
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
