// @vitest-environment jsdom
/** T-1166 — DataTable: design-system columns and states (the REQ-274 cases stay in DataTable.test.tsx). */
import { useState } from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, within, act } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { DataTable, type DataTableColumn } from '../DataTable'

afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

interface Row {
  id: string
  code: string
  name: string
  qty: number
}
const ROWS: Row[] = [
  { id: 'a', code: 'C-2', name: 'Beta', qty: 5 },
  { id: 'b', code: 'C-1', name: 'Alpha', qty: 9 },
  { id: 'c', code: 'C-3', name: 'Gamma', qty: 1 },
]
const COLS: DataTableColumn<Row>[] = [
  { key: 'code', label: 'Code', mono: true, sortable: true, render: (r) => r.code },
  { key: 'name', label: 'Name', stackLabel: 'Item name', render: (r) => r.name },
  { key: 'qty', label: 'Qty', align: 'end', mono: true, sortable: true, render: (r) => r.qty },
]

describe('T-1166 — DataTable', () => {
  it('TC-T1166-20: key/label/render columns render; mono/align classes and data-label (stackLabel) are set', () => {
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" />)
    expect(screen.getByTestId('datatable-header-code')).toHaveTextContent('Code')
    const first = screen.getAllByTestId('datatable-row')[0]
    expect(within(first).getByTestId('datatable-cell-code')).toHaveClass('mono')
    expect(within(first).getByTestId('datatable-cell-qty')).toHaveClass('is-end', 'mono')
    expect(within(first).getByTestId('datatable-cell-name')).toHaveAttribute('data-label', 'Item name')
    expect(within(first).getByTestId('datatable-cell-code')).toHaveAttribute('data-label', 'Code')
    expect(screen.getByTestId('datatable-header-qty')).toHaveClass('is-end')
  })

  it('TC-T1174-30: hideStackLabel marks the cell so the phone card shows no label row', () => {
    const cols: DataTableColumn<Row>[] = [...COLS, { key: 'st', label: 'Status', hideStackLabel: true, render: () => 'ok' }]
    render(<DataTable columns={cols} data={ROWS} emptyMessage="none" />)
    const first = screen.getAllByTestId('datatable-row')[0]
    expect(within(first).getByTestId('datatable-cell-st')).toHaveClass('is-check')
    expect(within(first).getByTestId('datatable-cell-name')).not.toHaveClass('is-check')
  })

  it('TC-T1166-21: sortable header is a button with aria-sort none -> ascending -> descending', () => {
    vi.useFakeTimers()
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" />)
    const th = screen.getByTestId('datatable-header-code')
    expect(th).toHaveAttribute('aria-sort', 'none')
    expect(within(th).getByRole('button', { name: 'Code' })).toBeInTheDocument()
    expect(screen.getByTestId('datatable-header-name')).not.toHaveAttribute('aria-sort')

    fireEvent.click(within(th).getByRole('button'))
    act(() => void vi.runAllTimers())
    expect(th).toHaveAttribute('aria-sort', 'ascending')
    expect(within(screen.getAllByTestId('datatable-row')[0]).getByTestId('datatable-cell-code')).toHaveTextContent('C-1')

    fireEvent.click(within(th).getByRole('button'))
    act(() => void vi.runAllTimers())
    expect(th).toHaveAttribute('aria-sort', 'descending')
    expect(within(screen.getAllByTestId('datatable-row')[0]).getByTestId('datatable-cell-code')).toHaveTextContent('C-3')
  })

  it('TC-T1166-22: selectedId marks the row selected; rowState adds error and retired classes', () => {
    render(
      <DataTable
        columns={COLS}
        data={ROWS}
        emptyMessage="none"
        selectedId="b"
        rowState={(r) => (r.id === 'a' ? 'error' : r.id === 'c' ? 'retired' : undefined)}
      />,
    )
    const rows = screen.getAllByTestId('datatable-row')
    expect(rows[0]).toHaveClass('is-error')
    expect(rows[1]).toHaveClass('is-selected')
    expect(rows[1]).toHaveAttribute('aria-current', 'true')
    expect(rows[2]).toHaveClass('is-retired')
    expect(rows[0]).not.toHaveClass('is-selected')
  })

  it('TC-T1166-23: getRowId overrides row.id for selection', () => {
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" selectedId="C-3" getRowId={(r) => r.code} />)
    expect(screen.getAllByTestId('datatable-row')[2]).toHaveClass('is-selected')
  })

  it('TC-T1166-24: density compact adds the compact class', () => {
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" density="compact" />)
    expect(screen.getByRole('table')).toHaveClass('lf-table--compact', 'lf-table--stack')
  })

  it('TC-T1166-25: a clickable row opens with Enter and Space, not from a nested control', () => {
    const onRowClick = vi.fn()
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" onRowClick={onRowClick} />)
    const row = screen.getAllByTestId('datatable-row')[1]
    expect(row).toHaveAttribute('tabindex', '0')
    fireEvent.keyDown(row, { key: 'Enter' })
    fireEvent.keyDown(row, { key: ' ' })
    expect(onRowClick).toHaveBeenCalledTimes(2)
    expect(onRowClick).toHaveBeenLastCalledWith(ROWS[1])
    fireEvent.keyDown(within(row).getByTestId('datatable-cell-code'), { key: 'Enter' })
    expect(onRowClick).toHaveBeenCalledTimes(2)
  })

  it('TC-T1166-26: loading shows skeleton rows, marks the body busy, and no data rows', () => {
    render(<DataTable columns={COLS} data={ROWS} isLoading emptyMessage="none" skeletonRows={4} />)
    expect(screen.getAllByTestId('datatable-skeleton-row')).toHaveLength(4)
    expect(screen.getAllByTestId('skeleton')).toHaveLength(12)
    expect(screen.getByTestId('datatable-body')).toHaveAttribute('aria-busy', 'true')
    expect(screen.queryAllByTestId('datatable-row')).toHaveLength(0)
  })

  it('TC-T1166-27: empty shows title, text and action', () => {
    render(
      <DataTable
        columns={COLS}
        data={[]}
        emptyMessage="No items"
        emptyText="Create the first one."
        emptyAction={<button type="button">Create</button>}
      />,
    )
    const empty = screen.getByTestId('datatable-empty-state')
    expect(empty).toHaveTextContent('No items')
    expect(empty).toHaveTextContent('Create the first one.')
    expect(within(empty).getByRole('button', { name: 'Create' })).toBeInTheDocument()
  })

  it('TC-T1166-28: load error shows the banner with a working retry and hides rows', () => {
    const onRetry = vi.fn()
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" error="The list could not be loaded." onRetry={onRetry} />)
    expect(screen.getByRole('alert')).toHaveTextContent('The list could not be loaded.')
    expect(screen.queryAllByTestId('datatable-row')).toHaveLength(0)
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('TC-T1166-29: error without onRetry has no retry button', () => {
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" error="boom" />)
    expect(screen.queryByTestId('datatable-retry')).toBeNull()
  })

  it('TC-T1166-30: the file touches no inline colour or spacing (the sticky header is CSS)', () => {
    render(<DataTable columns={COLS} data={ROWS} emptyMessage="none" onRowClick={() => {}} selectedId="a" />)
    const styled = Array.from(document.querySelectorAll('[style]')).map((el) => el.getAttribute('style'))
    expect(styled).toEqual([])
  })

  it('TC-T1172-31: a table with rows settles when the page around it changes (no page-reset render loop)', async () => {
    let calls = 0
    const cols: DataTableColumn<Row>[] = [
      {
        key: 'code',
        label: 'Code',
        render: (r) => {
          calls += 1
          if (calls > 200) throw new Error('DataTable re-renders without end')
          return r.code
        },
      },
    ]
    function Host() {
      const [n, setN] = useState(0)
      return (
        <>
          <button onClick={() => setN(n + 1)}>bump {n}</button>
          <DataTable columns={cols} data={ROWS} emptyMessage="none" />
        </>
      )
    }
    render(<Host />)
    // a state change of the page around the table, outside the click turn (a write that finished)
    await act(async () => {
      await Promise.resolve()
      fireEvent.click(screen.getByRole('button', { name: /bump/ }))
      for (let i = 0; i < 20; i += 1) await Promise.resolve()
    })
    expect(calls).toBeLessThan(40)
    expect(screen.getByText('C-2')).toBeInTheDocument()
  })
})
