/** useAssetsWrite — T-1333 / C13. One write call with a safe idempotency key: the same body (and target)
 *  retried after a failure reuses the key; an edited body takes a new key (else the server answers 409
 *  idempotency_key_reuse). An accepted answer reloads the lists. */
import { useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { assetsQueryKeys } from './assetsQueryKeys'
import { reasonOf } from './assetsModel'

export type AssetsWriteResult = 'ok' | 'notFound' | 'error'

function newKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `k-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

export function useAssetsWrite<TBody>(call: (body: TBody, key: string) => Promise<unknown>) {
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const attempt = useRef<{ key: string; fingerprint: string } | null>(null)
  const [isPending, setPending] = useState(false)
  const pendingRef = useRef(false)
  const [error, setError] = useState<unknown>(null)
  const lastId = useRef<string | null>(null)

  async function submit(body: TBody, target = ''): Promise<AssetsWriteResult> {
    if (pendingRef.current) return 'error'
    pendingRef.current = true
    const fingerprint = `${target}|${JSON.stringify(body)}`
    const key = attempt.current && attempt.current.fingerprint === fingerprint ? attempt.current.key : newKey()
    attempt.current = { key, fingerprint }
    setPending(true)
    setError(null)
    try {
      const answer = await call(body, key)
      const rid = (answer as { record_id?: unknown } | null | undefined)?.record_id
      lastId.current = typeof rid === 'string' ? rid : null
      attempt.current = null
      await queryClient.invalidateQueries({ queryKey: assetsQueryKeys.all(tenantId) })
      return 'ok'
    } catch (err) {
      setError(err)
      if (reasonOf(err).status === 404) {
        attempt.current = null
        await queryClient.invalidateQueries({ queryKey: assetsQueryKeys.all(tenantId) })
        return 'notFound'
      }
      return 'error'
    } finally {
      pendingRef.current = false
      setPending(false)
    }
  }

  /** `lastId`: record_id of the last accepted answer (the created record), or null. */
  return { submit, isPending, error, clearError: () => setError(null), lastId: () => lastId.current }
}
