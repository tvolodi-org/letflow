/** The harness's data seam (task S0d): while a harness screen is mounted, `window.fetch` is answered from the
 *  screen's fixture routes. Screens and the query layer are unchanged; a request no fixture matches is answered
 *  404 and logged, never sent to a network. The real fetch is restored on cleanup. */
import type { FixtureRoute, HarnessState } from './types'

const PROBLEM_500 = { type: 'about:blank', title: 'Fixture error', status: 500 }

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

/** Requests answered but not yet settled; the loading state's never-answered ones are not counted. */
let inFlight = 0
export function pendingFixtureRequests(): number {
  return inFlight
}

export function makeFixtureFetch(routes: FixtureRoute[], state: HarnessState): typeof window.fetch {
  return (input, init) => {
    const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    const path = new URL(raw, 'http://harness.invalid').pathname
    const method = (init?.method ?? (typeof input === 'object' && 'method' in input ? input.method : 'GET')).toUpperCase()
    const route = routes.find(r => r.match(path, method))
    if (!route) {
      console.warn(`[harness] no fixture for ${method} ${path}`)
      return Promise.resolve(jsonResponse(404, { title: 'No fixture', status: 404 }))
    }
    if (state === 'loading') return new Promise<Response>(() => {})
    if (state === 'error') return Promise.resolve(jsonResponse(500, PROBLEM_500))
    let requestBody: unknown
    if (typeof init?.body === 'string') {
      try {
        requestBody = JSON.parse(init.body)
      } catch {
        requestBody = undefined
      }
    }
    const { status, body } = route.reply(state, path, requestBody)
    inFlight += 1
    return Promise.resolve(jsonResponse(status, body)).finally(() => {
      inFlight -= 1
    })
  }
}

/** Installs the fixture fetch; returns the restore function. */
export function installFixtureFetch(routes: FixtureRoute[], state: HarnessState): () => void {
  const original = window.fetch
  window.fetch = makeFixtureFetch(routes, state)
  return () => {
    window.fetch = original
  }
}
