/** moduleRolloutsModel -- T-1660: pure rules of the module rollout screen. */
import type { ModuleRollout, ModuleRolloutOutcome } from '@/api/platformModuleRollouts'

/** Mirrors `Fleet @stale_minutes` (lib/letflow/module_upgrade/fleet.ex): a `running` outcome older than this is a
 *  crashed caller's claim and Resume may take it again. The server stays the authority. */
export const STALE_RUNNING_MINUTES = 15

/** Whether Resume is offered. Follows `Fleet.resume/3` whatever the rollout status (it reopens `completed` rollouts too):
 *  halted; or any failed / pending / outside_window outcome; or a `running` outcome whose attempt is older than 15 minutes. */
export function canResume(rollout: Pick<ModuleRollout, 'status'>, outcomes: Pick<ModuleRolloutOutcome, 'status' | 'attempted_at'>[], now: Date): boolean {
  if (rollout.status === 'halted') return true
  const limit = now.getTime() - STALE_RUNNING_MINUTES * 60_000
  return outcomes.some((o) => {
    if (o.status === 'failed' || o.status === 'pending' || o.status === 'outside_window') return true
    if (o.status !== 'running' || !o.attempted_at) return false
    const t = Date.parse(o.attempted_at)
    return Number.isFinite(t) && t < limit
  })
}
