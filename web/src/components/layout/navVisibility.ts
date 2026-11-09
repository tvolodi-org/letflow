/** Which sidebar entries a user sees: a pure function of the entries, the user's permission check and the
 *  installed modules' import types. Presentation only: the server stays the authority for direct URLs.
 *  Fails closed: while /me/access is loading or failed, `can` is false and nothing gated shows. */
import type { Permission } from '@/auth/access'

export type NavGroup = 'work' | 'tenantAdmin' | 'platform'

export interface NavItem {
  to: string
  label: string
  /** Sidebar group; module entries (no group) go to Work. */
  group: NavGroup
  /** What the server enforces for the page's own calls (see the PR's element-to-permission table). */
  permission: Permission
  /** Also require the platform tenant (platform-only entries). */
  platformOnly?: boolean
  /** Build-time visibility switch, read when the nav is built (REQ-630). */
  enabled?: () => boolean
  /** Hidden when the user may import no type (REQ-675; per-type permission, T-1522). */
  needsImportTypes?: boolean
}

export interface NavGroupDef {
  id: NavGroup
  label: string
}

export interface VisibleNavGroup extends NavGroupDef {
  items: NavItem[]
}

export function visibleNavGroups(args: {
  groups: NavGroupDef[]
  items: NavItem[]
  moduleItems: { to: string; label: string; permission: string; platformOnly?: boolean }[]
  can: (permission: string) => boolean
  isPlatformTenant: boolean
  importTypeCount: number
}): VisibleNavGroup[] {
  const all: (Omit<NavItem, 'permission'> & { permission: string })[] = [...args.items, ...args.moduleItems.map((n) => ({ ...n, group: 'work' as const }))]
  const visible = all.filter(
    (n) =>
      args.can(n.permission) &&
      (!n.enabled || n.enabled()) &&
      (!n.needsImportTypes || args.importTypeCount > 0) &&
      (!n.platformOnly || args.isPlatformTenant),
  )
  return args.groups
    .map((g) => ({ ...g, items: visible.filter((n) => n.group === g.id) }))
    .filter((g) => g.items.length > 0)
}
