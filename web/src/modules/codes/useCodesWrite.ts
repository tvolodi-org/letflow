/** useCodesWrite — GH 3606 / REQ-672. One write call with a safe idempotency key: the same body (and target)
 *  retried after a failure reuses the key; an edited body takes a new key (else the server answers 409
 *  idempotency_key_reuse). An accepted answer reloads the lists. */
import { useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { codesQueryKeys } from './codesQueryKeys'
import { reasonOf } from './codesModel'

export type CodesWriteResult = 'ok' | 'notFound' | 'error'

function newKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `k-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

export function useCodesWrite<TBody>(call: (body: TBody, key: string) => Promise<unknown>) {
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const attempt = useRef<{ key: string; fingerprint: string } | null>(null)
  const [isPending, setPending] = useState(false)
  const pendingRef = useRef(false)
  const [error, setError] = useState<unknown>(null)

  async function submit(body: TBody, target = ''): Promise<CodesWriteResult> {
    if (pendingRef.current) return 'error'
    pendingRef.current = true
    const fingerprint = `${target}|${JSON.stringify(body)}`
    const key = attempt.current && attempt.current.fingerprint === fingerprint ? attempt.current.key : newKey()
    attempt.current = { key, fingerprint }
    setPending(true)
    setError(null)
    try {
      await call(body, key)
      attempt.current = null
      await queryClient.invalidateQueries({ queryKey: codesQueryKeys.all(tenantId) })
      return 'ok'
    } catch (err) {
      setError(err)
      if (reasonOf(err).status === 404) {
        attempt.current = null
        await queryClient.invalidateQueries({ queryKey: codesQueryKeys.all(tenantId) })
        return 'notFound'
      }
      return 'error'
    } finally {
      pendingRef.current = false
      setPending(false)
    }
  }

  return { submit, isPending, error, clearError: () => setError(null) }
}
