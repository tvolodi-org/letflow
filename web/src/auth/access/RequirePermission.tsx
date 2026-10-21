import type { ReactNode } from 'react'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { useAccess, type UseAccess } from './useAccess'
import type { Permission } from './types'

interface Props {
  permission: Permission
  /** Also require the platform tenant (platform-only pages). */
  platformOnly?: boolean
  /** Rendered instead of `PermissionDenied` when access is ready but not granted. */
  fallback?: ReactNode
  children: ReactNode
}

/**
 * Page guard. Renders nothing of `children` until /me/access has loaded and granted the
 * permission: a neutral loading state, a retry notice on failure, `PermissionDenied` otherwise.
 */
export function RequirePermission({ permission, platformOnly = false, fallback, children }: Props) {
  const access = useAccess()
  if (!access.isReady) return <AccessPending access={access} />
  if (!access.can(permission) || (platformOnly && !access.isPlatformTenant)) {
    return <>{fallback ?? <PermissionDenied />}</>
  }
  return <>{children}</>
}

/**
 * For pages that keep their own denied view: the neutral state to render while /me/access is
 * not ready (`if (!access.isReady) return <AccessPending access={access} />`).
 */
export function AccessPending({ access }: { access: Pick<UseAccess, 'isLoading' | 'retry'> }) {
  if (access.isLoading) return <div data-testid="access-loading">Loading…</div>
  return (
    <div data-testid="access-error" role="alert">
      <p>Could not load your permissions.</p>
      <button type="button" onClick={access.retry}>Retry</button>
    </div>
  )
}
