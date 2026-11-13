/** Journal — the lf-journal shell: operations list on the left, the legs of the selected operation on the right
 *  (NOTES.md "lf-journal"). Under 900 px the CSS shows the narrow variant named by `data-variant`; this component only
 *  sets the attributes, the scrim of the sheet variant and the Escape rule. It knows no module words: the list and the
 *  details come in as nodes built from JournalList and JournalDetails. */
import { useRef, type KeyboardEvent, type ReactNode } from 'react'
import { SplitWrap, useSplit } from '../layout/Splitter'
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
  /** Screen id of the remembered layout (pane size, column widths), e.g. "stock.journal". */
  layoutScreen: string
  /** Name of the divider between the list and the details ("Movement details"). */
  splitLabel: string
}

/** The same width rule as the CSS container query and the page: wide means the journal area is over 900 px. */
const wide = (el: HTMLElement | null) => (el?.clientWidth ?? 0) > 900

export function Journal(props: JournalProps) {
  const layout = props.layout ?? DEFAULT_JOURNAL_LAYOUT
  const variant = props.variant ?? DEFAULT_JOURNAL_VARIANT

  const gridRef = useRef<HTMLDivElement>(null)
  const layerRef = useRef<HTMLDivElement>(null)
  useSplit(gridRef, layerRef, {
    // the same setup as the balances screens (verdict 4.3 item 3): the divider collapses the operations list
    id: 'list',
    screen: props.layoutScreen,
    vars: ['--lf-pane-1'],
    unit: 'pct',
    sized: 'before',
    min: [360],
    flexMin: 460,
    collapsible: [0],
    clampStored: true,
    defaults: [60],
    labels: [props.splitLabel],
    // the V2 scrim is a third grid child and is not a pane
    panes: () => {
      const list = gridRef.current?.querySelector<HTMLElement>(':scope > .lf-jrn__list') ?? null
      const det = gridRef.current?.querySelector<HTMLElement>(':scope > .lf-jrn__details') ?? null
      return list && det ? [list, det] : []
    },
    enabled: () => wide(gridRef.current),
  })

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key !== 'Escape' || !props.detailOpen || !props.onClose || e.defaultPrevented) return
    props.onClose()
  }

  return (
    <SplitWrap layerRef={layerRef}>
    <div
      ref={gridRef}
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
    </SplitWrap>
  )
}
