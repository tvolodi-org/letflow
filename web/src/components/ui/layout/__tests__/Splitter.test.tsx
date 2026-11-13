// @vitest-environment jsdom
/** T-1442 S1-S9 — LFSplit behaviour (jsdom, rects stubbed: the container is 1000 px wide, pane 1 is 30 % unless a size is set). */
import { act, cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useRef } from 'react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { createLayoutStore } from '@/lib/layoutStore'
import { attachSplit, type SplitHandle } from '../splitEngine'
import { SplitWrap, useSplit } from '../Splitter'
import { layoutMessages } from '../layoutMessages'

expect.extend(jestDomMatchers)

let store: ReturnType<typeof createLayoutStore>
beforeEach(() => {
  localStorage.clear()
  document.body.innerHTML = ''
  store = createLayoutStore({ storageKey: 'test.layout' })
})
afterEach(cleanup)

const rect = (left: number, width: number) => ({ left, right: left + width, width, top: 0, bottom: 400, height: 400, x: left, y: 0, toJSON: () => ({}) }) as DOMRect

function setup(extra: Partial<Parameters<typeof attachSplit>[1]> = {}) {
  const container = document.createElement('div')
  const a = document.createElement('div')
  const b = document.createElement('div')
  const layer = document.createElement('div')
  container.append(a, b, layer)
  document.body.append(container)
  Object.defineProperty(container, 'clientWidth', { value: 1000 })
  const pct = () => {
    const v = container.style.getPropertyValue('--lf-pane-1')
    return v.endsWith('%') ? parseFloat(v) : v.endsWith('px') ? parseFloat(v) / 10 : 30
  }
  a.getBoundingClientRect = () => rect(0, pct() * 10)
  b.getBoundingClientRect = () => rect(pct() * 10 + 16, 1000 - pct() * 10 - 16)
  layer.getBoundingClientRect = () => rect(0, 1000)
  const split = attachSplit(container, {
    id: 'sp', screen: 'scr', store, panes: () => [a, b], vars: ['--lf-pane-1'], unit: 'pct', sized: 'before', min: [100],
    flexMin: 200, enabled: () => true, labels: ['List'], layer, ...extra,
  })
  return { container, a, b, layer, split, handle: layer.querySelector('.lf-splitter') as HTMLElement }
}

