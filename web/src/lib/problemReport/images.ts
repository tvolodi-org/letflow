/** Image utilities for the "Report a problem" dialog (T-2015).
 *  processImageFile: draws to canvas (strips EXIF), validates size/type, returns a ReportImage.
 *  extractPastedImages / extractDroppedImages: pick image files from clipboard / drop events. */

export const MAX_IMAGES = 3
export const MAX_IMAGE_BYTES = 5_242_880
export const ACCEPTED_TYPES = ['image/png', 'image/jpeg', 'image/webp']
/** Maximum total raw bytes across all images in one report. The server's JSON body cap is 2 MiB;
 *  base64 adds ~33% overhead plus the JSON structure (~10 KB), so total raw image bytes must
 *  stay under ~1.3 MiB to fit comfortably within the 2 MiB body limit. */
export const MAX_TOTAL_BYTES = 1_300_000

export interface ReportImage {
  dataBase64: string
  contentType: 'image/png' | 'image/jpeg'
  preview: string
  name: string
  /** Raw byte count of the decoded image (used to enforce MAX_TOTAL_BYTES). */
  size: number
}

/** Processes one image file: validates MIME type, re-encodes through canvas (strips EXIF metadata),
 *  validates size, returns a ReportImage or null on any error. Never throws. */
export async function processImageFile(file: File): Promise<ReportImage | null> {
  try {
    if (!ACCEPTED_TYPES.includes(file.type)) return null

    const blobUrl = URL.createObjectURL(file)
    try {
      const img = await loadImage(blobUrl)
      const canvas = document.createElement('canvas')
      canvas.width = img.naturalWidth
      canvas.height = img.naturalHeight
      const ctx = canvas.getContext('2d')
      if (!ctx) return null
      ctx.drawImage(img, 0, 0)

      const outputMime: 'image/png' | 'image/jpeg' = file.type === 'image/png' ? 'image/png' : 'image/jpeg'
      const dataUrl = canvas.toDataURL(outputMime)
      // dataUrl is "data:<mime>;base64,<data>"
      const comma = dataUrl.indexOf(',')
      if (comma === -1) return null
      const dataBase64 = dataUrl.slice(comma + 1)

      const size = atob(dataBase64).length
      if (size > MAX_IMAGE_BYTES) return null

      return { dataBase64, contentType: outputMime, preview: dataUrl, name: file.name, size }
    } finally {
      URL.revokeObjectURL(blobUrl)
    }
  } catch {
    return null
  }
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}

/** Returns image Files from a ClipboardEvent. */
export function extractPastedImages(e: ClipboardEvent): File[] {
  if (!e.clipboardData) return []
  return Array.from(e.clipboardData.files).filter((f) => ACCEPTED_TYPES.includes(f.type))
}

/** Returns image Files from a DragEvent. */
export function extractDroppedImages(e: DragEvent): File[] {
  if (!e.dataTransfer) return []
  return Array.from(e.dataTransfer.files).filter((f) => ACCEPTED_TYPES.includes(f.type))
}
