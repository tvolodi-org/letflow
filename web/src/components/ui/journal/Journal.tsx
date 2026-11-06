/** Journal — the lf-journal shell: operations list on the left, the legs of the selected operation on the right
 *  (NOTES.md "lf-journal"). Under 900 px the CSS shows the narrow variant named by `data-variant`; this component only
 *  sets the attributes, the scrim of the sheet variant and the Escape rule. It knows no module words: the list and the
 *  details come in as nodes built from JournalList and JournalDetails. */
import type { KeyboardEvent, ReactNode } from 'react'
import {
  DEFAULT_JOURNAL_LAYOUT,
  DEFAULT_JOURNAL_VARIANT,
  type JournalLayout,
  type JournalVariant,
} from './journalLayouts'

export interface JournalProps {
  layout?: JournalLayout
  variant?: JournalVariant
  list: ReactNode
  details: ReactNode
  /** The details pane is open: under 900 px it replaces the list (v1, v3) or slides over it (v2). */
  detailOpen: boolean
  filtersOpen: boolean
  /** Escape closes the open details. */
  onClose?: () => void
}

export function Journal(props: JournalProps) {
  const layout = props.layout ?? DEFAULT_JOURNAL_LAYOUT
  const variant = props.variant ?? DEFAULT_JOURNAL_VARIANT

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key !== 'Escape' || !props.detailOpen || !props.onClose || e.defaultPrevented) return
    props.onClose()
  }

  return (
    <div
      className="lf-jrn"
      data-testid="journal"
      data-layout={layout}
      data-variant={variant}
      data-detail={props.detailOpen ? 'open' : 'closed'}
      data-filters={props.filtersOpen ? 'open' : 'closed'}
      onKeyDown={onKeyDown}
    >
      {variant === 'v2' && <div className="lf-jrn__scrim" data-testid="journal-scrim" onClick={props.onClose} />}
      {props.list}
      {props.details}
    </div>
  )
}
