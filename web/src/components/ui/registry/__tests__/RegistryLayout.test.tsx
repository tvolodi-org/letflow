// @vitest-environment jsdom
/** T-1446 T5-T7: the registry list's resizable columns (the list | details splitter is tested in ListDetail.test) (jsdom, widths stubbed). */
import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { ReactElement } from 'react'
import { createLayoutStore } from '@/lib/layoutStore'
import { RegistryList, type RegistryColumn } from '../RegistryList'

expect.extend(jestDomMatchers)

// the hook reads the store of this test file (the real provider needs react-query)
const holder = vi.hoisted(() => ({ store: null as unknown }))
vi.mock('@/hooks/useLayoutPrefs', () => ({ useLayoutPrefs: () => holder.store }))

let store: ReturnType<typeof createLayoutStore>
let width = 1200
beforeEach(() => {
  localStorage.clear()
  width = 1200
  store = createLayoutStore({ storageKey: 'test.reg' })
  holder.store = store
  vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockImplementation(() => width)
  vi.spyOn(HTMLElement.prototype, 'getClientRects').mockImplementation(() => [{}] as unknown as DOMRectList)
  vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function (this: HTMLElement) {
    const pct = parseFloat(this.style.width || '0')
    const w = this.tagName === 'TABLE' ? 600 : this.tagName === 'TH' ? (pct ? pct * 6 : 100) : width / 3
    return { left: 0, right: w, width: w, top: 0, bottom: 40, height: 40, x: 0, y: 0, toJSON: () => ({}) } as DOMRect
  })
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const wrap = (el: ReactElement) => el
const key = (el: Element, k: string, shiftKey = false) => act(() => void el.dispatchEvent(new KeyboardEvent('keydown', { key: k, shiftKey, bubbles: true })))

interface Row { id: string; a: string; b: string; c: string }
const COLUMNS: RegistryColumn<Row>[] = [
  { key: 'a', header: 'Alpha', sortable: true, width: { w: 30, min: 50 }, render: (r) => r.a },
  { key: 'b', header: 'Beta', width: { w: 20, min: 50 }, render: (r) => r.b },
  { key: 'c', header: 'Gamma', width: { w: 0, min: 60 }, render: (r) => r.c },
]
function tableList(onSort = vi.fn(), colResize: { screen: string } | undefined = { screen: 'x.reg' }) {
  return (
    <RegistryList<Row>
      title="T" titleId="t" labels={{ search: 's', showRetired: 'r', clearFilters: 'c', removeFilter: 'f', retry: 'r', pages: 'p', prev: 'a', next: 'b' }}
      state="ready" columns={COLUMNS} rows={[{ id: '1', a: 'x', b: 'y', c: 'z' }]} rowId={(r) => r.id} selectedId={null} onOpen={() => {}}
      query="" onQuery={() => {}} onClearFilters={() => {}} filtered={false} showRetired={false} onShowRetired={() => {}}
      sortKey="a" sortDir="asc" onSort={onSort} page={1} pageCount={1} onPage={() => {}} rangeText="1" empty={{ title: 'e', text: 'e' }}
      noMatch={{ title: 'n', text: 'n' }} colResize={colResize}
    />
  )
}
const inReg = (el: ReactElement) => wrap(<div className="lf-reg">{el}</div>)

describe('RegistryList columns', () => {
  it('T5 data-col on every header, handles on all but the last, table gets lf-colresize', () => {
    render(inReg(tableList()))
    expect(screen.getAllByRole('columnheader').map((h) => h.getAttribute('data-col'))).toEqual(['a', 'b', 'c'])
    expect(document.querySelectorAll('.lf-colhandle')).toHaveLength(2)
    expect(screen.getByRole('grid')).toHaveClass('lf-colresize')
  })

  it('T6 keys change the width and store it; Enter resets; a pointer drag does not sort', () => {
    const onSort = vi.fn()
    render(inReg(tableList(onSort)))
    const th = document.querySelector('th[data-col=a]') as HTMLElement
    const h = th.querySelector('.lf-colhandle') as HTMLElement
    key(h, 'ArrowRight')
    expect(th.style.width).toBe('31%')
    key(h, 'ArrowRight', true)
    expect(th.style.width).toBe('36%')
    expect(store.getCols('x.reg', 'list')).toEqual({ a: 36 })
    act(() => {
      h.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, clientX: 10 }))
      h.dispatchEvent(new MouseEvent('pointerup', { bubbles: true, clientX: 10 }))
      h.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    })
    expect(onSort).not.toHaveBeenCalled()
    key(h, 'Enter')
    expect(th.style.width).toBe('30%')
  })

  it('T7 under 900 px no handles and no lf-colresize; sorting still works', () => {
    width = 600
    const onSort = vi.fn()
    render(inReg(tableList(onSort)))
    expect(document.querySelectorAll('.lf-colhandle')).toHaveLength(0)
    expect(screen.getByRole('grid')).not.toHaveClass('lf-colresize')
    act(() => void screen.getByTestId('registry-sort-a').click())
    expect(onSort).toHaveBeenCalledWith('a')
  })
})
