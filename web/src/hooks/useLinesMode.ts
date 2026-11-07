/** T-1448 — the remembered entry mode of the lines editor (`screens.<id>.linesMode` of the `ui.layout` preference).
 *  Falls back to localStorage when the preference is not loaded or cannot be saved. The write merges the screen's other keys
 *  (panes, cols) and the other screens: the server replaces the whole document. */
import { useCallback, useState } from 'react'
import type { LeMode } from '@/components/ui/lines/types'
import { useUiLayout } from './useUiLayout'

const STORAGE_PREFIX = 'lf.linesMode.'

function readLocal(screenId: string): LeMode | null {
  try {
    const v = localStorage.getItem(STORAGE_PREFIX + screenId)
    return v === 'grid' || v === 'form' ? v : null
  } catch {
    return null
  }
}

export function useLinesMode(screenId: string): [LeMode, (m: LeMode) => void] {
  const { layout, save } = useUiLayout()
  const [local, setLocal] = useState<LeMode | null>(() => readLocal(screenId))
  const stored = layout?.screens[screenId]?.linesMode
  const mode: LeMode = local ?? stored ?? 'grid'

  const set = useCallback(
    (m: LeMode) => {
      setLocal(m)
      try {
        localStorage.setItem(STORAGE_PREFIX + screenId, m)
      } catch {
        /* storage unavailable: the preference below is the only copy */
      }
      if (layout) {
        const screen = layout.screens[screenId] ?? {}
        void save({ ...layout, screens: { ...layout.screens, [screenId]: { ...screen, linesMode: m } } }).catch(() => undefined)
      }
    },
    [layout, save, screenId],
  )
  return [mode, set]
}
