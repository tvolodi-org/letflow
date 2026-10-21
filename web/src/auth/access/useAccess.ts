import { useContext, useMemo } from 'react'
import { AccessContext } from './AccessContext'
import { can, canManageTenants, isCandidate, isPlatformTenant, rolesOf } from './access'
import type { AccessState, Permission } from './types'

export interface UseAccess {
  state: AccessState
  isReady: boolean
  isLoading: boolean
  isError: boolean
  /** False unless the state is `ready` and the server reported the permission. */
  can: (permission: Permission) => boolean
  isPlatformTenant: boolean
  canManageTenants: boolean
  isCandidate: boolean
  roles: string[]
  retry: () => void
}

export function useAccess(): UseAccess {
  const state = useContext(AccessContext)
  return useMemo(
    () => ({
      state,
      isReady: state.status === 'ready',
      isLoading: state.status === 'loading',
      isError: state.status === 'error',
      can: (permission: Permission) => can(state, permission),
      isPlatformTenant: isPlatformTenant(state),
      canManageTenants: canManageTenants(state),
      isCandidate: isCandidate(state),
      roles: rolesOf(state),
      retry: () => {
        if (state.status === 'error') state.retry()
      },
    }),
    [state],
  )
}
