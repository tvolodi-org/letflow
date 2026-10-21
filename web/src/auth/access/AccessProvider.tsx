/**
 * Fetches GET /me/access for the signed-in identity and publishes it.
 *
 * Two keys. The identity key (tenant slug + the token's `sub`, an identity, not a role) decides
 * when the state resets to `loading`: a tenant or user switch must never show the previous
 * grants, not even for one render, so the reset is derived during render. The token only
 * triggers a refetch: an OIDC silent renew replaces `session.token` for the same identity, and
 * then the `ready` state is kept (also when the background refetch fails), so guarded pages stay
 * mounted. State lives here and not in react-query: a platform session has no tenant id, so
 * tenant-scoped query keys would collapse and could leak grants across a switch.
 */

import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { meApi } from '@/api/me'
import { useAuth } from '@/auth/AuthContext'
import { decodeTokenPayload } from '@/auth/tokenUtils'
import { AccessContext } from './AccessContext'
import type { AccessState } from './types'

const LOADING: AccessState = { status: 'loading' }

interface Stored {
  key: string
  state: AccessState
}

export function AccessProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth()
  const token = session?.token ?? null
  const identityKey = session
    ? `${session.tenant_slug ?? ''}|${decodeTokenPayload(session.token)?.sub ?? ''}`
    : null

  const [stored, setStored] = useState<Stored | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (token === null || identityKey === null) return
    let cancelled = false
    meApi
      .getAccess()
      .then(info => {
        if (!cancelled) setStored({ key: identityKey, state: { status: 'ready', info } })
      })
      .catch((error: unknown) => {
        if (cancelled) return
        setStored(prev => {
          if (prev && prev.key === identityKey && prev.state.status === 'ready') return prev
          return {
            key: identityKey,
            state: { status: 'error', error, retry: () => {
              setStored({ key: identityKey, state: LOADING })
              setAttempt(a => a + 1)
            } },
          }
        })
      })
    return () => {
      cancelled = true
    }
  }, [token, identityKey, attempt])

  const state = stored !== null && stored.key === identityKey ? stored.state : LOADING
  return <AccessContext.Provider value={state}>{children}</AccessContext.Provider>
}

