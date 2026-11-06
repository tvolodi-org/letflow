// @vitest-environment jsdom
/** T-1448 U4-U6, U8-U12: LFLinesEditor with a plain line type (the component knows no module words). */
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { LFLinesEditor } from '../LFLinesEditor'
import type { LeCatalog, LeColumn, LeItem, LeMode, LFLinesEditorProps, LeError } from '../types'
import { ItemPicker } from '../ItemPicker'

expect.extend(jestDomMatchers)
afterEach(() => cleanup())

interface Ln { item: string; qty: string; ref: string }
const ITEMS: LeItem[] = [
  { id: 'i1', code: 'BOLT', title: 'Bolt M8', lotTracked: true, barcode: '4600' },
  { id: 'i2', code: 'NUT', title: 'Nut M8', lotTracked: false },
]
const catalog: LeCatalog = {
  byId: (id) => ITEMS.find((i) => i.id === id) ?? null,
  resolve: (t) => ITEMS.find((i) => [i.code, i.barcode, i.title].some((x) => x?.toLowerCase() === t.trim().toLowerCase())) ?? null,
  suggest: (t) => ITEMS.filter((i) => `${i.code} ${i.title}`.toLowerCase().includes(t.trim().toLowerCase())),
}
const blank = (): Ln => ({ item: '', qty: '', ref: '' })
const mk = (n: number): Ln[] => Array.from({ length: n }, (_, i) => ({ item: i % 2 ? 'i2' : 'i1', qty: String(i + 1), ref: `r${i}` }))
const columns: LeColumn<Ln>[] = [
  {
    key: 'item', label: 'Item', view: (l) => catalog.byId(l.item)?.title ?? '—',
    cell: (c) => <ItemPicker id={c.id} value={c.line.item} catalog={catalog} label="Item" invalid={c.invalid} onBlur={c.onBlur} onPick={(it) => c.patch({ item: it?.id ?? '' })} />,
    paste: (l, text) => {
      const it = catalog.resolve(text)
      return it ? { line: { ...l, item: it.id } } : { line: l, reason: `unknown ${text}` }
    },
  },
  {
    key: 'lot', label: 'Lot', view: () => '—', skip: (l) => catalog.byId(l.item)?.lotTracked === false,
    cell: (c) => <input id={c.id} aria-label="Lot" value={c.line.ref} onChange={(e) => c.patch({ ref: e.target.value })} onBlur={c.onBlur} />,
  },
  {
    key: 'qty', label: 'Quantity', num: true, view: (l) => l.qty,
    cell: (c) => <input id={c.id} aria-label="Quantity" value={c.line.qty} aria-invalid={c.invalid || undefined} onChange={(e) => c.patch({ qty: e.target.value })} onBlur={c.onBlur} />,
    paste: (l, t) => ({ line: { ...l, qty: t.replace(',', '.') } }),
  },
]
const validateLine = (l: Ln): LeError[] => (/^\d+(\.\d+)?$/.test(l.qty) && Number(l.qty) > 0 ? [] : [{ col: 'qty', message: 'Quantity must be above zero' }]).concat(l.item ? [] : [{ col: 'item', message: 'Choose an item' }])

function Host(p: Partial<LFLinesEditorProps<Ln>> & { initial?: Ln[]; start?: LeMode; onLines?: (l: Ln[]) => void }) {
  const [lines, setLines] = useState<Ln[]>(p.initial ?? [blank()])
  const [mode, setMode] = useState<LeMode>(p.start ?? 'grid')
  return (
    <div style={{ height: 600 }}>
      <LFLinesEditor<Ln>
        screenId="t"
        lines={lines}
        onChange={(l) => { setLines(l); p.onLines?.(l) }}
        columns={columns}
        blank={blank}
        duplicate={(l) => ({ ...l, ref: '' })}
        isBlank={(l) => l.item === '' && l.qty === '' && l.ref === ''}
        max={5}
        mode={mode}
        onModeChange={setMode}
        searchText={(l) => `${catalog.byId(l.item)?.title ?? ''} ${l.qty}`}
        validateLine={validateLine}
        scan={(code, ls) => {
          const it = catalog.resolve(code)
          if (!it) return { status: 'unknown', lines: ls }
          const at = ls.findIndex((l) => l.item === it.id)
          if (at >= 0) return { status: 'inc', lines: ls.map((l, i) => (i === at ? { ...l, qty: String(Number(l.qty || 0) + 1) } : l)), index: at, qty: String(Number(ls[at]!.qty || 0) + 1) }
          return { status: 'new', lines: [...ls, { item: it.id, qty: '1', ref: '' }], index: ls.length, qty: '1' }
        }}
        {...p}
      />
    </div>
  )
}
const rows = () => screen.queryAllByTestId('line-editor-row')
const rowOf = (i: number) => rows()[i]!

