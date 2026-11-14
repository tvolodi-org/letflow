/** useListSelection — T-1946. The one selection rule of every list + detail screen, so no screen resets it by hand:
 *  after CREATE the new record is selected (its detail opens), after EDIT the same record stays selected (the list is
 *  not touched, so its scroll position stays), after DELETE (retire) the selection clears (empty state).
 *  A screen passes the id the server returned to `saved`; `saved(null)` after a create with no id falls back to close. */
import { useCallback, useState } from 'react'

export type ListSaveOutcome =
  | { kind: 'create'; id: string | null }
  | { kind: 'edit' }
  | { kind: 'delete' }

/** Pure rule: the selected id after a save. */
export function selectionAfterSave(current: string | null, outcome: ListSaveOutcome): string | null {
  if (outcome.kind === 'create') return outcome.id
  if (outcome.kind === 'edit') return current
  return null
}

/** `C` is the create context a screen needs (for example the parent node); `true` when it needs none. */
export function useListSelection<C = true>(initialId: string | null = null, initialCreating: C | null = null) {
  const [selectedId, setSelectedId] = useState<string | null>(initialId)
  const [creating, setCreating] = useState<C | null>(initialCreating)

  const select = useCallback((id: string) => {
    setCreating(null)
    setSelectedId(id)
  }, [])
  const startCreate = useCallback((context: C = true as C) => {
    setSelectedId(null)
    setCreating(context)
  }, [])
  const close = useCallback(() => {
    setCreating(null)
    setSelectedId(null)
  }, [])
  /** Call with the save result: create selects `id`, edit keeps the selection, delete clears it. */
  const saved = useCallback((outcome: ListSaveOutcome) => {
    setCreating(null)
    setSelectedId((current) => selectionAfterSave(current, outcome))
  }, [])

  return { selectedId, creating, select, startCreate, close, saved }
}
