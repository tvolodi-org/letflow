/** T-1442 — LFColResize (design repo `demo.js`) for a React table. `attachColResize` is the typed port; `useColResize`
 *  re-attaches after each render (the handles are DOM nodes React does not own, removed on cleanup).
 *  The table gets `lf-colresize`; each resizable `th[data-col]` gets a width in percent; the LAST resizable column is the
 *  flexible one. Keys on a handle: Left/Right 1 % (Shift 5 %), Home = smallest, End = largest, Enter/double click = default. */
import { useEffect, type RefObject } from 'react'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import type { LayoutStore } from '@/lib/layoutStore'
import { useLayoutMessages } from './layoutMessages'

export interface ColSpec {
  id: string
  /** Default width in percent (the flexible last column ignores it). */
  w: number
  /** Smallest width in px. */
  min?: number
}

export interface ColResizeOptions {
  id: string
  screen: string
  cols: ColSpec[]
  label?: (colId: string, th: HTMLElement) => string
  enabled?: () => boolean
}

export interface ColResizeHandle {
  reset(): void
  values(): Record<string, number>
  destroy(): void
}

export function attachColResize(table: HTMLElement, store: LayoutStore, o: ColResizeOptions): ColResizeHandle | null {
  const all = Array.from(table.querySelectorAll<HTMLElement>('thead th[data-col]'))
  const ths = all.filter((t) => t.getClientRects().length > 0 && o.cols.some((c) => c.id === t.getAttribute('data-col')))
  const def: Record<string, ColSpec> = {}
  o.cols.forEach((c) => (def[c.id] = c))
  const off = o.enabled ? !o.enabled() : false
  if (off) {
    table.classList.remove('lf-colresize')
    all.forEach((t) => {
      t.style.width = ''
      t.querySelector('.lf-colhandle')?.remove()
    })
    return null
  }
  if (!ths.length) return null
  const idOf = (t: HTMLElement) => t.getAttribute('data-col') ?? ''
  let saved: Record<string, number> = { ...(store.getCols(o.screen, o.id) ?? {}) }
  const vals: Record<string, number> = {}
  const last = ths[ths.length - 1]
  const tw = () => table.getBoundingClientRect().width || 1
  const fixedPct = () => {
    const W = tw()
    let s = 0
    table.querySelectorAll<HTMLElement>('thead th').forEach((t) => {
      if (!ths.includes(t)) s += (t.getBoundingClientRect().width / W) * 100
    })
    return s
  }
  const limits = (id: string): [number, number] => {
    const c = def[id]
    const W = tw()
    const min = c.min ?? 3
    let others = 0
    ths.forEach((t) => {
      const i = idOf(t)
      if (i !== id && t !== last) others += vals[i]
    })
    const lastMin = Math.max(6, ((def[idOf(last)].min ?? 60) / W) * 100)
    return [Math.max(2, (min / W) * 100), Math.max((min / W) * 100, 100 - others - lastMin - fixedPct())]
  }
  const positions = () =>
    ths.forEach((t) => {
      const h = t.querySelector('.lf-colhandle')
      if (!h) return
      const l = limits(idOf(t))
      h.setAttribute('aria-valuenow', String(Math.round((t.getBoundingClientRect().width / tw()) * 100)))
      h.setAttribute('aria-valuemin', String(Math.round(l[0])))
      h.setAttribute('aria-valuemax', String(Math.round(l[1])))
    })
  const paint = () => {
    ths.forEach((t) => {
      t.style.width = t === last ? '' : `${vals[idOf(t)]}%`
    })
    positions()
  }
  const save = () => {
    const s: Record<string, number> = {}
    ths.forEach((t) => {
      const id = idOf(t)
      if (t !== last && saved[id] != null) s[id] = saved[id]
    })
    store.setCols(o.screen, o.id, s)
  }
  ths.forEach((t) => (vals[idOf(t)] = saved[idOf(t)] ?? def[idOf(t)].w))
  // the flexible column needs room: if the remembered widths leave under 6 %, fall back to the defaults
  let sum = 0
  ths.forEach((t) => {
    if (t !== last) sum += vals[idOf(t)]
  })
  if (sum > 94) {
    ths.forEach((t) => (vals[idOf(t)] = def[idOf(t)].w))
    saved = {}
  }
  table.classList.add('lf-colresize')
  const made: HTMLElement[] = []
  ths.forEach((t) => {
    const id = idOf(t)
    if (t === last) return
    t.querySelector('.lf-colhandle')?.remove()
    const h = document.createElement('span')
    h.className = 'lf-colhandle'
    h.setAttribute('role', 'separator')
    h.setAttribute('aria-orientation', 'vertical')
    h.tabIndex = 0
    h.setAttribute('aria-label', o.label ? o.label(id, t) : 'Resize column')
    let drag: { x: number; w: number } | null = null
    const setW = (pct: number, fin: boolean) => {
      const l = limits(id)
      const v = Math.round(Math.min(l[1], Math.max(l[0], pct)) * 10) / 10
      vals[id] = v
      saved[id] = v
      paint()
      if (fin) save()
    }
    const dflt = () => {
      vals[id] = def[id].w
      delete saved[id]
      paint()
      save()
    }
    h.addEventListener('pointerdown', (e) => {
      e.preventDefault()
      e.stopPropagation()
      try {
        h.setPointerCapture(e.pointerId)
      } catch {
        /* synthetic event */
      }
      drag = { x: e.clientX, w: t.getBoundingClientRect().width }
      h.classList.add('is-drag')
      document.body.classList.add('lf-split-dragging')
    })
    h.addEventListener('pointermove', (e) => {
      if (drag) setW(((drag.w + e.clientX - drag.x) / tw()) * 100, false)
    })
    const end = () => {
      if (!drag) return
      drag = null
      h.classList.remove('is-drag')
      document.body.classList.remove('lf-split-dragging')
      save()
    }
    h.addEventListener('pointerup', end)
    h.addEventListener('pointercancel', end)
    h.addEventListener('click', (e) => e.stopPropagation())
    h.addEventListener('dblclick', (e) => {
      e.stopPropagation()
      dflt()
    })
    h.addEventListener('keydown', (e) => {
      const l = limits(id)
      const st = e.shiftKey ? 5 : 1
      if (e.key === 'ArrowRight') {
        e.preventDefault()
        setW(vals[id] + st, true)
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault()
        setW(vals[id] - st, true)
      } else if (e.key === 'Home') {
        e.preventDefault()
        setW(l[0], true)
      } else if (e.key === 'End') {
        e.preventDefault()
        setW(l[1], true)
      } else if (e.key === 'Enter') {
        e.preventDefault()
        dflt()
      }
      e.stopPropagation()
    })
    t.appendChild(h)
    made.push(h)
  })
  paint()
  return {
    reset: () => {
      ths.forEach((t) => (vals[idOf(t)] = def[idOf(t)].w))
      saved = {}
      paint()
      save()
    },
    values: () => ({ ...vals }),
    destroy: () => made.forEach((h) => h.remove()),
  }
}

/** Attach after every render of the table; `opts.label` / `enabled` are read at that time (language, width). */
export function useColResize(tableRef: RefObject<HTMLElement>, opts: ColResizeOptions): void {
  const store = useLayoutPrefs()
  const m = useLayoutMessages()
  useEffect(() => {
    const table = tableRef.current
    if (!table) return
    const go = () => attachColResize(table, store, { label: () => m.resizeColumn, ...opts })
    let cur = go()
    const off = store.subscribe(() => {
      cur?.destroy()
      cur = go()
    })
    return () => {
      off()
      cur?.destroy()
    }
  })
}
