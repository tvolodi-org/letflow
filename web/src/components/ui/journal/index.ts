/** The journal component (lf-journal): operations list left, legs of the selected operation right. See Journal.tsx. */
export { Journal, type JournalProps } from './Journal'
export { JournalList, type JournalListProps, type JournalListLabels } from './JournalList'
export {
  JournalDetails, JournalLegs, JournalRef, JournalSigned, JournalStatusPill,
  type JournalDetailsProps, type JournalDetailsLabels, type JournalLegsLabels,
} from './JournalDetails'
export type { JournalOp, JournalLeg, JournalSign, JournalStatus } from './journalTypes'
export {
  DEFAULT_JOURNAL_LAYOUT, DEFAULT_JOURNAL_VARIANT, JOURNAL_LAYOUTS, JOURNAL_VARIANTS, isJournalVariant,
  type JournalLayout, type JournalVariant,
} from './journalLayouts'
