/** T-1442 — LFSplit (design repo `platform/style-guide/demo.js`) as a typed engine with the same DOM and class names,
 *  so the copied `components.css` applies unchanged. Percent sizes (`unit: 'pct'`) or px (side nav). The grid container
 *  reads `var(--lf-pane-N, <default>)`; the engine sets those custom properties (a user-chosen size, no colour or spacing).
 *  Handles live in a layer (`.lf-split-layer`) outside the re-rendered content; call `refresh()` after each render.
 *  Keys: Left/Right 1 % (Shift 5 %; px unit 8/32), Home = smallest, End = largest, Enter = collapse (collapsible pane)
 *  or reset, double click = collapse/expand (collapsible pane) or reset, Escape = reset every saved layout. Sizes and collapsed flags are remembered through the `LayoutStore`. */
import type { LayoutStore } from '@/lib/layoutStore'

export interface SplitOptions {
  id: string
  /** Screen id (key in `screens`), unused for the shell. */
  screen?: string
  store: LayoutStore
  /** The side nav splitter: sizes go to `shell.sidenav`. */
  shell?: boolean
  panes: () => (HTMLElement | null)[]
  vars?: string[]
  sized?: 'before' | 'after'
  unit?: 'pct' | 'px'
  min?: number[]
  max?: number[]
  flexMin?: number
  collapsible?: number[]
  collapsedSize?: number
  enabled: () => boolean
  labels?: string[]
  layer: HTMLElement
  /** `Collapse` / `Expand` words for the handle button; `resize` is the default handle label. */
  text?: { resize: string; collapse: string; expand: string }
  onCollapse?: (collapsed: Record<number, boolean>) => void
  /** Default size per pane in percent (`unit: 'pct'` only), used while nothing is stored; reset returns to it. */
  defaults?: number[]
  /** pct only: a stored size below `min[k]` is shown at `min[k]` (px of the container to percent, rounded up to 0.1);
   *  the store keeps the user's value, as for px. */
  clampStored?: boolean
}

export interface SplitHandle {
  refresh(): void
  place(): void
  set(k: number, px: number, final?: boolean): void
  toggle(k: number): void
  reset(): void
  handles(): HTMLElement[]
  state(): { sizes: (number | null)[]; collapsed: Record<number, boolean> }
  destroy(): void
}

const SVG_NS = 'http://www.w3.org/2000/svg'

function chevronsLeft(): SVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('class', 'lf-icon')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '2')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('stroke-linejoin', 'round')
  svg.setAttribute('aria-hidden', 'true')
  for (const d of ['m11 17-5-5 5-5', 'm18 17-5-5 5-5']) {
    const p = document.createElementNS(SVG_NS, 'path')
    p.setAttribute('d', d)
    svg.appendChild(p)
  }
  return svg
}

/** T-1884: viewport y of the expand button of a collapsed pane. Normally `pad` under the strip top; pushed down to the
 *  visible top (below the sticky top bar) when the strip top is scrolled above it; pulled up to the bottom edge of the
 *  viewport when the strip top is below the fold. So the way back is on screen wherever the strip is. When the viewport
 *  is too short for the range, `visTop` wins. */
export function expanderTop(stripTop: number, visTop: number, viewH: number, btnH: number, pad: number): number {
  const lo = visTop
  const hi = Math.max(lo, viewH - btnH - pad)
  return Math.min(Math.max(stripTop + pad, lo), hi)
}

