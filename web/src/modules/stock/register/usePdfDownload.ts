/** usePdfDownload — REQ-738. One file download at a time for a screen: fetch the blob (client.getBlob, bearer header),
 *  save it under the Content-Disposition name (else the fallback), keep a refusal as a message id so it follows the
 *  language switch. A ref guards the single flight: two clicks in one tick send one request. */
import { useCallback, useRef, useState } from 'react'
import { saveBlob } from './saveBlob'

export interface FetchedFile {
  blob: Blob
  contentDisposition: string | null
}

export function usePdfDownload(parseName: (header: string | null, fallback: string) => string) {
  const flying = useRef(false)
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const run = useCallback(
    async (key: string, fetchFile: () => Promise<FetchedFile>, fallbackName: string, errorId: (err: unknown) => string) => {
      if (flying.current) return
      flying.current = true
      setBusyKey(key)
      setError(null)
      try {
        const { blob, contentDisposition } = await fetchFile()
        saveBlob(blob, parseName(contentDisposition, fallbackName))
      } catch (err) {
        setError(errorId(err))
      } finally {
        flying.current = false
        setBusyKey(null)
      }
    },
    [parseName],
  )
  return { busyKey, error, run }
}
