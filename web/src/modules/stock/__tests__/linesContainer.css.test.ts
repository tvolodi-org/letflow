// @vitest-environment node
/** T-1410 B2: jsdom has no layout, so this only pins that the container-query card rules exist; the screenshots carry the proof. */
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const css = readFileSync(new URL('../../../styles/base.css', import.meta.url), 'utf8')

describe('lf-lines container-query card mode', () => {
  it('makes the lines card a container and switches to cards by container width', () => {
    expect(css).toMatch(/\.lf-doc__lines \{ container: lf-lines \/ inline-size; \}/)
    expect(css).toMatch(/@container lf-lines \(max-width: 700px\)/)
    expect(css).toMatch(/@container lf-lines \(max-width: 1000px\)/)
  })
  it('C1 wide screens put the lines under the header so the table fits', () => {
    expect(css).toMatch(/@media \(min-width: 1440px\)/)
    expect(css).toContain('"list top" "list header" "list lines"')
  })
})
