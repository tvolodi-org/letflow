/** REQ-630 — maps an uninstall/reactivate failure to a safe view model.
 *
 *  Every 404 gets one text, whatever the cause (unknown module, not installed,
 *  server flag off): the answers must not be told apart. A 409 is branched on
 *  `details.code` (the client keeps the whole body there; `ApiError.code` is
 *  the problem type URL).
 */

export const NOT_FOUND_MESSAGE = 'Module not found, or this action is not available'
export const FORBIDDEN_MESSAGE = 'You do not have access to this area. Contact your tenant administrator.'
export const UPGRADE_MESSAGE = 'This module needs an upgrade before this action can be done.'
export const GENERIC_MESSAGE = 'Something went wrong. Try again.'

export type ModuleTransitionError =
  | { kind: 'message'; text: string }
  | { kind: 'open_work'; openInstances: number; openTasks: number }
  | { kind: 'dependents'; dependents: string[] }

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

const generic: ModuleTransitionError = { kind: 'message', text: GENERIC_MESSAGE }

export function describeModuleTransitionError(err: unknown): ModuleTransitionError {
  const e = err as { status?: unknown; details?: unknown } | null | undefined
  if (!e || typeof e !== 'object' || typeof e.status !== 'number') return generic
  const details = isRecord(e.details) ? e.details : {}
  if (e.status === 404) return { kind: 'message', text: NOT_FOUND_MESSAGE }
  if (e.status === 403) return { kind: 'message', text: FORBIDDEN_MESSAGE }
  if (e.status === 409) {
    if (details.code === 'open_work_exists') {
      const { open_instances: i, open_tasks: t } = details
      if (typeof i === 'number' && Number.isFinite(i) && typeof t === 'number' && Number.isFinite(t)) {
        return { kind: 'open_work', openInstances: i, openTasks: t }
      }
      return generic
    }
    if (details.code === 'dependents_installed') {
      const list = Array.isArray(details.dependents)
        ? details.dependents.filter((d): d is string => typeof d === 'string')
        : []
      return list.length > 0 ? { kind: 'dependents', dependents: list } : generic
    }
    if (details.code === 'upgrade_required') return { kind: 'message', text: UPGRADE_MESSAGE }
    return generic
  }
  if (e.status === 422 && typeof details.detail === 'string') return { kind: 'message', text: details.detail }
  return generic
}
