/** JournalList — the list pane of the journal: head (title, Filters toggle, Export), the filters slot, the operations
 *  table (roving-tabindex rows, V1 expand button with the legs inline and a Details button) and its states: loading,
 *  error, empty, no match, no permission. Every string comes in through props. */
import { Fragment, useRef, type KeyboardEvent, type ReactNode } from 'react'
import { ChevronDown, Download, Inbox, Lock, Search } from 'lucide-react'
import { Link } from 'react-router-dom'
import { Button } from '../Button'
import { EmptyState } from '../EmptyState'
import { JournalLegs, JournalRef, JournalSigned, JournalStatusPill, type JournalLegsLabels } from './JournalDetails'
import { useColResize, type ColSpec } from '../layout/ColumnResize'
import { useLayoutMessages } from '../layout/layoutMessages'
import type { JournalOp } from './journalTypes'
import type { JournalVariant } from './journalLayouts'

export interface JournalListLabels {
  title: string
  filters: string
  export: string
  details: string
  expand: string
  collapse: string
  clearFilters: string
  more: (n: number) => string
  columns: { date: string; kind: string; doc: string; item: string; qty: string; location: string; status: string }
  legs: JournalLegsLabels
}

export interface JournalListProps {
  titleId: string
  variant: JournalVariant
  /** Screen id of the remembered layout (column widths). */
  layoutScreen: string
  labels: JournalListLabels
  state: 'ready' | 'loading' | 'error' | 'noperm'
  /** The error banner (with Retry) the module builds. */
  errorNode?: ReactNode
  ops: JournalOp[]
  selectedId: string | null
  expandedId: string | null
  /** Click on a row: the caller decides by the screen width (select, expand or open). */
  onRow: (op: JournalOp) => void
  onToggleExpand: (op: JournalOp) => void
  onDetails: (op: JournalOp) => void
  /** The filter controls (selects, fields). */
  filtersNode: ReactNode
  filterCount: number
  filtersOpen: boolean
  onToggleFilters: () => void
  onClearFilters: () => void
  filtered: boolean
  empty: { title: string; text: string }
  noMatch: { title: string; text: string }
  /** Shown for state 'noperm' (a screen that can tell the user may not read). */
  noPerm?: { title: string; text: string }
  /** Export button; omitted (undefined) when the user cannot read. */
  onExport?: () => void
  exporting?: boolean
  /** "Showing 25" */
  rangeText: string
  /** Load more button. */
  foot?: ReactNode
  /** Notice under the head (export failed). */
  notice?: ReactNode
}

/** Widths of the operations table in percent (the status, last, takes the rest); the smallest width in px. */
const OPS_COLS: ColSpec[] = [
  { id: 'date', w: 15, min: 110 },
  { id: 'kind', w: 13, min: 100 },
  { id: 'doc', w: 14, min: 120 },
  { id: 'item', w: 22, min: 160 },
  { id: 'qty', w: 9, min: 70 },
  { id: 'loc', w: 12, min: 100 },
  { id: 'st', w: 0, min: 90 },
]

/** Column handles only while the journal area is wide (the same 900 px as the CSS and the divider). */
const wideArea = (table: HTMLElement | null) => ((table?.closest('.lf-jrn') as HTMLElement | null)?.clientWidth ?? 0) > 900

