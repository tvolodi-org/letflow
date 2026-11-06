/** True when the host is wider than the 900 px breakpoint of the `lfhost` container query, so the splitter and the
 *  column handles switch exactly where the CSS does. jsdom and unmounted nodes report 0: then the nearest `main`
 *  is measured. */
export function isWideHost(el: HTMLElement | null): boolean {
  if (!el) return false
  const w = el.clientWidth || (el.closest('main') as HTMLElement | null)?.clientWidth || 0
  return w > 900
}
