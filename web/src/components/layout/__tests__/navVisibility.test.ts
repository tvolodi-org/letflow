// @vitest-environment jsdom
/**
 * T-1522 / D-114(1): the role-based sidebar. The visible entries are computed by `visibleNavGroups` from the
 * entries' own `permission` and the user's permission set. The sets come from the server's effective permission
 * matrix (priv/permission_matrix/effective.golden, module-aware), not from a hand-kept list. A role is picked by
 * its access fixture key; no role name is written here (no-role-literals guard).
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ACCESS_FIXTURES, type AccessFixtureName } from '@/auth/access/fixtures'
import { NAV_GROUPS, NAV_ITEMS } from '../AppShell'
import { visibleNavGroups } from '../navVisibility'
import { NAV_ROLE_PERMISSIONS } from '@/dev/harness/navRoleAccess'
import { REGISTERED_MODULES, getImportTypesFor, getInstalledModuleNavItems } from '@/modules/registry'

const GOLDEN = readFileSync(join(__dirname, '..', '..', '..', '..', '..', 'priv', 'permission_matrix', 'effective.golden'), 'utf8')

/** role -> permissions allowed, and every permission atom of the matrix. */
function parseGolden(text: string) {
  const byRole: Record<string, Set<string>> = {}
  const atoms = new Set<string>()
  for (const line of text.split(/\r?\n/)) {
    if (!line || line.startsWith('#')) continue
    const [role, permission, allowed] = line.split(' ')
    atoms.add(permission)
    byRole[role] ??= new Set()
    if (allowed === 'true') byRole[role].add(permission)
  }
  return { byRole, atoms }
}
const golden = parseGolden(GOLDEN)

const ALL_INSTALLED = REGISTERED_MODULES.map((m) => ({ module_id: m.id, version: '1' }))

function setFor(fixture: AccessFixtureName): Set<string> {
  return golden.byRole[ACCESS_FIXTURES[fixture].roles[0]]
}

function view(permissions: Set<string>, isPlatformTenant = false) {
  const can = (p: string) => permissions.has(p)
  const importTypes = getImportTypesFor(ALL_INSTALLED, can)
  const groups = visibleNavGroups({
    groups: NAV_GROUPS,
    items: NAV_ITEMS,
    moduleItems: getInstalledModuleNavItems(ALL_INSTALLED),
    can,
    isPlatformTenant,
    importTypeCount: importTypes.length,
  })
  return {
    groups: groups.map((g) => g.id),
    labels: groups.flatMap((g) => g.items.map((i) => i.label)),
    importTypes: importTypes.map((t) => t.entityType),
    items: groups.flatMap((g) => g.items),
  }
}

