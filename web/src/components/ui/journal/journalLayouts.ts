/** journalLayouts — the layouts and narrow variants of the journal (platform NOTES.md "lf-journal", `LFJrnLayout`).
 *  A layout is one entry here plus CSS under `.lf-jrn[data-layout="<name>"]` in components.css; a screen names a
 *  layout and never arranges the panes itself. Under 900 px the CSS shows one of three variants (`data-variant`):
 *  v1 legs inline under the row (default), v2 bottom sheet (kept as an option), v3 full-screen details. */
export const JOURNAL_LAYOUTS = {
  split: { name: 'split' },
} as const

export type JournalLayout = keyof typeof JOURNAL_LAYOUTS

export const DEFAULT_JOURNAL_LAYOUT: JournalLayout = 'split'

export const JOURNAL_VARIANTS = ['v1', 'v2', 'v3'] as const
export type JournalVariant = (typeof JOURNAL_VARIANTS)[number]

/** Owner decision 2026-11-06: V1 inline legs, details full-screen (V3 behaviour) from the Details button; V2 not default. */
export const DEFAULT_JOURNAL_VARIANT: JournalVariant = 'v1'

export function isJournalVariant(v: unknown): v is JournalVariant {
  return typeof v === 'string' && (JOURNAL_VARIANTS as readonly string[]).includes(v)
}
