/** useObjectUrl — T-2042. A revocable object URL for a Blob: created when the blob arrives, revoked when it is
 *  replaced or the component unmounts. Raw backend URLs are never used as an image source (no bearer token). */
import { useEffect, useState } from 'react'

export function useObjectUrl(blob: Blob | null | undefined): string | null {
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    if (!blob) {
      setUrl(null)
      return
    }
    const next = URL.createObjectURL(blob)
    setUrl(next)
    return () => {
      URL.revokeObjectURL(next)
    }
  }, [blob])
  return url
}