describe('role-based sidebar (golden-backed)', () => {
  it('N1 tenant admin: every tenant entry, work and tenant administration groups, all eleven import types', () => {
    const v = view(setFor('tenantAdmin'))
    expect(v.groups).toEqual(['work', 'tenantAdmin'])
    expect(v.labels).toEqual([
      'Instances', 'My Tasks', 'Definitions', 'Exams', 'Question Bank', 'Grading', 'Exam builder',
      'Legal companies', 'Sites', 'Org units', 'Positions', 'Employees', 'Locations', 'Location links',
      'Codes', 'Items', 'Lots', 'Stock documents', 'Balances', 'Movements', 'Counts',
      'Asset cards', 'Asset documents', 'Asset balances', 'Asset movements',
      'Promotion Reviews', 'DLQ', 'Webhooks', 'Users', 'Groups', 'Tokens', 'Audit', 'Print Templates',
      'Import data', 'Metrics', 'Solution Packs',
    ])
    expect(v.importTypes).toEqual([
      'org_unit', 'org_position', 'org_employee', 'location_node',
      'catalog_uom', 'catalog_item', 'catalog_counterparty', 'catalog_lot', 'stock_opening_line',
      'assets_card', 'assets_opening_line',
    ])
  })

  it('N2 storekeeper: stock screens and My Tasks; Import data with exactly stock_opening_line; no org/users entry', () => {
    const v = view(setFor('storekeeper'))
    expect(v.groups).toEqual(['work', 'tenantAdmin'])
    expect(v.labels).toEqual(['My Tasks', 'Items', 'Stock documents', 'Balances', 'Movements', 'Counts', 'Import data'])
    expect(v.importTypes).toEqual(['stock_opening_line'])
  })

  it('N2b a role holding the import permission but no type permission loses Import data', () => {
    const v = view(new Set(['EntitiesRecordsImport', 'TasksRead']))
    expect(v.labels).toEqual(['My Tasks'])
    expect(v.importTypes).toEqual([])
  })

  it('N3 task worker: only the Work group with Instances, My Tasks, Definitions', () => {
    const v = view(setFor('taskWorker'))
    expect(v.groups).toEqual(['work'])
    expect(v.labels).toEqual(['Instances', 'My Tasks', 'Definitions'])
  })

  it('N4 scoped users (custom permission sets): exactly the entries their atoms allow', () => {
    expect(view(new Set(['TasksRead', 'TasksComplete', 'EntitiesQuery'])).labels).toEqual(['My Tasks'])
    expect(view(new Set(['StockRead'])).labels).toEqual(['Items', 'Stock documents', 'Balances', 'Movements', 'Counts'])
    expect(view(new Set()).labels).toEqual([])
  })

  it('N5 a group with no visible entry is hidden', () => {
    const v = view(new Set(['TasksRead']))
    expect(v.groups).toEqual(['work'])
  })

  it('N6 while access is loading or failed (can is false) nothing gated shows', () => {
    const v = view(new Set())
    expect(v.groups).toEqual([])
    expect(v.labels).toEqual([])
  })

  it('N6b platform-only entries need the platform tenant as well as the permission', () => {
    const perms = setFor('platformAdmin')
    expect(view(perms, false).groups).not.toContain('platform')
    expect(view(perms, true).groups).toContain('platform')
  })

  it('N7 for each role, every visible entry carries a permission that role holds (no entry leads to a refused page)', () => {
    for (const name of Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]) {
      const perms = setFor(name)
      const isPlatform = ACCESS_FIXTURES[name].platform_tenant
      for (const item of view(perms, isPlatform).items) {
        expect(perms.has(item.permission), `${name}: ${item.label} needs ${item.permission}`).toBe(true)
        if (item.platformOnly) expect(isPlatform, `${name}: ${item.label} is platform-only`).toBe(true)
      }
    }
  })

  it('N8 every permission atom a nav entry or import type names exists in the permission matrix', () => {
    const named = [
      ...NAV_ITEMS.map((n) => n.permission as string),
      ...REGISTERED_MODULES.flatMap((m) => m.navItems.map((n) => n.permission)),
      ...REGISTERED_MODULES.flatMap((m) => (m.importTypes ?? []).map((t) => t.permission)),
    ]
    for (const atom of named) expect(golden.atoms.has(atom), `unknown permission atom ${atom}`).toBe(true)
  })

  it('N9 the role screens\' access sets equal the permission matrix (no drift)', () => {
    const pairs = [['admin', 'tenantAdmin'], ['storekeeper', 'storekeeper'], ['worker', 'taskWorker']] as const
    for (const [screen, fixture] of pairs) {
      expect([...NAV_ROLE_PERMISSIONS[screen]].sort(), screen).toEqual([...setFor(fixture)].sort())
    }
    for (const atom of NAV_ROLE_PERMISSIONS.scoped) expect(golden.atoms.has(atom), atom).toBe(true)
  })

  it('N9b no access fixture grants an atom the matrix denies that role', () => {
    for (const name of Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]) {
      const perms = setFor(name)
      for (const atom of ACCESS_FIXTURES[name].permissions) expect(perms.has(atom), `${name}: ${atom}`).toBe(true)
    }
  })
})