describe('attachSplit', () => {
  it('S1 builds one separator with the ARIA values and the pane name as label', () => {
    const { handle, a } = setup()
    expect(handle).toHaveAttribute('role', 'separator')
    expect(handle).toHaveAttribute('aria-orientation', 'vertical')
    expect(handle).toHaveAttribute('aria-label', 'List')
    expect(handle).toHaveAttribute('aria-valuenow', '30')
    expect(handle).toHaveAttribute('aria-valuemin', '10')
    expect(handle).toHaveAttribute('aria-controls', a.id)
    expect(handle.tabIndex).toBe(0)
  })

  it('S2 ArrowRight grows 1 %, Shift 5 %, ArrowLeft shrinks; the size is stored', () => {
    const { handle, container } = setup()
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('31%')
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', shiftKey: true })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('36%')
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('35%')
    expect(store.getPanes('scr', 'sp')).toEqual([35])
  })

  it('S-T1875 clampStored shows a stored size below the min at the min and keeps the stored value; off by default', () => {
    store.setPanes('scr', 'sp', [5])
    const on = setup({ clampStored: true })
    expect(on.container.style.getPropertyValue('--lf-pane-1')).toBe('10%')
    expect(store.getPanes('scr', 'sp')).toEqual([5])
    expect(setup().container.style.getPropertyValue('--lf-pane-1')).toBe('5%')
    store.setPanes('scr', 'sp', [42])
    expect(setup({ clampStored: true }).container.style.getPropertyValue('--lf-pane-1')).toBe('42%')
  })

  it('S3 Home and End hit the limits (min 100 px, max leaves the flexible pane its minimum)', () => {
    const { handle, container } = setup()
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('10%')
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'End' })))
    expect(parseFloat(container.style.getPropertyValue('--lf-pane-1'))).toBeGreaterThan(60)
    expect(parseFloat(container.style.getPropertyValue('--lf-pane-1'))).toBeLessThanOrEqual(78.4)
  })

  it('S4 Enter resets when the pane is not collapsible; double click resets too', () => {
    const { handle, container } = setup()
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' })))
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('')
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' })))
    act(() => void handle.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('')
    expect(store.getPanes('scr', 'sp')).toBeNull()
  })

  it('S5 Enter collapses a collapsible pane and again restores it; the flag is stored', () => {
    const { handle, container, a } = setup({ collapsible: [0], collapsedSize: 0 })
    const btn = handle.querySelector('.lf-splitter__btn') as HTMLElement
    expect(btn).toHaveAttribute('aria-expanded', 'true')
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('0px')
    expect(a).toHaveClass('is-collapsed')
    expect(btn).toHaveAttribute('aria-expanded', 'false')
    expect(store.getCollapsed('scr', 'sp')).toEqual([0])
    act(() => void btn.dispatchEvent(new MouseEvent('click', { bubbles: true })))
    expect(a).not.toHaveClass('is-collapsed')
    expect(store.getCollapsed('scr', 'sp')).toEqual([])
  })

  it('S6 a pointer drag writes the variable and stores the size on release', () => {
    const { handle, container } = setup()
    const ev = (type: string, x: number) => Object.assign(new MouseEvent(type, { bubbles: true, clientX: x }), { pointerId: 1 })
    act(() => void handle.dispatchEvent(ev('pointerdown', 300)))
    act(() => void handle.dispatchEvent(ev('pointermove', 400)))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('40%')
    expect(store.getPanes('scr', 'sp')).toBeNull()
    act(() => void handle.dispatchEvent(ev('pointerup', 400)))
    expect(store.getPanes('scr', 'sp')).toEqual([40])
    expect(document.body).not.toHaveClass('lf-split-dragging')
  })

  it('S7 enabled() false builds no handle', () => {
    const { layer } = setup({ enabled: () => false })
    expect(layer.querySelector('.lf-splitter')).toBeNull()
  })

  it('S8 a stored size is applied on attach; a px size outside min/max is clamped, not rewritten', () => {
    store.setPanes('scr', 'sp', [42])
    const one = setup()
    expect(one.container.style.getPropertyValue('--lf-pane-1')).toBe('42%')
    one.split.destroy()
    store.setShell({ w: 420 })
    const shell = setup({ shell: true, id: 'sidenav', unit: 'px', vars: ['--lf-pane-1'], min: [200], max: [360] })
    expect(shell.container.style.getPropertyValue('--lf-pane-1')).toBe('360px')
    expect(store.getShell().w).toBe(420)
  })

  it('S9 the hook labels the handle from the catalog in en, ru and kk, and cleans up', async () => {
    const { useUiLocaleStore } = await import('@/i18n/uiLocaleStore')
    const out: { h?: SplitHandle | null } = {}
    function Grid() {
      const grid = useRef<HTMLDivElement>(null)
      const layer = useRef<HTMLDivElement>(null)
      out.h = useSplit(grid, layer, { id: 'sp', screen: 'scr', panes: () => [grid.current?.children[0] as HTMLElement, grid.current?.children[1] as HTMLElement], enabled: () => true, vars: ['--lf-pane-1'] }).current
      return (
        <SplitWrap layerRef={layer}>
          <div ref={grid}>
            <div />
            <div />
          </div>
        </SplitWrap>
      )
    }
    for (const loc of ['en', 'ru', 'kk'] as const) {
      act(() => useUiLocaleStore.getState().setLocale(loc))
      const r = render(<Grid />)
      const h = r.container.querySelector('.lf-splitter') as HTMLElement
      expect(h).toHaveAttribute('aria-label', layoutMessages[loc].resize)
      r.unmount()
      expect(document.querySelector('.lf-splitter')).toBeNull()
    }
    act(() => useUiLocaleStore.getState().setLocale('en'))
  })
})

