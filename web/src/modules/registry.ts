/** web/src/modules/registry.ts — ISS-0844 / REQ-406
 *
 *  The ONE sanctioned importer of module code (0039 D3). Holds ONE list of
 *  registered module definitions and derives both route objects and nav items
 *  from it. Registry wraps each module's routeObjects in a ModuleGuard so
 *  module code itself never imports the guard (0039 D3).
 */
import { createElement } from 'react'
import type { InstalledModule, ModuleDefinition, ModuleNavItem } from './types'
import { examModuleDefinition } from './exam/index'
import { orgModuleDefinition } from './org/index'
import { locationsModuleDefinition } from './locations/index'
import { codesModuleDefinition } from './codes/index'
import { ModuleGuard } from '@/components/routing/ModuleGuard'
import type { RouteObject } from 'react-router-dom'

export const REGISTERED_MODULES: ModuleDefinition[] = [
  examModuleDefinition,
  orgModuleDefinition,
  locationsModuleDefinition,
  codesModuleDefinition,
]

/** All registered module RouteObjects wrapped in ModuleGuard, for inclusion
 *  in the static router. Router.tsx spreads this array into the authenticated
 *  route's children. Each entry's guard checks installed_modules at render
 *  time; a module path for an uninstalled tenant renders NotFoundPage. */
export const REGISTERED_MODULE_ROUTE_OBJECTS: RouteObject[] =
  REGISTERED_MODULES.map((mod) => ({
    element: createElement(ModuleGuard, { moduleId: mod.id }),
    children: mod.routeObjects,
  }))

export function getInstalledModuleDefinitions(
  installedModules: InstalledModule[],
  definitions: ModuleDefinition[] = REGISTERED_MODULES,
): ModuleDefinition[] {
  const installedIds = new Set(installedModules.map((module) => module.module_id))
  return definitions.filter((definition) => installedIds.has(definition.id))
}

export function getInstalledModuleNavItems(
  installedModules: InstalledModule[],
  definitions: ModuleDefinition[] = REGISTERED_MODULES,
): ModuleNavItem[] {
  return getInstalledModuleDefinitions(installedModules, definitions).flatMap((definition) => definition.navItems)
}