describe('U4 scan', () => {
  it('a new item adds a line with quantity 1, the same item increments the first match, the field is cleared', () => {
    render(<Host initial={mk(2)} />)
    const scan = screen.getByLabelText('Scan field')
    fireEvent.change(scan, { target: { value: 'NUT' } })
    fireEvent.keyDown(scan, { key: 'Enter' })
    expect(within(rowOf(1)).getByLabelText('Quantity')).toHaveValue('3') // line 2 was NUT with 2
    expect(scan).toHaveValue('')
    fireEvent.change(scan, { target: { value: '4600' } }) // BOLT by barcode: increments line 1
    fireEvent.keyDown(scan, { key: 'Enter' })
    expect(within(rowOf(0)).getByLabelText('Quantity')).toHaveValue('2')
    expect(rows()).toHaveLength(2)
  })
  it('an unknown code says so and adds nothing; a new item on an empty document replaces the blank line', () => {
    render(<Host />)
    const scan = screen.getByLabelText('Scan field')
    fireEvent.change(scan, { target: { value: 'ZZZ' } })
    fireEvent.keyDown(scan, { key: 'Enter' })
    expect(screen.getAllByText('Code ZZZ was not found').length).toBeGreaterThan(0)
    fireEvent.change(scan, { target: { value: 'BOLT' } })
    fireEvent.keyDown(scan, { key: 'Enter' })
    expect(rows()).toHaveLength(1)
    expect(within(rowOf(0)).getByLabelText('Quantity')).toHaveValue('1')
  })
  it('at the maximum a new item is refused', () => {
    render(<Host initial={mk(5).map((l, i) => ({ ...l, item: 'i1', qty: String(i + 1) }))} />)
    const scan = screen.getByLabelText('Scan field')
    fireEvent.change(scan, { target: { value: 'NUT' } })
    fireEvent.keyDown(scan, { key: 'Enter' })
    expect(screen.getAllByText('Not added: the maximum of 5 lines is reached').length).toBeGreaterThan(0)
    expect(rows()).toHaveLength(5)
  })
})

describe('U5 duplicate and delete', () => {
  it('Ctrl+D duplicates below without the reference, the button does the same', () => {
    render(<Host initial={mk(2)} />)
    fireEvent.keyDown(within(rowOf(0)).getByLabelText('Quantity'), { key: 'd', ctrlKey: true })
    expect(rows()).toHaveLength(3)
    expect(within(rowOf(1)).getByLabelText('Quantity')).toHaveValue('1')
    expect(within(rowOf(1)).getByLabelText('Lot')).toHaveValue('')
    fireEvent.click(within(rowOf(0)).getByRole('button', { name: 'Duplicate line 1' }))
    expect(rows()).toHaveLength(4)
  })
  it('Ctrl+Delete and the button delete the line and focus the neighbour; the last line leaves one blank line', async () => {
    render(<Host initial={mk(3)} />)
    fireEvent.keyDown(within(rowOf(1)).getByLabelText('Quantity'), { key: 'Delete', ctrlKey: true })
    expect(rows()).toHaveLength(2)
    await waitFor(() => expect(within(rowOf(1)).getByLabelText('Item')).toHaveFocus())
    fireEvent.click(within(rowOf(0)).getByRole('button', { name: 'Delete line 1' }))
    fireEvent.click(within(rowOf(0)).getByRole('button', { name: 'Delete line 1' }))
    expect(screen.getByTestId('lines-empty')).toBeInTheDocument()
  })
})