describe('T-1873 collapse trap', () => {
  const key = (k: string) => new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true })

  it('T3 double click toggles a collapsible pane both ways; the button is not part of it', () => {
    const { handle, a } = setup({ collapsible: [0], collapsedSize: 0 })
    act(() => void handle.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })))
    expect(a).toHaveClass('is-collapsed')
    expect(store.getCollapsed('scr', 'sp')).toEqual([0])
    act(() => void handle.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })))
    expect(a).not.toHaveClass('is-collapsed')
    expect(store.getCollapsed('scr', 'sp')).toEqual([])
  })

  it('T1/T7 the collapsed handle keeps a labelled, titled, focusable button; Enter and Space toggle', () => {
    const { handle, a } = setup({ collapsible: [0], collapsedSize: 0 })
    const btn = handle.querySelector('.lf-splitter__btn') as HTMLElement
    expect(btn.tabIndex).toBe(-1)
    act(() => void handle.dispatchEvent(key('Enter')))
    expect(handle).toHaveClass('is-collapsed')
    expect(btn.tabIndex).toBe(0)
    expect(btn.getAttribute('aria-label')).toMatch(/^Expand: List/)
    expect(btn.getAttribute('title')).toBe(btn.getAttribute('aria-label'))
    expect(btn).toHaveAttribute('aria-expanded', 'false')
    expect(btn).toHaveAttribute('aria-controls', a.id)
    act(() => void handle.dispatchEvent(key(' ')))
    expect(handle).not.toHaveClass('is-collapsed')
    expect(btn).toHaveAttribute('aria-expanded', 'true')
    act(() => void handle.dispatchEvent(key('ArrowRight')))
    expect(handle).toHaveAttribute('aria-valuenow', '31')
  })

  it('T4 Escape on the handle clears every saved layout, once, and stops propagating', () => {
    const reset = vi.fn()
    store = createLayoutStore({ storageKey: 'test.layout', reset })
    store.setCollapsed('other', 'sp', [0])
    const { handle, a } = setup({ collapsible: [0], collapsedSize: 0 })
    act(() => void handle.dispatchEvent(key('Enter')))
    expect(a).toHaveClass('is-collapsed')
    const outer = vi.fn()
    document.body.addEventListener('keydown', outer)
    act(() => void handle.dispatchEvent(key('Escape')))
    document.body.removeEventListener('keydown', outer)
    expect(outer).not.toHaveBeenCalled()
    expect(reset).toHaveBeenCalledTimes(1)
    expect(store.getCollapsed('other', 'sp')).toEqual([])
    expect(localStorage.getItem('test.layout')).toBeNull()
  })

  it('T6 a stored collapse is shown open while its control is not rendered, and kept in the store', () => {
    store.setCollapsed('scr', 'sp', [0])
    const off = setup({ collapsible: [0], collapsedSize: 0, enabled: () => false })
    expect(off.a).not.toHaveClass('is-collapsed')
    expect(off.container.style.getPropertyValue('--lf-pane-1')).not.toBe('0px')
    expect(store.getCollapsed('scr', 'sp')).toEqual([0])
    off.split.destroy()
    const one = setup({ collapsible: [0], collapsedSize: 0, panes: () => [document.createElement('div')] })
    expect(one.container.style.getPropertyValue('--lf-pane-1')).not.toBe('0px')
    one.split.destroy()
    const on = setup({ collapsible: [0], collapsedSize: 0 })
    expect(on.a).toHaveClass('is-collapsed')
    expect(on.handle).toHaveClass('is-collapsed')
    const btn = on.handle.querySelector('.lf-splitter__btn') as HTMLElement
    act(() => void btn.dispatchEvent(new MouseEvent('click', { bubbles: true })))
    expect(on.a).not.toHaveClass('is-collapsed')
    expect(store.getCollapsed('scr', 'sp')).toEqual([])
  })

  it('T9 collapse, reload (remount from the stored copy), restore, then reset after reload', () => {
    const one = setup({ collapsible: [0], collapsedSize: 0 })
    act(() => void one.handle.dispatchEvent(key('Enter')))
    store.flush()
    one.split.destroy()
    document.body.innerHTML = ''
    store = createLayoutStore({ storageKey: 'test.layout' })
    const two = setup({ collapsible: [0], collapsedSize: 0 })
    expect(two.a).toHaveClass('is-collapsed')
    const btn = two.handle.querySelector('.lf-splitter__btn') as HTMLElement
    expect(btn).toHaveAttribute('aria-expanded', 'false')
    act(() => void btn.dispatchEvent(new MouseEvent('click', { bubbles: true })))
    expect(two.a).not.toHaveClass('is-collapsed')
    act(() => void two.handle.dispatchEvent(key('Enter')))
    act(() => void two.handle.dispatchEvent(key('Escape')))
    expect(localStorage.getItem('test.layout')).toBeNull()
    expect(store.getCollapsed('scr', 'sp')).toEqual([])
  })
})

describe('defaults option', () => {
  it('P2 defaults:[60] is applied while nothing is stored, a key press wins, reset returns to it and stores null', () => {
    const { handle, container } = setup({ defaults: [60] })
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('60%')
    expect(store.getPanes('scr', 'sp')).toBeNull()
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('61%')
    expect(store.getPanes('scr', 'sp')).toEqual([61])
    act(() => void handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' })))
    expect(container.style.getPropertyValue('--lf-pane-1')).toBe('60%')
  })
})

describe('layoutMessages', () => {
  it('has the same keys in en, ru and kk, all non-empty', () => {
    const keys = Object.keys(layoutMessages.en).sort()
    for (const loc of ['ru', 'kk'] as const) {
      expect(Object.keys(layoutMessages[loc]).sort()).toEqual(keys)
      expect(Object.values(layoutMessages[loc]).every((v) => v.length > 0)).toBe(true)
    }
  })
})

vi.stubGlobal('ResizeObserver', undefined)
