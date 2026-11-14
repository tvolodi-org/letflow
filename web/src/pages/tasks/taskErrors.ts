/** taskErrors — T-1380. A claim / complete refusal as the catalog text; the server's wording and ids never reach the screen. */
import { isSeparationOfDuties } from '@/api/client'
import type { ActionKind } from './taskInboxModel'
import type { TaskMessages } from './taskMessages'

function bodyText(err: unknown): string {
  const e = err as { message?: unknown; details?: Record<string, unknown> } | null
  const d = e?.details ?? {}
  return [d['detail'], d['reason'], d['error'], e?.message].filter((x): x is string => typeof x === 'string').join(' ').toLowerCase()
}

/** Known problem types a worker can hit. Retrying cannot help any of them, so none falls to the generic "try again". */
function problemType(err: unknown): { status?: unknown; type: string; code: string } {
  const e = err as { status?: unknown; code?: unknown; details?: Record<string, unknown> } | null
  const d = e?.details ?? {}
  return {
    status: e?.status,
    type: typeof e?.code === 'string' ? e.code : typeof d['type'] === 'string' ? d['type'] : '',
    code: typeof d['code'] === 'string' ? d['code'] : '',
  }
}

export function taskErrorText(err: unknown, kind: ActionKind, m: TaskMessages): string {
  if (isSeparationOfDuties(err)) return m.sod[kind]
  const pt = problemType(err)
  if (pt.type.endsWith('module-upgrade-required') || pt.code === 'upgrade_required' || pt.code === 'module_upgrade_required') {
    return m.errModuleUpgrade
  }
  if (pt.status === 409 && (pt.type.endsWith('/conflict') || pt.type.endsWith('record-version-conflict'))) return m.errConflict
  const text = bodyText(err)
  if (text.includes('insufficient_stock') || text.includes('insufficient stock')) return m.errInsufficientStock
  if (text.includes('location_frozen')) return m.errLocationFrozen
  if (text.includes('different user')) return m.errAlreadyTaken
  if (text.includes('not pending')) return m.errNotPending
  if (text.includes('role') || text.includes('group')) return m.errNotHeld
  if (pt.status === 403) return m.errForbidden
  return m.errGeneric
}
