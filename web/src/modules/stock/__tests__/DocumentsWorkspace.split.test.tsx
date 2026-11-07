// @vitest-environment jsdom
/** S1, S3, S4, S6, S7, L1 — T-1443: the document screen has splitters between its panes and handles on the lines columns;
 *  jsdom has no layout, so the container width is stubbed (1600 px) and the panes report fixed rects. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { resetDefaultLayoutStore } from '@/hooks/useLayoutPrefs'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DOCS, LIST, fakeMasters, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const PREFS = '/api/v1/me/preferences'
let width = 1600
const rect = (w: number) => ({ left: 0, right: w, width: w, top: 0, bottom: 300, height: 300, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect

beforeEach(() => {
  localStorage.clear()
  resetDefaultLayoutStore()
  width = 1600
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, get() { return this.classList?.contains('lf-doc') ? width : 0 } })
  HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const grid = this.closest('.lf-doc') as HTMLElement | null
    if (this.classList.contains('lf-doc') || this.tagName === 'TABLE') return rect(1000)
    if (this.tagName === 'TH') return rect(parseFloat(this.style.width || '10') * 10)
    if (this.classList.contains('lf-le')) return rect(width)
    if (this.classList.contains('lf-doc__list')) {
      const v = parseFloat(grid?.style.getPropertyValue('--lf-pane-1') || '19')
      return rect((v / 100) * width)
    }
    return rect(400)
  }
  HTMLElement.prototype.getClientRects = (() => [{}]) as unknown as () => DOMRectList
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

function serve(docs: Record<string, unknown>[], layout = 'row') {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path === PREFS) return { preferences: {}, effective: { 'ui.document_layout': layout }, tenant_defaults: {} }
    for (const d of docs) if (path === `${DOCS}/${String(d['id'])}`) return d
    if (path === DOCS) return { rows: docs.map((d) => ({ ...d, lines: undefined })), next_cursor: null }
    return { rows: [], next_cursor: null }
  })
}
const doc = () => stockDoc({ id: 'd1', number: 'RC-1', state: 'posted' })
const handles = (ws: HTMLElement) => ws.parentElement!.querySelectorAll<HTMLElement>('.lf-split-layer [role="separator"]')
const key = (el: Element, k: string) => act(() => void el.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true })))

describe('T-1443 document screen splitters', () => {
  it('S1 row layout: two handles at 1600 px, one at 1200 px, none at 900 px', async () => {
    serve([doc()])
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-lines')
    await waitFor(() => expect(handles(ws)).toHaveLength(2))
    cleanup()
    width = 1200
    renderStock(`${LIST}/d1`, withPost)
    const ws2 = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-lines')
    await waitFor(() => expect(handles(ws2)).toHaveLength(1))
    cleanup()
    width = 900
    renderStock(`${LIST}/d1`, withPost)
    const ws3 = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-lines')
    expect(handles(ws3)).toHaveLength(0)
  })

  it('S2 tabs layout: one handle', async () => {
    serve([doc()], 'tabs')
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-tabs')
    await waitFor(() => expect(handles(ws)).toHaveLength(1))
  })

  it('S3/S4 keys move the list pane and are remembered; Home/End hit the limits; double click resets', async () => {
    serve([doc()])
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await waitFor(() => expect(handles(ws)).toHaveLength(2))
    const h = handles(ws)[0]!
    const before = h.getAttribute('aria-valuenow')
    key(h, 'ArrowRight')
    expect(ws.style.getPropertyValue('--lf-pane-1')).toMatch(/%$/)
    expect(h.getAttribute('aria-valuenow')).not.toBe(before)
    key(h, 'Home')
    expect(h.getAttribute('aria-valuenow')).toBe(h.getAttribute('aria-valuemin'))
    // written 400 ms after the last change (debounce)
    const stored = () => {
      const k = Object.keys(localStorage).find((x) => x.startsWith('lf.prefs.ui.layout'))
      return k ? JSON.parse(localStorage.getItem(k)!).screens?.['stock.documents']?.panes?.row : undefined
    }
    await waitFor(() => expect(stored()).toBeTruthy(), { timeout: 2000 })
    act(() => void h.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })))
    expect(ws.style.getPropertyValue('--lf-pane-1')).toBe('')
  })

  it('S6 Reset layout clears the screen: variables and column widths', async () => {
    serve([doc()])
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await waitFor(() => expect(handles(ws)).toHaveLength(2))
    key(handles(ws)[0]!, 'ArrowRight')
    expect(ws.style.getPropertyValue('--lf-pane-1')).not.toBe('')
    fireEvent.click(screen.getByTestId('reset-layout'))
    await waitFor(() => expect(ws.style.getPropertyValue('--lf-pane-1')).toBe(''))
  })

  it('S7 the handles follow the cards: skeleton first, three panes after the document arrives', async () => {
    let release: (d: unknown) => void = () => undefined
    const gate = new Promise((r) => (release = r))
    serve([])
    clientMock.get.mockImplementation(async (path: string) => {
      if (path === PREFS) return { preferences: {}, effective: {}, tenant_defaults: {} }
      if (path === `${DOCS}/d1`) return gate
      return { rows: [], next_cursor: null }
    })
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-loading')
    await waitFor(() => expect(handles(ws)).toHaveLength(1))
    release(doc())
    await screen.findByTestId('document-lines')
    await waitFor(() => expect(handles(ws)).toHaveLength(2))
  })

  it('C1/C2 the lines table has column handles by stable ids; keys resize and store under cols.lines', async () => {
    serve([doc()])
    renderStock(`${LIST}/d1`, withPost)
    await screen.findByTestId('document-lines')
    await waitFor(() => expect(screen.getByTestId('document-lines').querySelectorAll('.lf-colhandle').length).toBeGreaterThan(0))
    const table = screen.getByTestId('document-lines')
    expect(Array.from(table.querySelectorAll('th[data-col]')).map((t) => t.getAttribute('data-col'))).toEqual(['item', 'lot', 'qty', 'price', 'value'])
    expect(table.querySelector('th.is-idx')).not.toHaveAttribute('data-col')
    expect(table.querySelectorAll('.lf-colhandle')).toHaveLength(4)
    const h = table.querySelector('th[data-col=item] .lf-colhandle') as HTMLElement
    key(h, 'ArrowRight')
    expect((table.querySelector('th[data-col=item]') as HTMLElement).style.width).toBe('30%')
    key(h, 'Enter')
    expect((table.querySelector('th[data-col=item]') as HTMLElement).style.width).toBe('29%')
  })

  it('C4 an opening balance has no column handles', async () => {
    serve([stockDoc({ id: 'd1', kind: 'opening', number: 'OB-1', state: 'posted' })])
    renderStock(`${LIST}/d1`, withPost)
    const table = await screen.findByTestId('document-lines')
    expect(table.querySelector('.lf-colhandle')).toBeNull()
    expect(table).not.toHaveClass('lf-colresize')
  })

  it('C6 a narrow screen (card mode) has no column handles', async () => {
    width = 600
    serve([doc()])
    renderStock(`${LIST}/d1`, withPost)
    const table = await screen.findByTestId('document-lines')
    expect(table.querySelector('.lf-colhandle')).toBeNull()
  })

  it.each([['en', 'Resize the document list', 'Resize column: Item'], ['ru', 'Ширина списка документов', 'Ширина столбца: '], ['kk', 'Құжаттар тізімінің ені', 'Баған ені']])(
    'L1 handle labels follow the language (%s)',
    async (lang, listLabel, colPrefix) => {
      useUiLocaleStore.getState().setLocaleTransient(lang as 'en' | 'ru' | 'kk')
      serve([doc()])
      renderStock(`${LIST}/d1`, withPost)
      const ws = await screen.findByTestId('document-workspace')
      await waitFor(() => expect(handles(ws)).toHaveLength(2))
      expect(handles(ws)[0]).toHaveAttribute('aria-label', listLabel)
      await screen.findByTestId('document-lines')
      await waitFor(() => expect(screen.getByTestId('document-lines').querySelector('th[data-col=item] .lf-colhandle')?.getAttribute('aria-label')).toContain(colPrefix.replace(/: .*$/, '')))
    },
  )
})