export function JournalList(p: JournalListProps) {
  const L = p.labels
  const bodyRef = useRef<HTMLTableSectionElement>(null)
  const tableRef = useRef<HTMLTableElement>(null)
  const word = useLayoutMessages().resizeColumn
  useColResize(tableRef, {
    id: 'ops',
    screen: p.layoutScreen,
    cols: OPS_COLS,
    label: (_id, th) => `${word}: ${th.textContent?.trim() ?? ''}`,
    enabled: () => wideArea(tableRef.current),
  })

  function moveFocus(from: HTMLElement, to: 'next' | 'prev' | 'first' | 'last') {
    const rows = Array.from(bodyRef.current?.querySelectorAll<HTMLElement>('[data-nav]') ?? [])
    const i = rows.indexOf(from)
    const target = to === 'first' ? rows[0] : to === 'last' ? rows[rows.length - 1] : rows[i + (to === 'next' ? 1 : -1)]
    if (!target) return
    rows.forEach((r) => (r.tabIndex = -1))
    target.tabIndex = 0
    target.focus()
  }

  function onRowKey(e: KeyboardEvent<HTMLTableRowElement>, op: JournalOp) {
    if (e.target !== e.currentTarget) return
    const el = e.currentTarget
    if (e.key === 'ArrowDown') moveFocus(el, 'next')
    else if (e.key === 'ArrowUp') moveFocus(el, 'prev')
    else if (e.key === 'Home') moveFocus(el, 'first')
    else if (e.key === 'End') moveFocus(el, 'last')
    else if (e.key === 'Enter' || e.key === ' ') p.onRow(op)
    else return
    e.preventDefault()
  }

  const firstFocus = !p.ops.some((o) => o.id === p.selectedId)

  function body(): ReactNode {
    if (p.state === 'noperm') {
      return (
        <div className="lf-reg__body" data-testid="journal-noperm">
          <EmptyState icon={<Lock className="lf-icon lf-empty__icon" aria-hidden="true" />} title={p.noPerm?.title ?? ''} text={p.noPerm?.text} />
        </div>
      )
    }
    if (p.state === 'loading') {
      return (
        <div className="lf-reg__body" data-testid="journal-loading">
          <div className="lf-reg__skel" aria-busy="true">
            {Array.from({ length: 8 }, (_, i) => (
              <span className="lf-skel" key={i} />
            ))}
          </div>
        </div>
      )
    }
    if (p.state === 'error') {
      return <div className="lf-reg__state" data-testid="journal-error">{p.errorNode}</div>
    }
    if (p.ops.length === 0) {
      const t = p.filtered ? p.noMatch : p.empty
      return (
        <div className="lf-reg__body" data-testid={p.filtered ? 'journal-nomatch' : 'journal-empty'}>
          <EmptyState
            icon={<Inbox className="lf-icon lf-empty__icon" aria-hidden="true" />}
            title={t.title}
            text={t.text}
            action={
              p.filtered ? (
                <Button variant="secondary" onClick={p.onClearFilters} data-testid="journal-clear-empty">
                  {L.clearFilters}
                </Button>
              ) : undefined
            }
          />
        </div>
      )
    }
    const v1 = p.variant === 'v1'
    return (
      <>
        <div className="lf-reg__body lf-table-wrap">
          <table ref={tableRef} className="lf-table lf-table--compact lf-jrn__table" role="grid" aria-label={L.title} aria-rowcount={p.ops.length}>
            <thead>
              <tr role="row">
                <th scope="col" data-col="date">{L.columns.date}</th>
                <th scope="col" data-col="kind">{L.columns.kind}</th>
                <th scope="col" data-col="doc">{L.columns.doc}</th>
                <th scope="col" data-col="item">{L.columns.item}</th>
                <th scope="col" data-col="qty" className="c-qty">{L.columns.qty}</th>
                <th scope="col" data-col="loc" className="is-opt c-loc">{L.columns.location}</th>
                <th scope="col" data-col="st">{L.columns.status}</th>
              </tr>
            </thead>
            <tbody ref={bodyRef}>
              {p.ops.map((op, i) => {
                const on = op.id === p.selectedId
                const ex = p.expandedId === op.id
                const cls = ['lf-reg__row', 'lf-jrn__row', on ? 'is-selected' : '', op.status === 'reversed' ? 'is-reversed' : '']
                  .filter(Boolean)
                  .join(' ')
                return (
                  <Fragment key={op.id}>
                    <tr
                      className={cls}
                      role="row"
                      data-nav
                      data-testid="journal-row"
                      data-id={op.id}
                      aria-selected={on}
                      aria-expanded={v1 ? ex : undefined}
                      tabIndex={on || (firstFocus && i === 0) ? 0 : -1}
                      onClick={() => p.onRow(op)}
                      onKeyDown={(e) => onRowKey(e, op)}
                    >
                      <td className="c-date" role="gridcell">{op.time}</td>
                      <td className="c-kind" role="gridcell"><span className="lf-jrn__kind">{op.kindIcon}{op.kindLabel}</span></td>
                      <td className="c-doc" role="gridcell">
                        {op.docHref ? (
                          <Link to={op.docHref} data-testid="journal-doc-link" onClick={(e) => e.stopPropagation()}>
                            <DocText op={op} />
                          </Link>
                        ) : (
                          <DocText op={op} />
                        )}
                      </td>
                      <td className="c-item" role="gridcell">
                        {op.item !== '' && <JournalRef text={shorten(op.item)} full={op.item} className="lf-ref--trunc" />}
                        {op.itemMore > 0 && <span className="lf-jrn__more">{L.more(op.itemMore)}</span>}
                      </td>
                      <td className="c-qty" role="gridcell">
                        <span><JournalSigned sign={op.qtySign} text={op.qty} /></span>
                        {v1 && (
                          <button
                            type="button"
                            className="lf-jrn__expand"
                            tabIndex={-1}
                            aria-label={ex ? L.collapse : L.expand}
                            data-testid="journal-expand"
                            onClick={(e) => {
                              e.stopPropagation()
                              p.onToggleExpand(op)
                            }}
                          >
                            <ChevronDown className="lf-icon" aria-hidden="true" />
                          </button>
                        )}
                      </td>
                      <td className="c-loc is-opt" role="gridcell">
                        {op.location !== '' && <JournalRef text={shorten(op.location)} full={op.location} className="lf-ref--trunc" />}
                        {op.locationMore > 0 && <span className="lf-jrn__more">{L.more(op.locationMore)}</span>}
                      </td>
                      <td className="c-st" role="gridcell">
                        {/* the note ("Reversed by ...") is long and the list pane is narrow next to the sidebar: it is the
                            tooltip here and a line in the details pane */}
                        <span title={op.statusNote || undefined}>
                          <JournalStatusPill status={op.status} label={op.statusLabel} />
                        </span>
                      </td>
                    </tr>
                    {v1 && ex && (
                      <tr className="lf-jrn__legsrow is-open" role="row" data-testid="journal-legsrow">
                        <td role="gridcell" colSpan={7}>
                          <JournalLegs legs={op.legs} compact labels={L.legs} />
                          <div className="lf-btn-row">
                            <Button variant="secondary" size="sm" onClick={() => p.onDetails(op)} data-testid="journal-details-btn">
                              {L.details}
                            </Button>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                )
              })}
            </tbody>
          </table>
        </div>
        <div className="lf-table-foot lf-reg__foot">
          <span className="mono-s" data-testid="journal-range">{p.rangeText}</span>
          {p.foot}
        </div>
      </>
    )
  }

  return (
    <section className="lf-card lf-reg__list lf-jrn__list" aria-labelledby={p.titleId} data-testid="journal-list">
      <div className="lf-reg__tools">
        <div className="lf-reg__listhead">
          <h2 className="lf-reg__sectitle" id={p.titleId}>{L.title}</h2>
          <div className="lf-btn-row">
            <Button
              variant="ghost"
              size="sm"
              className="lf-jrn__filters-toggle"
              icon={<Search className="lf-icon" aria-hidden="true" />}
              onClick={p.onToggleFilters}
              data-testid="journal-filters-toggle"
            >
              {p.filterCount > 0 ? `${L.filters} (${p.filterCount})` : L.filters}
            </Button>
            {p.onExport && p.state !== 'noperm' && (
              <Button
                variant="secondary"
                size="sm"
                loading={p.exporting}
                disabled={p.state === 'loading' || p.state === 'error'}
                icon={<Download className="lf-icon" aria-hidden="true" />}
                onClick={p.onExport}
                data-testid="journal-export"
              >
                {L.export}
              </Button>
            )}
          </div>
        </div>
        {p.state !== 'noperm' && (
          <div className="lf-jrn__filters" data-testid="journal-filters">
            {p.filtersNode}
            {p.filterCount > 0 && (
              <div className="lf-reg__chips">
                <Button variant="ghost" size="sm" onClick={p.onClearFilters} data-testid="journal-clear">
                  {L.clearFilters}
                </Button>
              </div>
            )}
          </div>
        )}
        {p.notice}
      </div>
      {body()}
    </section>
  )
}

/** "RCP-2026-000001 - Receipt": the number with the kind on a muted second line (the text stays one string for readers
 *  and copy); with no number the kind alone. */
function DocText({ op }: { op: JournalOp }) {
  if (op.docNumber && op.docKind) {
    return (
      <>
        {op.docNumber}
        <span className="sr-only"> - </span>
        <span className="lf-jrn__of">{op.docKind}</span>
      </>
    )
  }
  return <>{op.docText}</>
}

/** The narrow rows give the reference no width to cut at (the CSS lifts the 17ch cap under 900 px and the cell is a block),
 *  so a very long title is cut here; the whole text stays in the tooltip. */
const MAX_REF_CHARS = 34
function shorten(text: string): string {
  return text.length > MAX_REF_CHARS ? `${text.slice(0, MAX_REF_CHARS - 1).trimEnd()}…` : text
}
