/** noUuidInDom — T-1378. The shared check behind "a reference field never shows an id": the visible text of a rendered
 *  screen, and the title / value / aria-label / placeholder attributes a user can read or copy, match no uuid. */
export const UUID_PATTERN = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

const ATTRIBUTES = ['title', 'value', 'aria-label', 'placeholder', 'alt']

/** Every uuid found in the container's text and readable attributes (empty when clean). */
export function uuidsInDom(container: Element): string[] {
  const found: string[] = []
  const take = (s: string | null | undefined) => {
    const m = s?.match(new RegExp(UUID_PATTERN.source, 'gi'))
    if (m) found.push(...m)
  }
  take(container.textContent)
  container.querySelectorAll('*').forEach((el) => {
    for (const a of ATTRIBUTES) {
      // an <option>'s value is the submitted id, not what the user reads (its text is checked as text)
      if (a === 'value' && el.tagName === 'OPTION') continue
      take(el.getAttribute(a))
    }
    // the current value of a form control (not an attribute once the user or React changed it)
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) take(el.value)
  })
  return found
}

/** `true` when no uuid is visible: `expect(noUuidInDom(container)).toBe(true)` (the failure message lists the ids via `uuidsInDom`). */
export function noUuidInDom(container: Element): boolean {
  return uuidsInDom(container).length === 0
}
