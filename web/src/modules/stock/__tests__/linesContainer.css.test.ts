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
    // T-1448: the one 1440 px rule hides the list while a draft is edited (header and lines keep their side-by-side areas).
    expect(css).toContain('@container lfhost (min-width: 1440px)')
    expect(css).toContain('grid-template-areas: "top top" "header lines"')
    expect(css).not.toContain('"list top" "list header" "list lines"')
    expect(css).toMatch(/\.lf-lines--edit \{ min-width: 38rem; \}/)
    expect(css).toMatch(/\.lf-topbar \{ background: var\(--paper\); backdrop-filter: none; \}/)
  })
  it('U5 T-1438: a view table drops the components.css min-width so it fits the card (no scrollbar bar)', () => {
    expect(css).toMatch(/\.lf-doc__lines \.lf-lines:not\(\.lf-lines--edit\):not\(\.lf-lines--wide\) \{ min-width: 0; \}/)
  })
  it('U6 T-1438: the harness edit helpers know the edit and save labels of en, ru and kk', () => {
    const fx = readFileSync(new URL('../../../dev/harness/fixtures/stockDocuments.tsx', import.meta.url), 'utf8')
    for (const label of ['Изменить', 'Өзгерту', 'Сохранить черновик', 'Жобаны сақтау']) expect(fx).toContain(label)
  })
})

describe('LE2-T9 the lines panel fills the window and keeps a fixed fallback', () => {
  it('base.css keeps the fixed height and adds a viewport fill rule for wide, tall windows', () => {
    expect(css).toContain('.lf-doc__lines .lf-le { height: min(70vh, 720px); min-height: 22rem; }')
    expect(css).toMatch(/@media \(min-width: 900px\) and \(min-height: 700px\) \{\s*\.lf-doc__lines \.lf-le \{ height: clamp\(22rem, calc\(100dvh - 15rem\), 64rem\); \}/)
  })
})