describe('U6 mode and phone', () => {
  it('the toggle switches between the table and the form and reports the choice', () => {
    const onMode = vi.fn()
    render(<Host initial={mk(2)} onModeChange={onMode} />)
    expect(screen.getByTestId('mode-grid')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('lines-editor')).toHaveAttribute('data-mode', 'grid')
  })
  it('under 700 px the grid is disabled with a reason and the form is used; the stored mode is kept', () => {
    const spy = vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({ width: 390, height: 600, top: 0, left: 0, right: 390, bottom: 600, x: 0, y: 0, toJSON: () => ({}) })
    const onMode = vi.fn()
    render(<Host initial={mk(2)} start="grid" onModeChange={onMode} />)
    const grid = screen.getByTestId('mode-grid')
    expect(grid).toBeDisabled()
    expect(grid).toHaveAttribute('title', 'The grid needs a wider screen')
    expect(screen.getByTestId('lines-editor')).toHaveAttribute('data-mode', 'form')
    expect(onMode).not.toHaveBeenCalled()
    spy.mockRestore()
  })
})

describe('U8 line by line', () => {
  it('Save and add next stores the line and opens an empty form; Save and close closes it; a saved line loads back', async () => {
    const seen: Ln[][] = []
    render(<Host start="form" onLines={(l) => seen.push(l)} />)
    fireEvent.click(screen.getByRole('button', { name: 'Add line' }))
    const item = screen.getByLabelText('Item')
    fireEvent.change(item, { target: { value: 'Bolt M8' } })
    fireEvent.blur(item)
    fireEvent.change(screen.getByLabelText('Quantity'), { target: { value: '3' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save and add next' }))
    expect(seen.at(-1)).toEqual([{ item: 'i1', qty: '3', ref: '' }])
    expect(screen.getByText('New line 2')).toBeInTheDocument()
    expect(screen.getByLabelText('Quantity')).toHaveValue('')
    // an invalid line is refused with the field named
    fireEvent.click(screen.getByRole('button', { name: 'Save and close' }))
    expect(screen.getAllByText('Quantity must be above zero').length).toBeGreaterThan(0)
    expect(seen.at(-1)).toHaveLength(1)
    fireEvent.keyDown(screen.getByLabelText('Quantity'), { key: 'Escape' })
    expect(screen.queryByText('New line 2')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Editing line 1' }))
    expect(screen.getByLabelText('Quantity')).toHaveValue('3')
    fireEvent.click(screen.getByRole('button', { name: 'Delete line' }))
    expect(seen.at(-1)).toEqual([blank()])
  })
})

describe('U9 maximum', () => {
  it('shows the banner and the counter, refuses add, paste, Enter in the last cell', () => {
    render(<Host initial={mk(5)} />)
    expect(screen.getByTestId('lines-max')).toHaveTextContent('Maximum of 5 lines reached')
    expect(screen.getByText('5 of 5 lines')).toHaveClass('is-max')
    expect(screen.getByRole('button', { name: 'Add line' })).toBeDisabled()
    const q = within(rowOf(4)).getByLabelText('Quantity')
    fireEvent.keyDown(q, { key: 'Enter' })
    expect(rows()).toHaveLength(5)
    expect(screen.getByTestId('lines-notice')).toHaveTextContent('Line not added')
    fireEvent.paste(q, { clipboardData: { getData: () => 'BOLT\t1\nNUT\t2' } })
    expect(rows()).toHaveLength(5)
    expect(screen.getByTestId('lines-notice')).toHaveTextContent('1 lines pasted, 1 refused (maximum of 5 lines)')
  })
})

describe('paste', () => {
  it('rows from a sheet fill from the focused cell, add rows to the maximum and list the reasons', () => {
    render(<Host initial={mk(1)} />)
    const item = within(rowOf(0)).getByLabelText('Item')
    fireEvent.paste(item, { clipboardData: { getData: () => 'NUT\t\t2,5\r\nNOPE\t\t1\r\nBOLT\t\t4' } })
    expect(rows()).toHaveLength(3)
    expect(within(rowOf(0)).getByLabelText('Quantity')).toHaveValue('2.5')
    expect(within(rowOf(2)).getByLabelText('Quantity')).toHaveValue('4')
    expect(screen.getByTestId('lines-notice')).toHaveTextContent('3 lines pasted')
    expect(screen.getByTestId('lines-notice')).toHaveTextContent('unknown NOPE')
  })
  it('a single value is not handled (the browser pastes it)', () => {
    render(<Host initial={mk(1)} />)
    const ev = fireEvent.paste(within(rowOf(0)).getByLabelText('Quantity'), { clipboardData: { getData: () => '7' } })
    expect(ev).toBe(true)
  })
})

describe('U10 errors', () => {
  it('only touched lines show errors, the badge counts them and Next error focuses the first bad cell', async () => {
    render(<Host initial={[{ item: 'i1', qty: '', ref: '' }, { item: 'i2', qty: '', ref: '' }, { item: 'i1', qty: '2', ref: '' }]} />)
    expect(screen.queryByText(/lines? ha(s|ve) errors/)).not.toBeInTheDocument()
    const q = within(rowOf(1)).getByLabelText('Quantity')
    fireEvent.focus(q)
    fireEvent.blur(q)
    expect(screen.getByText(/1 line has errors/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Next error/ }))
    await waitFor(() => expect(within(rowOf(1)).getByLabelText('Quantity')).toHaveFocus())
    fireEvent.focusIn(within(rowOf(1)).getByLabelText('Quantity'))
    expect(await screen.findByText(/Quantity must be above zero/)).toBeInTheDocument()
  })
  it('showErrors validates every line at once', () => {
    render(<Host initial={[{ item: 'i1', qty: '', ref: '' }, { item: '', qty: '', ref: '' }]} showErrors />)
    expect(screen.getByText(/2 lines have errors/)).toBeInTheDocument()
    expect(rowOf(0)).toHaveClass('is-error')
  })
})

describe('U11 states', () => {
  it('no permission, loading, error with Retry, empty with the actions, read-only', () => {
    const retry = vi.fn()
    const { rerender } = render(<Host noPermission />)
    expect(screen.getByText('No access to the lines')).toBeInTheDocument()
    rerender(<Host state="loading" />)
    expect(screen.getByTestId('lines-loading')).toHaveAttribute('aria-busy', 'true')
    rerender(<Host state="error" onRetry={retry} />)
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(retry).toHaveBeenCalled()
    rerender(<Host />)
    expect(screen.getByText('No lines yet')).toBeInTheDocument()
    expect(screen.getByLabelText('Scan field')).toBeInTheDocument()
    cleanup()
    render(<Host initial={mk(2)} readOnly />)
    expect(screen.queryAllByTestId('line-row')).toHaveLength(2)
    expect(screen.queryByLabelText('Scan field')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Add line' })).not.toBeInTheDocument()
  })
  it('a search with no match says so and can be cleared', () => {
    render(<Host initial={mk(3)} />)
    fireEvent.change(screen.getByLabelText('Search in the lines'), { target: { value: 'zzz' } })
    expect(screen.getByTestId('lines-nomatch')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Clear search' }))
    expect(rows()).toHaveLength(3)
  })
})

describe('U1 virtual rows in the component, U12 focus', () => {
  it('1000 lines mount at most 30 rows and aria-rowcount counts them all', () => {
    render(<Host initial={Array.from({ length: 1000 }, (_, i) => ({ item: 'i1', qty: String(i + 1), ref: '' }))} max={1000} />)
    expect(rows().length).toBeLessThanOrEqual(30)
    expect(screen.getByTestId('lines-scroll')).toHaveAttribute('aria-rowcount', '1001')
  })
  it('Enter in the last cell adds a row and focuses its item cell', async () => {
    render(<Host initial={mk(1)} />)
    fireEvent.keyDown(within(rowOf(0)).getByLabelText('Quantity'), { key: 'Enter' })
    await waitFor(() => expect(rows()).toHaveLength(2))
    await waitFor(() => expect(within(rowOf(1)).getByLabelText('Item')).toHaveFocus())
  })
  it('the lot cell of an item without lots is skipped by Tab', async () => {
    render(<Host initial={[{ item: 'i2', qty: '1', ref: '' }]} />)
    const item = within(rowOf(0)).getByLabelText('Item')
    item.focus()
    fireEvent.keyDown(item, { key: 'Tab' })
    await waitFor(() => expect(within(rowOf(0)).getByLabelText('Quantity')).toHaveFocus())
  })
})

describe('import', () => {
  it('importRows adds rows to the maximum and reports what was refused', async () => {
    let ctl: { importRows: (r: { line: Ln; reason?: string }[]) => void } | undefined
    render(<Host initial={mk(4)} onImport={(c) => { ctl = c }} />)
    fireEvent.click(screen.getByRole('button', { name: 'Import lines from Excel' }))
    act(() => ctl!.importRows([{ line: { item: 'i1', qty: '1', ref: '' } }, { line: { item: 'i2', qty: '2', ref: '' } }]))
    expect(rows()).toHaveLength(5)
    expect(screen.getByTestId('lines-notice')).toHaveTextContent('1 lines added, 1 refused')
  })
})
