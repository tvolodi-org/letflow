/** platformModuleRollouts -- T-1660 (fleet driver part 3): API client of the module rollout operator screen.
 *  Field names are copied from `rollout_map/1` and `outcome_map/1` in `lib/letflow/routers/platform_module_rollouts.ex`;
 *  no renaming. The four routes are the whole surface (`:ModuleRolloutsManage`, platform tenant only, enforced by the server).
 */
import { client } from './client'

export type ModuleRolloutStatus = 'running' | 'completed' | 'halted'
export type ModuleOutcomeStatus = 'pending' | 'running' | 'succeeded' | 'failed' | 'skipped' | 'outside_window'

export interface ModuleRollout {
  id: string
  module_id: string
  to_version: string
  status: ModuleRolloutStatus
  halt_after: number
  consecutive_failures: number
  started_at: string | null
  completed_at: string | null
  halted_at: string | null
}

export interface ModuleRolloutOutcome {
  tenant_id: string
  status: ModuleOutcomeStatus
  error_code: string | null
  plan_hash: string | null
  attempted_at: string | null
  completed_at: string | null
}

export interface ModuleRolloutResult {
  rollout: ModuleRollout
  outcomes: ModuleRolloutOutcome[]
}

export type ModuleOutcomeCounts = Partial<Record<ModuleOutcomeStatus, number>>

export interface ModuleRolloutListItem {
  rollout: ModuleRollout
  counts: ModuleOutcomeCounts
}

export interface ModuleRolloutList {
  rollouts: ModuleRolloutListItem[]
}

const BASE = '/api/v1/platform-module-rollouts'

export const platformModuleRolloutsApi = {
  list: () => client.get<ModuleRolloutList>(BASE),
  status: (id: string) => client.get<ModuleRolloutResult>(`${BASE}/${encodeURIComponent(id)}`),
  start: (moduleId: string) => client.post<ModuleRolloutResult>(BASE, { module_id: moduleId }),
  resume: (id: string) => client.post<ModuleRolloutResult>(`${BASE}/${encodeURIComponent(id)}/resume`, {}),
}
