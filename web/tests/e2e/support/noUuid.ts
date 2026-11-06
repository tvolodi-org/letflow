/**
 * Node-side copy of src/test-utils/noUuidInDom.ts (T-1378, the R1 helper) for Playwright specs, which must not import
 * from src/ test-utils. tests/unit/e2eNoUuid.test.ts asserts the pattern and the attribute list stay equal.
 */
import type { Page } from '@playwright/test'

export const UUID_PATTERN_SOURCE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
export const READABLE_ATTRIBUTES = ['title', 'value', 'aria-label', 'placeholder', 'alt']

/** Every uuid visible on the page: text, readable attributes, current value of form controls (an <option> value is skipped). */
export async function uuidsOnPage(page: Page): Promise<string[]> {
  return page.evaluate(
    ({ source, attributes }) => {
      const re = new RegExp(source, 'gi')
      const found: string[] = []
      const take = (s: string | null | undefined) => {
        const m = s?.match(re)
        if (m) found.push(...m)
      }
      take(document.body.textContent)
      document.body.querySelectorAll('*').forEach((el) => {
        for (const a of attributes) {
          if (a === 'value' && el.tagName === 'OPTION') continue
          take(el.getAttribute(a))
        }
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) take(el.value)
      })
      return found
    },
    { source: UUID_PATTERN_SOURCE, attributes: READABLE_ATTRIBUTES },
  )
}

/** Throws with the ids and the screen name when any uuid is visible. */
export async function assertNoUuid(page: Page, screen: string): Promise<void> {
  const found = await uuidsOnPage(page)
  if (found.length > 0) throw new Error(`${screen}: uuid visible on screen: ${found.slice(0, 3).join(', ')}`)
}
