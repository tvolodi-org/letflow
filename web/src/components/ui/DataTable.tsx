/** DataTable — design-system component (REQ-274, NOTES.md §2, README "Tables")
 *
 *  Sort state lives inside the component (asc/desc toggle) and is handed to
 *  `@tanstack/react-table` (headless: row/column/sort models only); all markup
 *  is ours and styled by `.lf-table*` from `components.css`.
 *
 *  Columns take either the original shape (`id`, `header`, `accessor`) or the
 *  design-system shape (`key`, `label`, `render`); both may be mixed, so existing
 *  callers keep working. A row's id comes from `getRowId`, else `row.id`.
 *  States: loading (skeleton rows), empty, load error with retry, per-row
 *  `error`/`retired` (`rowState`), selected (`selectedId`), compact density.
 *  Every cell has `data-label` so the table stacks into cards on phones. The sticky header is
 *  `.lf-table th` in components.css (an inline style on <thead> would keep it visible in the card layout).
 */

import React, { useMemo, useState } from 'react'
import {
  useReactTable,
  getCoreRowModel,
  getSortedRowModel,
  type ColumnDef,
  type SortingState,
} from '@tanstack/react-table'
import { ArrowDown, ArrowUp, ArrowUpDown, AlertTriangle } from 'lucide-react'
import { Button } from './Button'
import { EmptyState } from './EmptyState'
import { Skeleton } from './Skeleton'
import { deferClickState } from '@/utils/deferClickState'

export interface DataTableColumn<TRow> {
  id?: string
  key?: string
  header?: string
  label?: string
  accessor?: (row: TRow) => React.ReactNode
  render?: (row: TRow) => React.ReactNode
  sortable?: boolean
  sortValue?: (row: TRow) => string | number
  align?: 'start' | 'end'
  /** Mono type, never wrapped (codes, ids, dates). */
  mono?: boolean
  /** Label shown on the phone card; defaults to the header. */
  stackLabel?: string
  /** Phone card: no label row (the cell already says it, e.g. a StatusPill). */
  hideStackLabel?: boolean
}

export type DataTableRowState = 'error' | 'retired'

export interface DataTableProps<TRow> {
  columns: DataTableColumn<TRow>[]
  data: TRow[]
  isLoading?: boolean
  emptyMessage: string
  /** Optional second line and action for the empty state. */
  emptyText?: React.ReactNode
  emptyAction?: React.ReactNode
  onRowClick?: (row: TRow) => void
  selectedId?: string | null
  getRowId?: (row: TRow) => string
  rowState?: (row: TRow) => DataTableRowState | undefined
  density?: 'default' | 'compact'
  /** Load error message; shows a banner with a retry button instead of rows. */
  error?: React.ReactNode
  onRetry?: () => void
  skeletonRows?: number
  labels?: { loading: string; retry: string }
}

interface Resolved<TRow> {
  id: string
  header: string
  cell: (row: TRow) => React.ReactNode
  col: DataTableColumn<TRow>
}

interface SortState {
  columnId: string | null
  direction: 'asc' | 'desc'
}

const DEFAULT_LABELS = { loading: 'Loading content', retry: 'Try again' }

function resolveColumns<TRow>(columns: DataTableColumn<TRow>[]): Resolved<TRow>[] {
  return columns.map((col, index) => ({
    id: col.id ?? col.key ?? String(index),
    header: col.header ?? col.label ?? '',
    cell: col.render ?? col.accessor ?? (() => null),
    col,
  }))
}

function cellClass<TRow>(col: DataTableColumn<TRow>): string | undefined {
  const parts = [col.align === 'end' ? 'is-end' : '', col.mono ? 'mono' : '', col.hideStackLabel ? 'is-check' : ''].filter(Boolean)
  return parts.length > 0 ? parts.join(' ') : undefined
}

