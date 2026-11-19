/** cardPhotosModel — T-2042 (photos P3). Types of the card gallery answers (routes of T-2041), the local staging item
 *  of an upload, and the photo-specific error mapping. The asset card errors (`assetsModel.errorMessageId`) are not
 *  used: they map every 409 to "idempotency key reused", which is wrong for a lock or a full storage. */
import { reasonOf } from './assetsModel'

export interface CardPhoto {
  id: string
  position: number
  is_main: boolean
  caption: string | null
  has_thumbnail: boolean
  inserted_at: string
  locked: boolean
  can_delete: boolean
}

export interface CardPhotoLimits {
  max_photos: number
  original_max_bytes: number
  original_max_px: number
  thumbnail_max_bytes: number
  thumbnail_max_px: number
  caption_max: number
}

export interface CardPhotoList {
  photos: CardPhoto[]
  can_add: boolean
  can_delete_any: boolean
  limits: CardPhotoLimits
}

/** One image chosen but not yet stored. `preparing` while the browser decodes and scales it. */
export interface StagedPhoto {
  key: string
  label: string
  state: 'preparing' | 'ready' | 'uploading' | 'failed'
  /** message id of the plain reason when `failed` */
  errorId?: string
  original?: Blob
  thumbnail?: Blob
}

const REASONS = [
  'photo_type_not_allowed',
  'photo_malformed',
  'photo_too_large',
  'photo_infected',
  'owner_cap_reached',
  'caption_invalid',
  'invalid_order',
  'photos_add_required',
  'photos_delete_required',
  'photo_not_own',
  'photo_locked',
  'storage_quota_exceeded',
  'upload_rate_exceeded',
  'scan_unavailable',
] as const

/** The message id for a refused photo call; unknown failures use the generic text (with Retry). */
export function photoErrorId(err: unknown): string {
  const info = reasonOf(err)
  if ((err as { details?: { code?: unknown } } | null)?.details?.code === 'request_too_large') {
    return 'assets.photos.error.photo_too_large'
  }
  if (info.reason !== undefined && (REASONS as readonly string[]).includes(info.reason)) {
    return `assets.photos.error.${info.reason}`
  }
  if (info.status === 404) return 'assets.photos.error.notFound'
  if (info.status === 403) return 'assets.photos.error.forbidden'
  if (info.status === 429) return 'assets.photos.error.upload_rate_exceeded'
  return 'assets.photos.error.generic'
}

/** Characters as the server counts them (code points), not UTF-16 units. */
export const codePoints = (text: string) => Array.from(text).length

/** Photos sorted for display: server position order. */
export const inOrder = (photos: CardPhoto[]) => [...photos].sort((a, b) => a.position - b.position)

/** The main photo that has a thumbnail to show in the list; none when the main photo has no thumbnail. */
export function mainThumbnail(list: CardPhotoList | undefined): CardPhoto | null {
  const main = list?.photos?.find((p) => p.is_main)
  return main !== undefined && main.has_thumbnail ? main : null
}
