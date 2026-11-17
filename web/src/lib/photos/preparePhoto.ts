/** preparePhoto — T-2042 (photos P3). Browser-side preparation of one photo before upload: the pixels are drawn
 *  orientation-correct on a canvas (this also removes client metadata; the server strips again), the original is
 *  scaled to at most 2048 px on its long edge and the thumbnail to at most 320 px, both encoded as JPEG quality 0.85.
 *  No image library. Failures are returned as a reason code the caller maps to a translated message. */

export const ORIGINAL_EDGE = 2048
export const THUMBNAIL_EDGE = 320
export const JPEG_QUALITY = 0.85

export interface PhotoCaps {
  original_max_bytes: number
  original_max_px: number
  thumbnail_max_bytes: number
  thumbnail_max_px: number
}

export type PrepareFailure = 'type' | 'decode' | 'encode' | 'too_large'

export type Prepared = { ok: true; original: Blob; thumbnail: Blob } | { ok: false; reason: PrepareFailure }

/** Size that fits within `edge` on the long side, never enlarging; both sides at least 1. */
export function fitWithin(width: number, height: number, edge: number): { width: number; height: number } {
  const longest = Math.max(width, height)
  if (longest <= edge) return { width, height }
  const scale = edge / longest
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

const ACCEPTED = /^image\/(jpeg|png|webp|heic|heif)$/i
const ACCEPTED_NAME = /\.(jpe?g|png|webp|heic|heif)$/i

/** Early UX only: the server's first-byte check stays authoritative. HEIC may carry an empty type in some browsers. */
export function isAcceptedImage(file: { type: string; name: string }): boolean {
  return ACCEPTED.test(file.type) || (file.type === '' && ACCEPTED_NAME.test(file.name))
}

interface Decoded {
  source: CanvasImageSource
  width: number
  height: number
  release: () => void
}

async function decode(file: Blob): Promise<Decoded> {
  if (typeof createImageBitmap === 'function') {
    const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
    return { source: bitmap, width: bitmap.width, height: bitmap.height, release: () => bitmap.close?.() }
  }
  const url = URL.createObjectURL(file)
  try {
    const img = new Image()
    await new Promise<void>((resolve, reject) => {
      img.onload = () => resolve()
      img.onerror = () => reject(new Error('decode'))
      img.src = url
    })
    return { source: img, width: img.naturalWidth, height: img.naturalHeight, release: () => undefined }
  } finally {
    URL.revokeObjectURL(url)
  }
}

function encode(decoded: Decoded, edge: number): Promise<Blob | null> {
  const size = fitWithin(decoded.width, decoded.height, edge)
  const canvas = document.createElement('canvas')
  canvas.width = size.width
  canvas.height = size.height
  const ctx = canvas.getContext('2d')
  if (!ctx) return Promise.resolve(null)
  // JPEG has no alpha: paint a white page first so a transparent PNG does not turn black
  ctx.fillStyle = 'white'
  ctx.fillRect(0, 0, size.width, size.height)
  ctx.drawImage(decoded.source, 0, 0, size.width, size.height)
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b), 'image/jpeg', JPEG_QUALITY))
}

export async function preparePhoto(file: File, caps: PhotoCaps): Promise<Prepared> {
  if (!isAcceptedImage(file)) return { ok: false, reason: 'type' }
  let decoded: Decoded
  try {
    decoded = await decode(file)
  } catch {
    return { ok: false, reason: 'decode' }
  }
  try {
    const original = await encode(decoded, Math.min(ORIGINAL_EDGE, caps.original_max_px))
    const thumbnail = await encode(decoded, Math.min(THUMBNAIL_EDGE, caps.thumbnail_max_px))
    if (original === null || thumbnail === null) return { ok: false, reason: 'encode' }
    if (original.size > caps.original_max_bytes || thumbnail.size > caps.thumbnail_max_bytes) {
      return { ok: false, reason: 'too_large' }
    }
    return { ok: true, original, thumbnail }
  } catch {
    return { ok: false, reason: 'encode' }
  } finally {
    decoded.release()
  }
}
