/** useDiagramDraft — T-1563. The edit draft of the process designer: a DefinitionGraph plus bounded undo/redo
 *  (editHistory), the dirty flag and the `updated_at` seen when editing started (best-effort stale check on save).
 *  Every change goes through graphEdit; this hook never builds graph nodes or edges itself. */
import { useCallback, useState } from 'react'
import type { DefinitionGraph } from '@/types/api'
import { canRedo, canUndo, initialHistory, push, redo as redoH, reset as resetH, undo as undoH, type History } from '@/utils/canvas/editHistory'
import type { EditRefusal, EditResult } from '@/utils/canvas/graphEdit'

export interface DiagramDraft {
  graph: DefinitionGraph
  dirty: boolean
  canUndo: boolean
  canRedo: boolean
  seededAt: string | null
  /** Applies a graphEdit result; a refusal changes nothing and is returned. */
  apply: (result: EditResult, coalesceKey?: string) => EditRefusal | null
  /** Replaces the graph (for example after the layout filled in missing positions) as one step. */
  setGraph: (graph: DefinitionGraph, coalesceKey?: string) => void
  undo: () => void
  redo: () => void
  /** Forget all steps; `graph` becomes the clean base (after a save or a discard). */
  reset: (graph: DefinitionGraph, seededAt?: string | null) => void
}

export function useDiagramDraft(seed: DefinitionGraph, seededAtInit: string | null = null): DiagramDraft {
  const [h, setH] = useState<History<DefinitionGraph>>(() => initialHistory(seed))
  const [base, setBase] = useState<DefinitionGraph>(seed)
  const [seededAt, setSeededAt] = useState<string | null>(seededAtInit)

  const apply = useCallback((result: EditResult, coalesceKey?: string): EditRefusal | null => {
    if (!result.ok) return result.reason
    setH((cur) => push(cur, result.graph, coalesceKey))
    return null
  }, [])
  const setGraph = useCallback((graph: DefinitionGraph, coalesceKey?: string) => setH((cur) => push(cur, graph, coalesceKey)), [])
  const undo = useCallback(() => setH((cur) => undoH(cur)), [])
  const redo = useCallback(() => setH((cur) => redoH(cur)), [])
  const reset = useCallback((graph: DefinitionGraph, at?: string | null) => {
    setH(resetH(graph))
    setBase(graph)
    if (at !== undefined) setSeededAt(at)
  }, [])

  return { graph: h.present, dirty: h.present !== base, canUndo: canUndo(h), canRedo: canRedo(h), seededAt, apply, setGraph, undo, redo, reset }
}
