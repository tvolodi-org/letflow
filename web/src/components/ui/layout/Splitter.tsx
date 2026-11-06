/** T-1442 — React side of LFSplit: `useSplit` attaches the engine (`splitEngine.ts`) to a grid container and keeps it in
 *  step with renders; `SplitWrap` is the `div.lf-splitwrap` + `div.lf-split-layer` pair the handles live in.
 *  Usage: <SplitWrap layerRef={layerRef}><div ref={gridRef} className="lf-jrn">...</div></SplitWrap>, then
 *  useSplit(gridRef, layerRef, { id, screen, vars, unit, panes: () => [...], ... }). No per-screen CSS. */
import { useEffect, useRef, type ReactNode, type RefObject } from 'react'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { attachSplit, type SplitHandle, type SplitOptions } from './splitEngine'
import { useLayoutMessages } from './layoutMessages'

export type UseSplitOptions = Omit<SplitOptions, 'store' | 'layer' | 'text'>

export function SplitWrap({ layerRef, children }: { layerRef: RefObject<HTMLDivElement>; children: ReactNode }) {
  return (
    <div className="lf-splitwrap">
      {children}
      <div className="lf-split-layer" ref={layerRef} />
    </div>
  )
}

/** Attach once per container; the latest options are read on every use, so labels and callbacks may change per render. */
export function useSplit(
  containerRef: RefObject<HTMLElement>,
  layerRef: RefObject<HTMLElement>,
  opts: UseSplitOptions,
): RefObject<SplitHandle | null> {
  const store = useLayoutPrefs()
  const m = useLayoutMessages()
  const live = useRef({ ...opts, text: { resize: m.resize, collapse: m.collapse, expand: m.expand } })
  live.current = { ...opts, text: { resize: m.resize, collapse: m.collapse, expand: m.expand } }
  const handle = useRef<SplitHandle | null>(null)

  useEffect(() => {
    const container = containerRef.current
    const layer = layerRef.current
    if (!container || !layer) return
    const o = new Proxy({} as SplitOptions, {
      get: (_t, k: string) => (k === 'store' ? store : k === 'layer' ? layer : (live.current as unknown as Record<string, unknown>)[k]),
    })
    const h = attachSplit(container, o)
    handle.current = h
    // the stored layout may arrive after the first paint (server value)
    const off = store.subscribe(() => h.refresh())
    return () => {
      off()
      h.destroy()
      handle.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- attach once per container/store/screen/split id
  }, [store, containerRef, layerRef, opts.id, opts.screen])

  // after every render: re-read the sizes, rebuild handles for the panes that are shown, re-place
  useEffect(() => {
    handle.current?.refresh()
  })
  return handle
}
