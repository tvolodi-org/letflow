/** Photo list answers of the asset card gallery harness fixtures (T-2042): shaped as the T-2041 routes answer. */

export interface PhotoSpec {
  id: string
  caption: string | null
  /** a CSS colour name for the drawn image */
  color: string
  noThumbnail?: boolean
}

export function listOf(specs: PhotoSpec[], opts: { canAdd: boolean; canDelete: boolean; max: number }) {
  return {
    photos: specs.map((s, i) => ({
      id: s.id,
      position: i + 1,
      is_main: i === 0,
      caption: s.caption,
      has_thumbnail: s.noThumbnail !== true,
      inserted_at: '2026-11-10T09:00:00Z',
      locked: false,
      can_delete: opts.canDelete,
    })),
    can_add: opts.canAdd,
    can_delete_any: opts.canDelete,
    limits: {
      max_photos: opts.max,
      original_max_bytes: 5_000_000,
      original_max_px: 4096,
      thumbnail_max_bytes: 200_000,
      thumbnail_max_px: 512,
      caption_max: 200,
    },
  }
}