export function DataTable<TRow>(props: DataTableProps<TRow>): React.ReactElement {
  const {
    columns,
    data,
    isLoading = false,
    emptyMessage,
    onRowClick,
    selectedId = null,
    rowState,
    density = 'default',
    error,
    onRetry,
    skeletonRows = 5,
  } = props
  const labels = props.labels ?? DEFAULT_LABELS

  const [sortState, setSortState] = useState<SortState>({ columnId: null, direction: 'asc' })

  const resolved = useMemo(() => resolveColumns(columns), [columns])

  const columnDefs = useMemo<ColumnDef<TRow>[]>(
    () =>
      resolved.map(({ id, header, cell, col }) => ({
        id,
        header,
        accessorFn: (row: TRow) => (col.sortValue ? col.sortValue(row) : cell(row)),
        enableSorting: !!col.sortable,
      })),
    [resolved],
  )

  // Stable between renders: a fresh array each render makes the sorted row model recompute, whose
  // change hook resets the page index and re-renders the table without end once `data` has changed.
  const sorting = useMemo<SortingState>(
    () => (sortState.columnId ? [{ id: sortState.columnId, desc: sortState.direction === 'desc' }] : []),
    [sortState.columnId, sortState.direction],
  )

  const table = useReactTable({
    data,
    columns: columnDefs,
    state: { sorting },
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    // No pagination here. Without this, every render's fresh `sorting` array makes the sorted row model
    // report a change, tanstack queues a page-index reset, that sets state, and the table re-renders for ever
    // as soon as it has rows (a page froze after any reload of its rows).
    autoResetPageIndex: false,
  })

  // `table` is a stable ref (mutated in place), so memoizing on it would never
  // recompute after a sort change — read the (internally memoized) row model.
  const sortedRows = table.getSortedRowModel().rows

  function rowId(row: TRow): string | null {
    if (props.getRowId) return props.getRowId(row)
    const id = (row as { id?: unknown } | null)?.id
    return typeof id === 'string' || typeof id === 'number' ? String(id) : null
  }

  function handleHeaderClick(col: DataTableColumn<TRow>, id: string): void {
    if (!col.sortable) return
    // ISS-0662: deferred by one macrotask — see web/src/utils/deferClickState.ts.
    deferClickState(() => {
      setSortState((prev) =>
        prev.columnId !== id
          ? { columnId: id, direction: 'asc' }
          : { columnId: id, direction: prev.direction === 'asc' ? 'desc' : 'asc' },
      )
    })
  }

  const hasError = error !== undefined && error !== null && error !== false
  const isEmpty = !isLoading && !hasError && data.length === 0
  const colSpan = Math.max(resolved.length, 1)

  return (
    <div className="lf-table-wrap" data-testid="data-table">
      <div data-testid="datatable-scroll-container">
        <table className={`lf-table lf-table--stack${density === 'compact' ? ' lf-table--compact' : ''}`}>
          <thead data-testid="datatable-header">
            <tr>
              {resolved.map(({ id, header, col }) => {
                const isActive = sortState.columnId === id
                const ariaSort = col.sortable
                  ? isActive
                    ? sortState.direction === 'asc'
                      ? 'ascending'
                      : 'descending'
                    : 'none'
                  : undefined
                const SortIcon = isActive ? (sortState.direction === 'asc' ? ArrowUp : ArrowDown) : ArrowUpDown
                return (
                  <th
                    key={id}
                    data-testid={`datatable-header-${id}`}
                    aria-sort={ariaSort}
                    className={col.align === 'end' ? 'is-end' : undefined}
                    onClick={() => handleHeaderClick(col, id)}
                  >
                    {col.sortable ? (
                      <button type="button" className="lf-sort">
                        {header}
                        <span data-testid={isActive ? `datatable-sort-indicator-${id}` : undefined} className="lf-sort__icon">
                          <SortIcon className="lf-icon" aria-hidden="true" />
                        </span>
                      </button>
                    ) : (
                      header
                    )}
                  </th>
                )
              })}
            </tr>
          </thead>
          <tbody data-testid="datatable-body" aria-busy={isLoading || undefined} aria-label={isLoading ? labels.loading : undefined}>
            {isLoading ? (
              Array.from({ length: skeletonRows }).map((_, rowIdx) => (
                <tr key={rowIdx} data-testid="datatable-skeleton-row">
                  {resolved.map(({ id, header, col }, colIdx) => (
                    <td key={id} data-label={col.stackLabel ?? header}>
                      <Skeleton width={`${60 + ((rowIdx + colIdx) % 3) * 15}%`} />
                    </td>
                  ))}
                </tr>
              ))
            ) : hasError ? (
              <tr>
                <td colSpan={colSpan} data-testid="datatable-error">
                  <div className="lf-banner lf-banner--danger" role="alert">
                    <AlertTriangle className="lf-icon" aria-hidden="true" />
                    <div>{error}</div>
                    {onRetry && (
                      <Button variant="secondary" size="sm" onClick={onRetry} data-testid="datatable-retry">
                        {labels.retry}
                      </Button>
                    )}
                  </div>
                </td>
              </tr>
            ) : isEmpty ? (
              <tr>
                <td colSpan={colSpan}>
                  <EmptyState
                    data-testid="datatable-empty-state"
                    title={emptyMessage}
                    text={props.emptyText}
                    action={props.emptyAction}
                  />
                </td>
              </tr>
            ) : (
              sortedRows.map((row) => {
                const rawRow = row.original
                const id = rowId(rawRow)
                const state = rowState?.(rawRow)
                const classes = [
                  id !== null && id === selectedId ? 'is-selected' : '',
                  state === 'error' ? 'is-error' : '',
                  state === 'retired' ? 'is-retired' : '',
                ]
                  .filter(Boolean)
                  .join(' ')
                return (
                  <tr
                    key={row.id}
                    data-testid="datatable-row"
                    className={classes || undefined}
                    aria-current={id !== null && id === selectedId ? 'true' : undefined}
                    tabIndex={onRowClick ? 0 : undefined}
                    onClick={onRowClick ? () => onRowClick(rawRow) : undefined}
                    onKeyDown={
                      onRowClick
                        ? (event) => {
                            if (event.target !== event.currentTarget) return
                            if (event.key === 'Enter' || event.key === ' ') {
                              event.preventDefault()
                              onRowClick(rawRow)
                            }
                          }
                        : undefined
                    }
                  >
                    {resolved.map(({ id: colId, header, cell, col }, colIdx) => (
                      <td
                        key={colId}
                        data-testid={`datatable-cell-${colId}`}
                        data-label={col.stackLabel ?? header}
                        className={[cellClass(col), colIdx === 0 ? 'is-primary' : ''].filter(Boolean).join(' ') || undefined}
                      >
                        {cell(rawRow)}
                      </td>
                    ))}
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
