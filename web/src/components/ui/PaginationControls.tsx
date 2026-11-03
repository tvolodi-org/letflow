/** PaginationControls — design-system component (REQ-287, docs/frontend/design-system.md §7.8)
 *
 *  Pure derived-value component — it holds no state of its own. Supports
 *  known-total pagination ("Showing X-Y of Z") and cursor pagination where
 *  `totalItems` is `null` and the caller supplies `hasNextPage` instead
 *  (neither AuditLogPage nor InstanceBoardPage can provide a total row count).
 *  Markup is the table footer + pager of the design system (`.lf-table-foot`,
 *  `.lf-pager`); Previous/Next stay real labelled buttons.
 */

import React from 'react'
import { Button } from './Button'

export interface PaginationControlsProps {
  page: number // 1-indexed current page
  pageSize: number // one of 25, 50, 100
  totalItems: number | null // null when total is unknown (cursor-based pagination)
  onPageChange: (page: number) => void
  onPageSizeChange?: (pageSize: number) => void // omit to hide the size selector
  hasNextPage?: boolean // consulted only when totalItems is null
  labels?: { showing: string; of: string; previous: string; next: string; page: string; itemsPerPage: string; pages: string }
}

export const PAGE_SIZE_OPTIONS = [25, 50, 100] as const

const DEFAULT_LABELS = {
  showing: 'Showing',
  of: 'of',
  previous: 'Previous',
  next: 'Next',
  page: 'page',
  itemsPerPage: 'Items per page',
  pages: 'Pages',
}

export function PaginationControls(props: PaginationControlsProps): React.ReactElement {
  const { page, pageSize, totalItems, onPageChange, onPageSizeChange, hasNextPage } = props
  const labels = props.labels ?? DEFAULT_LABELS

  const start = (page - 1) * pageSize + 1
  const end = totalItems === null ? page * pageSize : Math.min(page * pageSize, totalItems)

  const isPrevDisabled = page <= 1
  const isNextDisabled = totalItems === null ? hasNextPage !== true : page * pageSize >= totalItems
  const showSizeSelector = onPageSizeChange !== undefined

  return (
    <div className="lf-table-foot" data-testid="pagination-controls">
      <span data-testid="pagination-summary">
        {labels.showing}{' '}
        <span className="mono">
          {start}-{end}
        </span>
        {totalItems !== null && (
          <>
            {' '}
            {labels.of} <span className="mono">{totalItems}</span>
          </>
        )}
      </span>
      <nav className="lf-pager" aria-label={labels.pages}>
        {showSizeSelector && (
          <span className="lf-control">
            <select
              data-testid="pagination-size-select"
              aria-label={labels.itemsPerPage}
              value={pageSize}
              onChange={(event) => onPageSizeChange?.(Number(event.target.value))}
            >
              {PAGE_SIZE_OPTIONS.map((size) => (
                <option key={size} value={size}>
                  {size} / {labels.page}
                </option>
              ))}
            </select>
          </span>
        )}
        <span data-testid="pagination-prev">
          <Button variant="secondary" size="sm" disabled={isPrevDisabled} onClick={() => onPageChange(page - 1)}>
            {labels.previous}
          </Button>
        </span>
        <span data-testid="pagination-next">
          <Button variant="secondary" size="sm" disabled={isNextDisabled} onClick={() => onPageChange(page + 1)}>
            {labels.next}
          </Button>
        </span>
      </nav>
    </div>
  )
}
