/** Tells the dev server's harness gate (harnessGatePlugin in vite.config.ts) that the screen has drawn, so the
 *  page's load event, and with it headless Firefox's screenshot, comes after the render. An image request, not
 *  fetch: the fixture seam replaces window.fetch while a screen is mounted. */
export const HARNESS_READY_URL = '/__harness-ready'

/** Waits until `pending()` has been 0 for three polls (or `maxMs` passed), then signals. Returns a cancel function. */
export function signalWhenSettled(pending: () => number, maxMs = 3000, pollMs = 50): () => void {
  const started = Date.now()
  let quiet = 0
  const timer = window.setInterval(() => {
    quiet = pending() === 0 ? quiet + 1 : 0
    // The loading state never settles by design: give up after maxMs and shoot what is on screen.
    if (quiet >= 3 || Date.now() - started >= maxMs) {
      window.clearInterval(timer)
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          new Image().src = `${HARNESS_READY_URL}?t=${Date.now()}`
        }),
      )
    }
  }, pollMs)
  return () => window.clearInterval(timer)
}
