/** RegistryList — the list pane of the registry: tools (title, search, filters, chips, Show retired), a compact table
 *  with sortable headers, roving-tabindex rows and a pager; loading, error, empty and no-match states.
 *  Generic over the row type; every string comes in through props (the message catalog of the caller). */
import { useRef, type KeyboardEvent, type ReactNode } from 'react'
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, ChevronsUpDown, Search, X } from 'lucide-react'
import { Banner } from '../Banner'
import { Button } from '../Button'
import { Checkbox } from '../Checkbox'
import { EmptyState } from '../EmptyState'

export interface RegistryColumn<T> {
  key: string
  header: string
  /** Hidden between 901 and 1100 px (design `is-opt`). */
  optional?: boolean
  mono?: boolean
  sortable?: boolean
  render: (row: T) => ReactNode
}

export type RegistrySortDir = 'asc' | 'desc'

export interface RegistryListLabels {
  search: string
  showRetired: string
  clearFilters: string
  removeFilter: string
  retry: string
  pages: string
  prev: string
  next: string
}

export interface RegistryChip {
  id: string
  label: string
  onRemove: () => void
}

export interface RegistryListProps<T> {
  title: string
  titleId: string
  labels: RegistryListLabels
  /** 'ready' draws the table; the others draw their own state. */
  state: 'ready' | 'loading' | 'error'
  errorTitle?: string
  errorText?: string
  onRetry?: () => void
  columns: RegistryColumn<T>[]
  rows: T[]
  rowId: (row: T) => string
  isRetired?: (row: T) => boolean
  selectedId: string | null
  onOpen: (row: T) => void
  query: string
  onQuery: (q: string) => void
  /** Extra filter controls (a select) in the second tool row. */
  filters?: ReactNode
  chips?: RegistryChip[]
  onClearFilters: () => void
  /** True when a search text or filter is active: an empty result then says "no match" instead of "empty". */
  filtered: boolean
  showRetired: boolean
  onShowRetired: (v: boolean) => void
  sortKey: string
  sortDir: RegistrySortDir
  onSort: (key: string) => void
  page: number
  pageCount: number
  onPage: (p: number) => void
  /** "1-25 of 120" */
  rangeText: string
  empty: { title: string; text: string; action?: ReactNode }
  noMatch: { title: string; text: string }
  /** A create button for the list head (omitted when the user cannot write). */
  headAction?: ReactNode
}

