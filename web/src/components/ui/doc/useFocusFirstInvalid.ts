/** useFocusFirstInvalid — after a refused Save, move focus to the first control marked `aria-invalid` so a keyboard or
 *  screen-reader user lands on the error (its text is tied to the control by `aria-describedby`). The returned function
 *  only counts a request; the effect runs after the render that shows the errors (and any tab switch). With no marked
 *  control (error only in a banner) nothing moves. `rootSelector` limits the search (default: the whole page). */
import { useCallback, useEffect, useState } from 'react'

export function useFocusFirstInvalid(rootSelector = 'body'): () => void {
  const [request, setRequest] = useState(0)
  useEffect(() => {
    if (request === 0) return
    const root = document.querySelector(rootSelector)
    const el = root?.querySelector<HTMLElement>('[aria-invalid="true"]')
    if (el) el.focus()
    else root?.querySelector<HTMLElement>('[data-testid="lines-scroll"]')?.focus()
  }, [request, rootSelector])
  return useCallback(() => setRequest((n) => n + 1), [])
}
