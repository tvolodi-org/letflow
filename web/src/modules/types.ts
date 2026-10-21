import type { RouteObject } from 'react-router-dom'

export interface InstalledModule {
  module_id: string
  version: string
}

export interface ModuleNavItem {
  to: string
  label: string
  /** A permission atom the server reports in /me/access. A plain string: module permissions are
   *  not in the core permission set. */
  permission: string
  platformOnly?: boolean
}

/** A module's static definition. Each module's `web/src/modules/<id>/index.ts`
 *  exports exactly one of these. `registry.ts` is the only file that imports
 *  module code (0039 D3); it wraps `routeObjects` in a `ModuleGuard` when
 *  building the router's module route list. */
export interface ModuleDefinition {
  id: string
  depends_on?: string[]
  /** Plain route objects — no guard wrapper. Registry wraps them. */
  routeObjects: RouteObject[]
  navItems: ModuleNavItem[]
}
