/** useLabelsPrint — E3b (REQ-779 web half). Asks the label route for a PDF of the chosen codes and saves it.
 *  Nothing is written on the server, so no idempotency key and a retry is safe; one request at a time. */
import { useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { codesApi } from './codes.api'
import { reasonOf } from './codesModel'
import { codesQueryKeys } from './codesQueryKeys'
import { saveBlob } from '@/lib/saveBlob'

export type LabelsPrintResult = 'ok' | 'notFound' | 'error'

/** The file name the server sends (`Content-Disposition`); `postBlob` returns no headers, so it is fixed here. */
export const LABELS_FILE_NAME = 'code-labels.pdf'

export function useLabelsPrint(initialError: unknown = null) {
  const queryClient = useQueryClient()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [isPending, setPending] = useState(false)
  const pendingRef = useRef(false)
  const [error, setError] = useState<unknown>(initialError)

  async function print(ids: string[]): Promise<LabelsPrintResult> {
    if (pendingRef.current) return 'error'
    pendingRef.current = true
    setPending(true)
    setError(null)
    try {
      const { blob } = await codesApi.labels(ids)
      saveBlob(blob, LABELS_FILE_NAME)
      return 'ok'
    } catch (err) {
      setError(err)
      if (reasonOf(err).status === 404) {
        await queryClient.invalidateQueries({ queryKey: codesQueryKeys.all(tenantId) })
        return 'notFound'
      }
      return 'error'
    } finally {
      pendingRef.current = false
      setPending(false)
    }
  }

  return { print, isPending, error, clearError: () => setError(null) }
}
