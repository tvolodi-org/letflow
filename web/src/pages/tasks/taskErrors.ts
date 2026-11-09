/** taskErrors — T-1380. A claim / complete refusal as the catalog text; the server's wording and ids never reach the screen. */
import { isSeparationOfDuties } from '@/api/client'
import type { ActionKind } from './taskInboxModel'
import type { TaskMessages } from './taskMessages'

function bodyText(err: unknown): string {
  const e = err as { message?: unknown; details?: Record<string, unknown> } | null
  const d = e?.details ?? {}
  return [d['detail'], d['reason'], d['error'], e?.message].filter((x): x is string => typeof x === 'string').join(' ').toLowerCase()
}

export function taskErrorText(err: unknown, kind: ActionKind, m: TaskMessages): string {
  if (isSeparationOfDuties(err)) return m.sod[kind]
  const text = bodyText(err)
  if (text.includes('insufficient_stock') || text.includes('insufficient stock')) return m.errInsufficientStock
  if (text.includes('location_frozen')) return m.errLocationFrozen
  if (text.includes('different user')) return m.errAlreadyTaken
  if (text.includes('not pending')) return m.errNotPending
  if (text.includes('role') || text.includes('group')) return m.errNotHeld
  return m.errGeneric
}
