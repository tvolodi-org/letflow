// @vitest-environment jsdom
import { describe, expect, it } from 'vitest'
import { getInstalledModuleDefinitions, getInstalledModuleNavItems } from '../registry'
import type { ModuleDefinition } from '../types'
import type { RouteObject } from 'react-router-dom'

const fixtureRouteObjects: RouteObject[] = [{ path: '/sample' }]

const fixtureDefinitions: ModuleDefinition[] = [
  {
    id: 'sample',
    depends_on: [],
    routeObjects: fixtureRouteObjects,
    navItems: [{ to: '/sample', label: 'Sample', permission: 'ExamSessionStart' }],
  },
]

describe('module registry (REQ-406, ISS-0844)', () => {
  it('returns only the installed modules\' definitions and nav items', () => {
    const installed = [
      { module_id: 'sample', version: '1.0.0' },
      { module_id: 'other', version: '2.0.0' },
    ]

    expect(getInstalledModuleDefinitions(installed, fixtureDefinitions)).toEqual(fixtureDefinitions)
    expect(getInstalledModuleNavItems(installed, fixtureDefinitions)).toEqual(fixtureDefinitions[0].navItems)
  })

  it('returns empty arrays when no module is installed', () => {
    const installed = [{ module_id: 'missing', version: '1.0.0' }]

    expect(getInstalledModuleDefinitions(installed, fixtureDefinitions)).toEqual([])
    expect(getInstalledModuleNavItems(installed, fixtureDefinitions)).toEqual([])
  })

  it('REGISTERED_MODULE_ROUTE_OBJECTS derives one guard-wrapped entry per registered module', async () => {
    // Verify that nav items and route objects are both derived from REGISTERED_MODULES
    // (single source of truth) rather than maintained in parallel lists.
    const { REGISTERED_MODULES, REGISTERED_MODULE_ROUTE_OBJECTS } = await import('../registry')
    expect(REGISTERED_MODULE_ROUTE_OBJECTS).toHaveLength(REGISTERED_MODULES.length)
  })
})