export function attachSplit(container: HTMLElement, o: SplitOptions): SplitHandle {
  const vars = o.vars ?? ['--lf-pane-1']
  const unit = o.unit ?? 'pct'
  const sized = o.sized ?? 'before'
  const flexMin = o.flexMin ?? 280
  const collapsible = o.collapsible ?? []
  const csz = () => o.collapsedSize ?? 0
  /** Read on every `place()`, so a language switch relabels the handles. */
  const textNow = () => o.text ?? { resize: 'Resize', collapse: 'Collapse', expand: 'Expand' }
  const layer = o.layer
  const handles: HTMLElement[] = []
  let sizes: (number | null)[] = []
  let collapsed: Record<number, boolean> = {}
  let drag: { k: number; x: number; w: number; h: HTMLElement } | null = null

  const stored = () => {
    if (o.shell) {
      const s = o.store.getShell()
      sizes = [s.w ?? null]
      collapsed = s.collapsed ? { 0: true } : {}
    } else {
      const p = o.store.getPanes(o.screen ?? '', o.id)
      sizes = vars.map((_, i) => p?.[i] ?? null)
      collapsed = {}
      o.store.getCollapsed(o.screen ?? '', o.id).forEach((k) => (collapsed[k] = true))
    }
  }
  const persist = () => {
    if (o.shell) {
      o.store.setShell({ w: sizes[0] != null ? Math.round(sizes[0]) : null, collapsed: collapsed[0] ? true : null })
      return
    }
    o.store.setPanes(o.screen ?? '', o.id, sizes.slice())
    o.store.setCollapsed(
      o.screen ?? '',
      o.id,
      Object.keys(collapsed)
        .filter((k) => collapsed[Number(k)])
        .map(Number),
    )
  }
  const cw = () => {
    const cs = getComputedStyle(container)
    return container.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0)
  }
  const paneOf = (k: number) => o.panes()[sized === 'after' ? k + 1 : k] ?? null

  /** A collapse is shown only while its restore control is rendered (T-1873): the splitter is enabled, its handle
   *  exists and both panes of the pair are there. Otherwise the pane is shown open; the stored flag stays as it is. */
  const eff = (k: number) => {
    if (!collapsed[k] || !o.enabled() || !handles[k]) return false
    const panes = o.panes()
    return !!panes[k] && !!panes[k + 1]
  }
  const effMap = () => {
    const m: Record<number, boolean> = {}
    vars.forEach((_, k) => {
      if (eff(k)) m[k] = true
    })
    return m
  }
  const setVar = (v: string, val: string) => {
    if (container.style.getPropertyValue(v) !== val) container.style.setProperty(v, val)
  }

  const apply = () => {
    vars.forEach((v, k) => {
      if (eff(k)) setVar(v, `${csz()}px`)
      else if (sizes[k] != null) {
        // a stored px size outside the allowed range is clamped here, not rewritten in the store
        const px = unit === 'px' ? Math.min(o.max?.[k] ?? 420, Math.max(o.min?.[k] ?? 160, sizes[k] as number)) : null
        let pctVal = sizes[k] as number
        if (px == null && o.clampStored) {
          const w = cw()
          const lo = o.min?.[k]
          if (w > 0 && lo != null) pctVal = Math.max(pctVal, Math.ceil((lo / w) * 1000) / 10)
        }
        setVar(v, px != null ? `${px}px` : `${pctVal}%`)
      }
      else if (unit === 'pct' && typeof o.defaults?.[k] === 'number') setVar(v, `${o.defaults[k]}%`)
      else container.style.removeProperty(v)
      const pn = paneOf(k)
      if (pn) pn.classList.toggle('is-collapsed', eff(k) && csz() === 0)
    })
    o.onCollapse?.(effMap())
  }
  /** [min, max] of the sized pane in px. */
  const limits = (k: number): [number, number] => {
    const W = cw()
    const panes = o.panes()
    const gap = 16
    let others = 0
    panes.forEach((p, i) => {
      const idx = sized === 'after' ? i - 1 : i
      if (idx !== k && idx >= 0 && idx < vars.length && p) others += p.getBoundingClientRect().width
    })
    const min = o.min?.[k] ?? 160
    const max = unit === 'px' ? (o.max?.[k] ?? 420) : Math.max(min, W - others - gap * (panes.length - 1) - flexMin)
    return [min, Math.max(min, max)]
  }
  const px2val = (px: number) => (unit === 'px' ? Math.round(px) : Math.round((px / (cw() || 1)) * 1000) / 10)
  const curPx = (k: number) => paneOf(k)?.getBoundingClientRect().width ?? 0

  const set = (k: number, px: number, final?: boolean) => {
    const l = limits(k)
    const v = Math.min(l[1], Math.max(l[0], px))
    collapsed[k] = false
    sizes[k] = px2val(v)
    apply()
    place()
    if (final) persist()
  }
  const reset = (k: number) => {
    sizes[k] = null
    collapsed[k] = false
    apply()
    place()
    persist()
  }
  const toggle = (k: number) => {
    // a stored collapse that is not shown (no control rendered) opens instead of collapsing again
    collapsed[k] = collapsed[k] && !eff(k) ? false : !collapsed[k]
    apply()
    place()
    persist()
  }

  const makeHandle = (k: number) => {
    const h = document.createElement('div')
    h.className = 'lf-splitter'
    h.setAttribute('role', 'separator')
    h.setAttribute('aria-orientation', 'vertical')
    h.tabIndex = 0
    h.setAttribute('data-k', String(k))
    const line = document.createElement('span')
    line.className = 'lf-splitter__line'
    h.appendChild(line)
    if (collapsible.includes(k)) {
      const b = document.createElement('button')
      b.type = 'button'
      b.className = 'lf-splitter__btn'
      b.tabIndex = -1
      b.appendChild(chevronsLeft())
      h.appendChild(b)
    }
    const onBtn = (e: Event) => !!(e.target as Element | null)?.closest('.lf-splitter__btn')
    h.addEventListener('pointerdown', (e) => {
      if (onBtn(e)) return
      e.preventDefault()
      try {
        h.setPointerCapture(e.pointerId)
      } catch {
        /* synthetic event */
      }
      drag = { k, x: e.clientX, w: curPx(k), h }
      h.classList.add('is-drag')
      document.body.classList.add('lf-split-dragging')
    })
    h.addEventListener('pointermove', (e) => {
      if (!drag || drag.h !== h) return
      const dx = e.clientX - drag.x
      set(k, drag.w + (sized === 'after' ? -dx : dx), false)
    })
    const end = () => {
      if (!drag || drag.h !== h) return
      drag = null
      h.classList.remove('is-drag')
      document.body.classList.remove('lf-split-dragging')
      persist()
    }
    h.addEventListener('pointerup', end)
    h.addEventListener('pointercancel', end)
    h.addEventListener('dblclick', (e) => {
      if (onBtn(e)) return
      if (collapsible.includes(k)) toggle(k)
      else reset(k)
    })
    h.addEventListener('click', (e) => {
      if (onBtn(e)) toggle(k)
    })
    h.addEventListener('keydown', (e) => {
      const step = unit === 'px' ? (e.shiftKey ? 32 : 8) : cw() * (e.shiftKey ? 0.05 : 0.01)
      const l = limits(k)
      const dir = sized === 'after' ? -1 : 1
      if (e.key === 'ArrowRight') {
        e.preventDefault()
        set(k, curPx(k) + dir * step, true)
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault()
        set(k, curPx(k) - dir * step, true)
      } else if (e.key === 'Home') {
        e.preventDefault()
        set(k, l[0], true)
      } else if (e.key === 'End') {
        e.preventDefault()
        set(k, l[1], true)
      } else if (e.key === 'Enter' || (e.key === ' ' && !onBtn(e))) {
        if (onBtn(e)) return // native click on the button
        e.preventDefault()
        if (collapsible.includes(k)) toggle(k)
        else reset(k)
      } else if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        o.store.resetAll()
      }
    })
    layer.appendChild(h)
    handles.push(h)
  }

  const build = () => {
    let want = o.enabled() ? o.panes().length - 1 : 0
    want = Math.max(0, Math.min(want, vars.length))
    while (handles.length > want) handles.pop()?.remove()
    while (handles.length < want) makeHandle(handles.length)
  }

  /** T-1884: the expand button of a collapsed pane is `position: fixed` (base.css) and placed against the viewport. */
  function placeExpander(btn: HTMLElement, isEff: boolean, stripTop: number, mid: number) {
    if (!isEff) {
      btn.style.removeProperty('top')
      btn.style.removeProperty('left')
      return
    }
    // an ancestor with layout containment can be the containing block of a fixed box: measure the origin it gives
    btn.style.top = '0px'
    btn.style.left = '0px'
    const o0 = btn.getBoundingClientRect()
    const pad = 16
    const bar = document.querySelector('.lf-topbar')
    const visTop = bar ? bar.getBoundingClientRect().bottom : 0
    const bw = o0.width || 32
    const bh = o0.height || 32
    const y = expanderTop(stripTop, visTop, window.innerHeight, bh, pad)
    const x = Math.min(Math.max(mid - bw / 2, pad / 2), Math.max(pad / 2, window.innerWidth - bw - pad / 2))
    btn.style.top = `${y - o0.top}px`
    btn.style.left = `${x - o0.left}px`
  }

  function place() {
    const panes = o.panes()
    const L = layer.getBoundingClientRect()
    handles.forEach((h, k) => {
      const a = panes[k]
      const b = panes[k + 1]
      if (!a || !b) {
        h.hidden = true
        return
      }
      h.hidden = false
      const ra = a.getBoundingClientRect()
      const rb = b.getBoundingClientRect()
      const gap = Math.max(0, rb.left - ra.right)
      const mid = ra.right + gap / 2
      let top = Math.min(ra.top, rb.top)
      let bot = Math.max(ra.bottom, rb.bottom)
      if (o.shell) {
        top = L.top
        bot = L.bottom
      }
      const isEff = eff(k)
      if (isEff && !o.shell) {
        // a collapsed strip is as tall as the whole work area, not as tall as the (hidden) pane
        const C = container.getBoundingClientRect()
        top = Math.min(top, C.top)
        bot = Math.max(bot, C.bottom)
      }
      h.style.left = `${isEff ? Math.max(mid - L.left, 18) : mid - L.left}px`
      h.style.top = `${top - L.top}px`
      h.style.height = `${Math.max(0, bot - top)}px`
      const l = limits(k)
      const px = curPx(k)
      const W = cw() || 1
      const now = isEff ? 0 : unit === 'px' ? px : (px / W) * 100
      const lo = unit === 'px' ? l[0] : (l[0] / W) * 100
      const hi = unit === 'px' ? l[1] : (l[1] / W) * 100
      h.setAttribute('aria-valuenow', String(Math.round(now)))
      h.setAttribute('aria-valuemin', String(Math.round(lo)))
      h.setAttribute('aria-valuemax', String(Math.round(hi)))
      const pn = sized === 'after' ? b : a
      if (!pn.id) pn.id = `${o.id}-pane-${k}`
      h.setAttribute('aria-controls', pn.id)
      const text = textNow()
      const name = o.labels?.[k] ?? ''
      h.setAttribute('aria-label', name || text.resize)
      const btn = h.querySelector('.lf-splitter__btn')
      if (btn) {
        placeExpander(btn as HTMLElement, isEff, top, L.left + Math.max(mid - L.left, 18))
        const label = `${isEff ? text.expand : text.collapse}: ${name}`
        btn.setAttribute('aria-label', label)
        btn.setAttribute('title', label)
        btn.setAttribute('aria-controls', pn.id)
        btn.setAttribute('aria-expanded', String(!isEff))
        ;(btn as HTMLElement).tabIndex = isEff ? 0 : -1
        h.classList.toggle('is-collapsed', isEff)
      }
    })
  }

  let raf = 0
  const later = () => {
    cancelAnimationFrame(raf)
    raf = requestAnimationFrame(() => {
      build()
      apply()
      place()
    })
  }
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(later) : null
  ro?.observe(container)
  window.addEventListener('scroll', later, true)
  window.addEventListener('resize', later)

  const self: SplitHandle = {
    refresh: () => {
      stored()
      build()
      apply()
      place()
    },
    place,
    set,
    toggle,
    reset: () => {
      for (let k = 0; k < vars.length; k++) {
        sizes[k] = null
        collapsed[k] = false
      }
      apply()
      place()
      persist()
    },
    handles: () => handles,
    state: () => ({ sizes: sizes.slice(), collapsed: { ...collapsed } }),
    destroy: () => {
      cancelAnimationFrame(raf)
      handles.splice(0).forEach((h) => h.remove())
      window.removeEventListener('scroll', later, true)
      window.removeEventListener('resize', later)
      ro?.disconnect()
      vars.forEach((v) => container.style.removeProperty(v))
    },
  }
  self.refresh()
  return self
}
