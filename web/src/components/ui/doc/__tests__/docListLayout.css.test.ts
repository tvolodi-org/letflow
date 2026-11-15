// @vitest-environment node
/** T-1875 U1: jsdom has no layout, so this pins the CSS rules that keep the document list card usable; the browser test
 *  (tests/e2e/doc-list-layout.e2e.spec.ts) carries the layout proof. */
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const base = readFileSync(new URL('../../../../styles/base.css', import.meta.url), 'utf8')
const components = readFileSync(new URL('../../../../styles/components.css', import.meta.url), 'utf8')

describe('document list card layout (T-1875)', () => {
  it('base.css floors the list card and sizes it to its content while nothing is open', () => {
    expect(base).toContain('@container lfhost (min-width: 901px) and (max-width: 1439px)')
    expect(base).toContain(
      '.lf-doc > .lf-doc__list:not(.is-collapsed) { min-height: max(100%, min(40rem, calc(100vh - 2 * var(--space-4)))); }',
    )
    expect(base).toContain('.lf-doc:has(> .lf-doc__blank) > .lf-doc__list:not(.is-collapsed) { height: auto;')
    // Row keeps all three panes beside each other even when AppShell reduces the work area.
    expect(base).toContain('.lf-doc[data-layout="row"]')
    expect(base).toContain('grid-template-areas: "list top top" "list header lines";')
  })
  it('components.css still has the height: 0 rule the fix works around (re-check when the design release changes it)', () => {
    expect(components).toMatch(/height: 0;\s*min-height: 100%/)
  })
  it('count facts stack inside a narrow header, including long translated labels', () => {
    expect(base).toContain('.lf-doc__header .lf-dl { grid-template-columns: minmax(0, 1fr);')
    expect(base).toContain('.lf-doc__header .lf-dl dd { margin: 0 0 var(--space-3); }')
    expect(base).toContain('.lf-doc__lines { position: relative; }')
  })
})
