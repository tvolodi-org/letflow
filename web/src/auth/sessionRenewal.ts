/**
 * Single-flight session renewal registry (T-1400).
 *
 * AuthProvider registers the one function that can refresh the session (refresh-token
 * grant on the active OIDC manager). The API client (on a 401) and AuthProvider's own
 * expiry timer both call `renewSession()`, which shares ONE in-flight promise, so two
 * callers never send two refresh grants with the same refresh token (Keycloak refresh
 * token rotation would revoke the session). No React, no fetch.
 */

export type RenewOutcome =
  | { kind: 'ok'; token: string }
  | { kind: 'terminal' }
  | { kind: 'transient' }

type Renewer = () => Promise<RenewOutcome>

let _renewer: Renewer | null = null
let _inflight: Promise<RenewOutcome> | null = null

/** Registers the active renewer; the returned function unregisters it (only if still current). */
export function registerRenewer(fn: Renewer): () => void {
  _renewer = fn
  return () => {
    if (_renewer === fn) _renewer = null
  }
}

/** Renews the session now. No renewer registered, or a renewer that throws, is `terminal`. */
export function renewSession(): Promise<RenewOutcome> {
  if (_inflight) return _inflight
  const renewer = _renewer
  if (!renewer) return Promise.resolve({ kind: 'terminal' })
  const p = (async (): Promise<RenewOutcome> => {
    try {
      return await renewer()
    } catch {
      return { kind: 'terminal' }
    } finally {
      if (_inflight === p) _inflight = null
    }
  })()
  _inflight = p
  return p
}