export function RegistryList<T>(props: RegistryListProps<T>) {
  const { labels: L } = props
  const bodyRef = useRef<HTMLTableSectionElement>(null)
  const retiredSwitch = (
    <Checkbox label={L.showRetired} checked={props.showRetired} onChange={props.onShowRetired} data-testid="registry-show-retired" />
  )

  function moveFocus(from: HTMLElement, to: 'next' | 'prev' | 'first' | 'last') {
    const rows = Array.from(bodyRef.current?.querySelectorAll<HTMLElement>('[data-nav]') ?? [])
    const i = rows.indexOf(from)
    const target = to === 'first' ? rows[0] : to === 'last' ? rows[rows.length - 1] : rows[i + (to === 'next' ? 1 : -1)]
    if (!target) return
    rows.forEach((r) => (r.tabIndex = -1))
    target.tabIndex = 0
    target.focus()
  }

  function onRowKey(e: KeyboardEvent<HTMLTableRowElement>, row: T) {
    const el = e.currentTarget
    if (e.key === 'ArrowDown') moveFocus(el, 'next')
    else if (e.key === 'ArrowUp') moveFocus(el, 'prev')
    else if (e.key === 'Home') moveFocus(el, 'first')
    else if (e.key === 'End') moveFocus(el, 'last')
    else if (e.key === 'Enter' || e.key === ' ') props.onOpen(row)
    else return
    e.preventDefault()
  }

  const firstFocus = !props.rows.some((r) => props.rowId(r) === props.selectedId)

  function body(): ReactNode {
    if (props.state === 'loading') {
      return (
        <div className="lf-reg__body" data-testid="registry-loading">
          <div className="lf-reg__skel" aria-busy="true">
            {Array.from({ length: 7 }, (_, i) => (
              <span className="lf-skel" key={i} />
            ))}
          </div>
        </div>
      )
    }
    if (props.state === 'error') {
      return (
        <div className="lf-reg__state" data-testid="registry-error">
          <Banner
            tone="danger"
            title={props.errorTitle}
            action={
              <Button variant="secondary" onClick={props.onRetry} data-testid="registry-retry">
                {L.retry}
              </Button>
            }
          >
            {props.errorText}
          </Banner>
        </div>
      )
    }
    if (props.rows.length === 0) {
      const t = props.filtered ? props.noMatch : props.empty
      return (
        <div className="lf-reg__body" data-testid={props.filtered ? 'registry-nomatch' : 'registry-empty'}>
          <EmptyState
            title={t.title}
            text={t.text}
            action={
              props.filtered ? (
                <Button variant="secondary" onClick={props.onClearFilters} data-testid="registry-clear-empty">
                  {L.clearFilters}
                </Button>
              ) : (
                props.empty.action
              )
            }
          />
        </div>
      )
    }
    return (
      <>
        <div className="lf-reg__body lf-table-wrap">
          <table className="lf-table lf-table--compact" role="grid" aria-label={props.title} aria-rowcount={props.rows.length}>
            <thead>
              <tr>
                {props.columns.map((c) => {
                  const on = props.sortKey === c.key
                  const sort = on ? (props.sortDir === 'asc' ? 'ascending' : 'descending') : 'none'
                  const Icon = on ? (props.sortDir === 'asc' ? ArrowUp : ArrowDown) : ChevronsUpDown
                  return (
                    <th key={c.key} scope="col" className={c.optional ? 'is-opt' : undefined} aria-sort={c.sortable ? sort : undefined}>
                      {c.sortable ? (
                        <button type="button" className="lf-sort" onClick={() => props.onSort(c.key)} data-testid={`registry-sort-${c.key}`}>
                          {c.header}
                          <Icon className="lf-icon" aria-hidden="true" />
                        </button>
                      ) : (
                        c.header
                      )}
                    </th>
                  )
                })}
              </tr>
            </thead>
            <tbody ref={bodyRef}>
              {props.rows.map((row, i) => {
                const id = props.rowId(row)
                const on = id === props.selectedId
                const cls = ['lf-reg__row', on ? 'is-selected' : '', props.isRetired?.(row) ? 'is-retired' : '']
                  .filter(Boolean)
                  .join(' ')
                return (
                  <tr
                    key={id}
                    className={cls}
                    role="row"
                    data-nav
                    data-testid="registry-row"
                    data-id={id}
                    aria-selected={on}
                    tabIndex={on || (firstFocus && i === 0) ? 0 : -1}
                    onClick={() => props.onOpen(row)}
                    onKeyDown={(e) => onRowKey(e, row)}
                  >
                    {props.columns.map((c) => (
                      <td key={c.key} role="gridcell" className={[c.mono ? 'mono' : '', c.optional ? 'is-opt' : ''].filter(Boolean).join(' ') || undefined}>
                        {c.render(row)}
                      </td>
                    ))}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        <div className="lf-table-foot lf-reg__foot">
          <span className="mono-s" data-testid="registry-range">
            {props.rangeText}
          </span>
          {props.pageCount > 1 && (
            <nav className="lf-pager" aria-label={L.pages}>
              <button
                type="button"
                className="lf-pager__page"
                aria-label={L.prev}
                disabled={props.page <= 1}
                onClick={() => props.onPage(props.page - 1)}
                data-testid="registry-prev"
              >
                <ChevronLeft className="lf-icon" aria-hidden="true" />
              </button>
              <button type="button" className="lf-pager__page" aria-current="page">
                {props.page}
              </button>
              <button
                type="button"
                className="lf-pager__page"
                aria-label={L.next}
                disabled={props.page >= props.pageCount}
                onClick={() => props.onPage(props.page + 1)}
                data-testid="registry-next"
              >
                <ChevronRight className="lf-icon" aria-hidden="true" />
              </button>
            </nav>
          )}
        </div>
      </>
    )
  }

  return (
    <section className="lf-card lf-reg__list" aria-labelledby={props.titleId} data-testid="registry-list">
      <div className="lf-reg__tools">
        <div className="lf-reg__listhead">
          <h2 className="lf-reg__sectitle" id={props.titleId}>
            {props.title}
          </h2>
          {props.headAction}
        </div>
        <div className="lf-reg__toolrow">
          <div className="lf-field">
            <label className="lf-label sr-only" htmlFor={`${props.titleId}-q`}>
              {L.search}
            </label>
            <div className="lf-control">
              <span className="lf-control__lead">
                <Search className="lf-icon" aria-hidden="true" />
              </span>
              <input
                id={`${props.titleId}-q`}
                autoComplete="off"
                placeholder={L.search}
                value={props.query}
                onChange={(e) => props.onQuery(e.target.value)}
                data-testid="registry-search"
              />
            </div>
          </div>
        </div>
        <div className="lf-reg__toolrow">
          {props.filters}
          {retiredSwitch}
        </div>
        {props.chips && props.chips.length > 0 && (
          <div className="lf-reg__chips">
            {props.chips.map((c) => (
              <span className="lf-chip" key={c.id}>
                {c.label}
                <button type="button" aria-label={`${L.removeFilter}: ${c.label}`} onClick={c.onRemove}>
                  <X className="lf-icon" aria-hidden="true" />
                </button>
              </span>
            ))}
            <Button variant="ghost" size="sm" onClick={props.onClearFilters} data-testid="registry-clear">
              {L.clearFilters}
            </Button>
          </div>
        )}
      </div>
      {body()}
    </section>
  )
}
