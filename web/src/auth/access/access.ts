/** Pure access decisions over an `AccessState`. Everything is false unless the state is `ready`. */

import { P, type AccessInfo, type AccessState, type Permission } from './types'

function infoOf(state: AccessState): AccessInfo | null {
  return state.status === 'ready' ? state.info : null
}

export function can(state: AccessState, permission: Permission): boolean {
  return infoOf(state)?.permissions.includes(permission) ?? false
}

export function isPlatformTenant(state: AccessState): boolean {
  return infoOf(state)?.platform_tenant === true
}

/** Platform authority: the tenant-management permission, held in the platform tenant. */
export function canManageTenants(state: AccessState): boolean {
  return isPlatformTenant(state) && can(state, P.TenantsManage)
}

/** True for a caller holding the candidate (exam taker) role. Only for the denied-page link:
 *  every other decision is a permission. */
export function isCandidate(state: AccessState): boolean {
  const info = infoOf(state)
  return info?.roles.includes('CANDIDATE') ?? false
}

export function rolesOf(state: AccessState): string[] {
  return infoOf(state)?.roles ?? []
}
