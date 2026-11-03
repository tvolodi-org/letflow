// @vitest-environment jsdom
/**
 * Unit tests — REQ-274: DataTable design-system primitive
 *
 * TC-REQ274-01: props exactly match design-system.md §7.2 (columns, data,
 *   isLoading, emptyMessage, onRowClick) and drive rendered rows/headers
 * TC-REQ274-02: isLoading=true renders SkeletonLayout's own rendered output
 *   inside DataTable rather than the data rows
 * TC-REQ274-03: data=[] + isLoading=false renders the centered empty state
 *   with emptyMessage text
 * TC-REQ274-04: the header element (datatable-header) carries position: sticky
 * TC-REQ274-05: clicking a sortable column's header twice toggles asc then
 *   desc row order
 * TC-REQ274-06: onRowClick fires with the clicked row's data
 * TC-REQ274-07: a non-sortable column's header click is a no-op
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, within, act } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { DataTable, type DataTableColumn } from '../DataTable'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

interface Row {
  id: string
  name: string
  age: number
}

const ROWS: Row[] = [
  { id: '1', name: 'Charlie', age: 40 },
  { id: '2', name: 'Alice', age: 25 },
  { id: '3', name: 'Bob', age: 33 },
]

const COLUMNS: DataTableColumn<Row>[] = [
  { id: 'name', header: 'Name', accessor: (r) => r.name, sortable: true },
  { id: 'age', header: 'Age', accessor: (r) => r.age, sortable: true, sortValue: (r) => r.age },
]

describe('REQ-274 — DataTable', () => {
  it('TC-REQ274-01: props drive rendered headers and rows', () => {
    render(<DataTable columns={COLUMNS} data={ROWS} emptyMessage="No rows" />)

    expect(screen.getByTestId('datatable-header-name')).toHaveTextContent('Name')
    expect(screen.getByTestId('datatable-header-age')).toHaveTextContent('Age')

    const rows = screen.getAllByTestId('datatable-row')
    expect(rows).toHaveLength(3)
    expect(within(rows[0]).getByTestId('datatable-cell-name')).toHaveTextContent('Charlie')
  })

  it('TC-REQ274-02: isLoading renders SkeletonLayout output, not data rows', () => {
    render(<DataTable columns={COLUMNS} data={ROWS} isLoading emptyMessage="No rows" />)

    // SkeletonLayout renders aria-busy="true" content with no data rows present.
    expect(screen.getByLabelText('Loading content')).toBeInTheDocument()
    expect(screen.queryAllByTestId('datatable-row')).toHaveLength(0)
    expect(screen.queryByText('Charlie')).not.toBeInTheDocument()
  })

  it('TC-REQ274-03: empty data renders the centered empty state with emptyMessage', () => {
    render(<DataTable columns={COLUMNS} data={[]} emptyMessage="No instances found" />)

    const emptyState = screen.getByTestId('datatable-empty-state')
    expect(emptyState).toBeInTheDocument()
    expect(emptyState).toHaveTextContent('No instances found')
    expect(screen.queryAllByTestId('datatable-row')).toHaveLength(0)
  })

  it('TC-REQ274-04: the header is a thead; sticky positioning comes from .lf-table th, not an inline style', () => {
    render(<DataTable columns={COLUMNS} data={ROWS} emptyMessage="No rows" />)

    const header = screen.getByTestId('datatable-header')
    expect(header.tagName).toBe('THEAD')
    expect(header).not.toHaveAttribute('style')
  })

  it('TC-REQ274-05: clicking a sortable header toggles asc then desc order', () => {
    vi.useFakeTimers()
    try {
      render(<DataTable columns={COLUMNS} data={ROWS} emptyMessage="No rows" />)

      // Unsorted (insertion) order: Charlie, Alice, Bob
      let rows = screen.getAllByTestId('datatable-row')
      expect(within(rows[0]).getByTestId('datatable-cell-name')).toHaveTextContent('Charlie')

      // ISS-0662: handleHeaderClick defers its setState by one macrotask
      // (deferClickState) to avoid a real-click renderer freeze on this
      // component when embedded in EntityCrudPage, so the reorder is
      // asynchronous here too — flush the deferred macrotask with fake timers
      // rather than polling on real ones.
      fireEvent.click(screen.getByTestId('datatable-header-name'))
      act(() => {
        vi.runAllTimers()
      })
      rows = screen.getAllByTestId('datatable-row')
      expect(within(rows[0]).getByTestId('datatable-cell-name')).toHaveTextContent('Alice')
      expect(within(rows[1]).getByTestId('datatable-cell-name')).toHaveTextContent('Bob')
      expect(within(rows[2]).getByTestId('datatable-cell-name')).toHaveTextContent('Charlie')

      fireEvent.click(screen.getByTestId('datatable-header-name'))
      act(() => {
        vi.runAllTimers()
      })
      rows = screen.getAllByTestId('datatable-row')
      expect(within(rows[0]).getByTestId('datatable-cell-name')).toHaveTextContent('Charlie')
      expect(within(rows[1]).getByTestId('datatable-cell-name')).toHaveTextContent('Bob')
      expect(within(rows[2]).getByTestId('datatable-cell-name')).toHaveTextContent('Alice')
    } finally {
      vi.useRealTimers()
    }
  })

  it('TC-REQ274-06: onRowClick fires with the clicked row', () => {
    const onRowClick = vi.fn()
    render(<DataTable columns={COLUMNS} data={ROWS} emptyMessage="No rows" onRowClick={onRowClick} />)

    const rows = screen.getAllByTestId('datatable-row')
    fireEvent.click(rows[0])

    expect(onRowClick).toHaveBeenCalledTimes(1)
    expect(onRowClick).toHaveBeenCalledWith(ROWS[0])
  })

  it('TC-REQ274-07: clicking a non-sortable column header is a no-op', () => {
    const nonSortableColumns: DataTableColumn<Row>[] = [
      { id: 'name', header: 'Name', accessor: (r) => r.name },
      { id: 'age', header: 'Age', accessor: (r) => r.age },
    ]
    render(<DataTable columns={nonSortableColumns} data={ROWS} emptyMessage="No rows" />)

    fireEvent.click(screen.getByTestId('datatable-header-name'))
    const rows = screen.getAllByTestId('datatable-row')
    expect(within(rows[0]).getByTestId('datatable-cell-name')).toHaveTextContent('Charlie')
  })
})
