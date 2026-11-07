// @vitest-environment jsdom
/** T-1442 C1-C6 — LFColResize (jsdom, the table is 1000 px wide and every th reports its percent width). */
import { act, cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { useRef } from 'react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { createLayoutStore } from '@/lib/layoutStore'
import { attachColResize, useColResize } from '../ColumnResize'

expect.extend(jestDomMatchers)

let store: ReturnType<typeof createLayoutStore>
beforeEach(() => {
  localStorage.clear()
  document.body.innerHTML = ''
  store = createLayoutStore({ storageKey: 'test.cols' })
})
afterEach(cleanup)

const COLS = [
  { id: 'a', w: 30, min: 50 },
  { id: 'b', w: 20, min: 50 },
  { id: 'c', w: 0, min: 50 },
]

function makeTable() {
  const table = document.createElement('table')
  table.innerHTML = '<thead><tr><th data-col="a">A</th><th data-col="b">B</th><th data-col="c">C</th></tr></thead>'
  document.body.append(table)
  table.getBoundingClientRect = () => ({ width: 1000, left: 0, right: 1000, top: 0, bottom: 40, height: 40, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect
  table.querySelectorAll('th').forEach((th) => {
    th.getClientRects = () => [{}] as unknown as DOMRectList
    th.getBoundingClientRect = () => ({ width: parseFloat(th.style.width || '30') * 10, left: 0, right: 0, top: 0, bottom: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect
  })
  return table
}
const key = (el: Element, k: string, shiftKey = false) => act(() => void el.dispatchEvent(new KeyboardEvent('keydown', { key: k, shiftKey, bubbles: true })))

describe('attachColResize', () => {
  it('C1 handles on all but the last column; the table gets lf-colresize; defaults are painted', () => {
    const table = makeTable()
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS, label: (id) => `col ${id}` })
    expect(table).toHaveClass('lf-colresize')
    const hs = table.querySelectorAll('.lf-colhandle')
    expect(hs).toHaveLength(2)
    expect(hs[0]).toHaveAttribute('role', 'separator')
    expect(hs[0]).toHaveAttribute('aria-label', 'col a')
    expect((table.querySelector('th[data-col=a]') as HTMLElement).style.width).toBe('30%')
    expect((table.querySelector('th[data-col=c]') as HTMLElement).style.width).toBe('')
  })

  it('C2 keys: Right 1 %, Shift 5 %, Left, Home, End; the width is stored', () => {
    const table = makeTable()
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS })
    const h = table.querySelector('th[data-col=a] .lf-colhandle') as HTMLElement
    const w = () => (table.querySelector('th[data-col=a]') as HTMLElement).style.width
    key(h, 'ArrowRight')
    expect(w()).toBe('31%')
    key(h, 'ArrowRight', true)
    expect(w()).toBe('36%')
    key(h, 'ArrowLeft')
    expect(w()).toBe('35%')
    expect(store.getCols('s', 't')).toEqual({ a: 35 })
    key(h, 'Home')
    expect(w()).toBe('5%')
    key(h, 'End')
    expect(parseFloat(w())).toBeLessThanOrEqual(100)
  })

  it('C3 Enter and double click return a column to its default and forget it', () => {
    const table = makeTable()
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS })
    const h = table.querySelector('th[data-col=a] .lf-colhandle') as HTMLElement
    key(h, 'ArrowRight')
    key(h, 'Enter')
    expect((table.querySelector('th[data-col=a]') as HTMLElement).style.width).toBe('30%')
    expect(store.getCols('s', 't')).toBeNull()
    key(h, 'ArrowRight')
    act(() => void h.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })))
    expect((table.querySelector('th[data-col=a]') as HTMLElement).style.width).toBe('30%')
  })

  it('C4 remembered widths are applied', () => {
    store.setCols('s', 't', { a: 41, b: 12 })
    const table = makeTable()
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS })
    expect((table.querySelector('th[data-col=a]') as HTMLElement).style.width).toBe('41%')
    expect((table.querySelector('th[data-col=b]') as HTMLElement).style.width).toBe('12%')
  })

  it('C5 remembered widths leaving under 6 % for the flexible column fall back to the defaults', () => {
    store.setCols('s', 't', { a: 60, b: 38 })
    const table = makeTable()
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS })
    expect((table.querySelector('th[data-col=a]') as HTMLElement).style.width).toBe('30%')
    expect((table.querySelector('th[data-col=b]') as HTMLElement).style.width).toBe('20%')
  })

  it('C6 enabled() false removes the class, widths and handles; destroy removes handles', () => {
    const table = makeTable()
    const h = attachColResize(table, store, { id: 't', screen: 's', cols: COLS })
    h?.destroy()
    expect(table.querySelectorAll('.lf-colhandle')).toHaveLength(0)
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS })
    attachColResize(table, store, { id: 't', screen: 's', cols: COLS, enabled: () => false })
    expect(table).not.toHaveClass('lf-colresize')
    expect(table.querySelectorAll('.lf-colhandle')).toHaveLength(0)
    expect((table.querySelector('th[data-col=a]') as HTMLElement).style.width).toBe('')
  })

  it('C7 the hook attaches after render and removes the handles on unmount', () => {
    function T() {
      const ref = useRef<HTMLTableElement>(null)
      useColResize(ref, { id: 't', screen: 's', cols: COLS })
      return (
        <table ref={ref}>
          <thead>
            <tr>
              <th data-col="a">A</th>
              <th data-col="b">B</th>
              <th data-col="c">C</th>
            </tr>
          </thead>
        </table>
      )
    }
    const orig = HTMLElement.prototype.getClientRects
    HTMLElement.prototype.getClientRects = () => [{}] as unknown as DOMRectList
    try {
      const r = render(<T />)
      expect(r.container.querySelectorAll('.lf-colhandle')).toHaveLength(2)
      expect(r.container.querySelector('.lf-colhandle')).toHaveAttribute('aria-label', 'Resize column')
      r.unmount()
      expect(document.querySelectorAll('.lf-colhandle')).toHaveLength(0)
    } finally {
      HTMLElement.prototype.getClientRects = orig
    }
  })
})
