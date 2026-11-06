/** useVirtualRows — fixed-height row window over a scroll container. Only `first..last` rows are mounted; the caller
 *  renders two spacer rows of `padTop`/`padBottom` pixels. One animation frame per scroll burst; state changes only when
 *  the first or last row changes. */
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'

/** Row height from the CSS token (never a literal in TSX); the fallback is only for a DOM without styles. */
export function readRowHeight(el: Element | null, token: string, fallback: number): number {
  if (!el || typeof getComputedStyle !== 'function') return fallback
  const raw = getComputedStyle(el).getPropertyValue(token).trim()
  const n = parseFloat(raw)
  return Number.isFinite(n) && n > 0 ? n : fallback
}

export interface VirtualWindow {
  first: number
  last: number // exclusive
  padTop: number
  padBottom: number
}

export function computeWindow(count: number, rowH: number, scrollTop: number, viewH: number, overscan: number): VirtualWindow {
  const h = viewH > 0 ? viewH : rowH * 12
  const first = Math.max(0, Math.floor(scrollTop / rowH) - overscan)
  const last = Math.min(count, Math.ceil((scrollTop + h) / rowH) + overscan)
  return { first, last, padTop: first * rowH, padBottom: Math.max(0, (count - last) * rowH) }
}

export function useVirtualRows(count: number, token: string, fallbackH: number, overscan = 8) {
  const ref = useRef<HTMLDivElement | null>(null)
  const [rowH, setRowH] = useState(fallbackH)
  const [pos, setPos] = useState({ top: 0, h: 0 })
  const raf = useRef(0)

  useLayoutEffect(() => {
    setRowH(readRowHeight(ref.current, token, fallbackH))
    setPos({ top: ref.current?.scrollTop ?? 0, h: ref.current?.clientHeight ?? 0 })
  }, [token, fallbackH])

  const measure = useCallback(() => {
    raf.current = 0
    const el = ref.current
    if (!el) return
    const w = computeWindow(count, rowH, el.scrollTop, el.clientHeight, overscan)
    setPos((p) => {
      const a = computeWindow(count, rowH, p.top, p.h, overscan)
      return a.first === w.first && a.last === w.last && p.h === el.clientHeight ? p : { top: el.scrollTop, h: el.clientHeight }
    })
  }, [count, rowH, overscan])

  const onScroll = useCallback(() => {
    if (raf.current) return
    raf.current = typeof requestAnimationFrame === 'function' ? requestAnimationFrame(measure) : (measure(), 0)
  }, [measure])

  useEffect(() => {
    measure()
    return () => {
      if (raf.current && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(raf.current)
      raf.current = 0
    }
  }, [measure])

  const scrollToRow = useCallback(
    (i: number) => {
      const el = ref.current
      if (!el) return
      const top = i * rowH
      const view = el.clientHeight || rowH * 12
      if (top < el.scrollTop) el.scrollTop = top
      else if (top + rowH > el.scrollTop + view - rowH * 2) el.scrollTop = Math.max(0, top - view / 2)
      setPos({ top: el.scrollTop, h: el.clientHeight })
    },
    [rowH],
  )

  const win = computeWindow(count, rowH, pos.top, pos.h, overscan)
  return { ref, win, rowH, onScroll, scrollToRow }
}
