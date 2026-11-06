// @vitest-environment node
/** T-1410 B2: jsdom has no layout, so this only pins that the container-query card rules exist; the screenshots carry the proof. */
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const css = readFileSync(new URL('../../../styles/base.css', import.meta.url), 'utf8')

describe('lf-lines container-query card mode', () => {
  it('makes the lines card a container and switches to cards by container width', () => {
    expect(css).toMatch(/\.lf-doc__lines \{ container: lf-lines \/ inline-size; \}/)
    expect(css).toMatch(/@container lf-lines \(max-width: 520px\)/)
    expect(css).not.toMatch(/@container lf-lines \(max-width: (700|1000)px\)/)
  })
  it('U4 T-1438: no 1440 px re-template stacks the lines under the header; edit tables have a floor width', () => {
    expect(css).not.toMatch(/@media \(min-width: 1440px\)/)
    expect(css).not.toContain('"list top" "list header" "list lines"')
    expect(css).toMatch(/\.lf-lines--edit \{ min-width: 38rem; \}/)
    expect(css).toMatch(/\.lf-topbar \{ background: var\(--paper\); backdrop-filter: none; \}/)
  })
})
