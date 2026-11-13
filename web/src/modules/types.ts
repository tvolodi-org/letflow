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

/** An entity type the module can import from an Excel file (REQ-675); the label per locale comes from
 *  the module's own message file. Core code lists these without naming a module (0039 D3). */
export interface ModuleImportType {
  entityType: string
  /** The module permission the server needs for this type besides EntitiesRecordsImport (a plain string,
   *  like ModuleNavItem.permission). The menu and the type picker show the type only to a holder. */
  permission: string
  labels: Record<'en' | 'ru' | 'kk', string>
}

export type ModuleReportGroup = NonNullable<ModuleDefinition['reportGroup']> & { moduleId: string }

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
  /** Importable entity types, parents first (REQ-675). */
  importTypes?: ModuleImportType[]
  /** T-1874: the Reports page groups saved reports by module; saved views carry no module field, so the module
   *  claims every entity type whose name starts with `entityTypePrefix` (the backend prefixes a module's types). */
  reportGroup?: { entityTypePrefix: string; labels: Record<'en' | 'ru' | 'kk', string> }
}
