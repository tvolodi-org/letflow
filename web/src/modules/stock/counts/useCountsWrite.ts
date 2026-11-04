/** useCountsWrite — GH 3735 / REQ-702. One write call with a double-submit guard. An accepted answer (and a 404)
 *  reloads the count queries. count_write reads no idempotency key, so none is sent. */
import { useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { countsQueryKeys } from './countsQueryKeys'

export type CountsWriteResult<R> = { ok: true; data: R } | { ok: false }

export function useCountsWrite<TArg, R>(call: (arg: TArg) => Promise<R>) {
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
      await queryClient.invalidateQueries({ queryKey: countsQueryKeys.all(tenantId) })
      return { ok: true, data }
    } catch (err) {
      setError(err)
      // A refused state change means the screen shows an old state: reload it.
      void queryClient.invalidateQueries({ queryKey: countsQueryKeys.all(tenantId) })
      return { ok: false }
    } finally {
      pendingRef.current = false
      setPending(false)
    }
  }
  return { submit, isPending, error, reset: () => setError(null) }
}
