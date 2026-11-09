// @vitest-environment jsdom
/** T-1554 K1/K2: the a11y helper itself — it must catch the faults it is there for. The forms are checked in their own
 *  test files (card form, both document forms, line form) with the same helper. */
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, render } from '@testing-library/react'
import { accessibleFormProblems, assertFormAccessible } from '@/test-utils/a11yForm'

afterEach(cleanup)

describe('assertFormAccessible', () => {
  it('passes for bound labels, aria-label and tied error text', () => {
    render(
      <form>
        <label htmlFor="a">Name</label>
        <input id="a" aria-invalid="true" aria-describedby="a-e" />
        <p id="a-e">Required</p>
        <input aria-label="Qty" />
        <label>
          Note <textarea />
        </label>
        <input type="hidden" name="h" />
      </form>,
    )
    expect(() => assertFormAccessible()).not.toThrow()
  })

  it('reports an unnamed control, an untied error, a positive tabindex and a grid without headers', () => {
    render(
      <form>
        <input name="bare" />
        <input aria-label="X" aria-invalid="true" />
        <button type="button" tabIndex={3}>
          go
        </button>
        <div role="grid" />
      </form>,
    )
    const problems = accessibleFormProblems()
    expect(problems.some((p) => p.startsWith('no accessible name'))).toBe(true)
    expect(problems.some((p) => p.startsWith('aria-invalid without error text'))).toBe(true)
    expect(problems.some((p) => p.startsWith('positive tabindex'))).toBe(true)
    expect(problems).toContain('grid without columnheader')
    expect(() => assertFormAccessible()).toThrow(/not accessible/)
  })
})
