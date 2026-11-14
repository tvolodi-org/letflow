// @vitest-environment jsdom
/** T-1946: the one selection rule of list + detail screens: create selects the new record, edit keeps the same
 *  record (and the list pane stays mounted, so its scroll position stays), delete clears the selection. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, renderHook, screen } from '@testing-library/react'
import { ListDetail } from '../ListDetail'
import { selectionAfterSave, useListSelection } from '../useListSelection'

expect.extend(jestDomMatchers)
afterEach(cleanup)

describe('selectionAfterSave', () => {
  it('create selects the new id', () => expect(selectionAfterSave('a', { kind: 'create', id: 'n' })).toBe('n'))
  it('create without an id closes', () => expect(selectionAfterSave('a', { kind: 'create', id: null })).toBeNull())
  it('edit keeps the selection', () => expect(selectionAfterSave('a', { kind: 'edit' })).toBe('a'))
  it('delete clears the selection', () => expect(selectionAfterSave('a', { kind: 'delete' })).toBeNull())
})

function Screen() {
  const sel = useListSelection()
  return (
    <ListDetail
      screen="test.sel"
      listLabel="Items"
      list={
        <div data-testid="list-scroll">
          <button onClick={() => sel.select('a')}>row a</button>
          <button onClick={() => sel.startCreate()}>new</button>
        </div>
      }
      detail={
        <div>
          <p data-testid="record">{sel.creating ? 'creating' : `record ${sel.selectedId}`}</p>
          <button onClick={() => sel.saved(sel.creating ? { kind: 'create', id: 'n1' } : { kind: 'edit' })}>save</button>
          <button onClick={() => sel.saved({ kind: 'delete' })}>delete</button>
        </div>
      }
      empty={<p data-testid="empty-state">Nothing selected</p>}
      detailOpen={sel.selectedId !== null || sel.creating !== null}
      onClose={sel.close}
    />
  )
}

describe('useListSelection in ListDetail', () => {
  it('create: after save the new record is selected and its detail is open', () => {
    render(<Screen />)
    fireEvent.click(screen.getByText('new'))
    expect(screen.getByTestId('record')).toHaveTextContent('creating')
    fireEvent.click(screen.getByText('save'))
    expect(screen.getByTestId('record')).toHaveTextContent('record n1')
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
  })

  it('edit: the same record stays selected and the list pane is not remounted', () => {
    render(<Screen />)
    fireEvent.click(screen.getByText('row a'))
    const list = screen.getByTestId('list-scroll')
    list.scrollTop = 120
    fireEvent.click(screen.getByText('save'))
    expect(screen.getByTestId('record')).toHaveTextContent('record a')
    expect(screen.getByTestId('list-scroll')).toBe(list)
    expect(list.scrollTop).toBe(120)
  })

  it('delete: the selection clears and the empty state shows', () => {
    render(<Screen />)
    fireEvent.click(screen.getByText('row a'))
    fireEvent.click(screen.getByText('delete'))
    expect(screen.getByTestId('empty-state')).toBeInTheDocument()
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
  })

  it('saved() leaves create mode', () => {
    const { result } = renderHook(() => useListSelection<{ parent: string }>())
    act(() => result.current.startCreate({ parent: 'p' }))
    expect(result.current.creating).toEqual({ parent: 'p' })
    act(() => result.current.saved({ kind: 'create', id: 'x' }))
    expect(result.current.creating).toBeNull()
    expect(result.current.selectedId).toBe('x')
  })
})

describe('default first-item selection (T-1946 owner addition)', () => {
  function Dir({ ids, initial = null }: { ids: string[]; initial?: string | null }) {
    const sel = useListSelection(initial)
    return (
      <ListDetail
        screen="test.dir"
        listLabel="Items"
        list={<div>list</div>}
        detail={<p data-testid="record">{`record ${sel.selectedId}`}</p>}
        detailOpen={sel.selectedId !== null || sel.creating !== null}
        onClose={sel.close}
        defaultSelectId={ids[0] ?? null}
        onDefaultSelect={sel.select}
      />
    )
  }
  let width = 1200
  const original = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientWidth')
  beforeEach(() => {
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, get: () => width })
  })
  afterEach(() => {
    if (original) Object.defineProperty(HTMLElement.prototype, 'clientWidth', original)
    width = 1200
  })

  it('wide host: the first item is selected and its detail opens', () => {
    render(<Dir ids={['f1', 'f2']} />)
    expect(screen.getByTestId('record')).toHaveTextContent('record f1')
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open')
  })

  it('empty list: nothing is selected, the empty state stays', () => {
    render(<Dir ids={[]} />)
    expect(screen.queryByTestId('record')).toBeNull()
    expect(screen.getByTestId('list-detail-empty')).toBeInTheDocument()
  })

  it('a record the URL gave wins over the first item', () => {
    render(<Dir ids={['f1', 'f2']} initial="f2" />)
    expect(screen.getByTestId('record')).toHaveTextContent('record f2')
  })

  it('narrow host (single pane): the list stays first, no detail opens', () => {
    width = 600
    render(<Dir ids={['f1', 'f2']} />)
    expect(screen.queryByTestId('record')).toBeNull()
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
  })

  it('after a close the first item is not selected again', () => {
    render(<Dir ids={['f1']} />)
    fireEvent.click(screen.getByTestId('list-detail-back'))
    expect(screen.queryByTestId('record')).toBeNull()
  })
})
