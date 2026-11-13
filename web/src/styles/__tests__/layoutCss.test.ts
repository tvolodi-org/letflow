// @vitest-environment node
/** T-1873 T2 — the generic `.is-collapsed { visibility: hidden }` of components.css also matched the splitter handle and hid the
 *  only way back; base.css must override it for `.lf-splitter.is-collapsed` (the rendered result is in the screenshot matrix). */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const read = (f: string) => readFileSync(join(__dirname, '..', f), 'utf8')

describe('collapsed splitter handle stays visible', () => {
  it('T2 base.css overrides the generic hidden rule for the handle and its button', () => {
    const base = read('base.css')
    expect(read('components.css')).toMatch(/\.is-collapsed\s*\{[^}]*visibility:\s*hidden/)
    expect(base).toMatch(/\.lf-splitter\.is-collapsed\s*\{[^}]*visibility:\s*visible/)
    expect(base).toMatch(/\.lf-splitter\.is-collapsed \.lf-splitter__btn\s*\{[^}]*display:\s*grid/)
    expect(base).toMatch(/\.lf-splitter\.is-collapsed \.lf-splitter__btn\s*\{[^}]*width:\s*var\(--control-h-s\)/)
  })

  it('L1 (T-1884) the collapsed expand button is position: fixed, so the engine can keep it inside the viewport', () => {
    expect(read('base.css')).toMatch(/\.lf-splitter\.is-collapsed \.lf-splitter__btn\s*\{[^}]*position:\s*fixed/)
  })
})
