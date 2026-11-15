/** useAssetCountsWrite — T-1933 / REQ-822 (K7a). One write call with a double-submit guard. An accepted answer (and a
 *  refused one, whose screen state may be old) reloads the count queries. The count routes read no idempotency key. */
import { useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { assetsQueryKeys } from '../assetsQueryKeys'

export type CountsWriteResult<R> = { ok: true; data: R } | { ok: false }

export function useAssetCountsWrite<TArg, R>(call: (arg: TArg) => Promise<R>) {
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [isPending, setPending] = useState(false)
  const pendingRef = useRef(false)
  const [error, setError] = useState<unknown>(null)

  async function submit(arg: TArg): Promise<CountsWriteResult<R>> {
    if (pendingRef.current) return { ok: false }
    pendingRef.current = true
    setPending(true)
    setError(null)
    try {
      const data = await call(arg)
      await queryClient.invalidateQueries({ queryKey: assetsQueryKeys.counts(tenantId) })
      return { ok: true, data }
    } catch (err) {
      setError(err)
      void queryClient.invalidateQueries({ queryKey: assetsQueryKeys.counts(tenantId) })
      return { ok: false }
    } finally {
      pendingRef.current = false
      setPending(false)
    }
  }
  return { submit, isPending, error, reset: () => setError(null) }
}
