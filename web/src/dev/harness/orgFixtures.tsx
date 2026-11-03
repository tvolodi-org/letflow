/** Harness fixtures of the org-structure screens (tasks S1, S2): legal companies, sites, the org unit tree, positions
 *  and employees.
 *  Plain invented data (the design repo's Gate A names); no real tenant, id or secret. The fake server honours
 *  the `active` and `deleted` filters of POST /api/v1/entities/query and answers by `entity_type`. */
import { useEffect, type ReactNode } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import LegalEntitiesPage from '@/modules/org/LegalEntitiesPage'
import PositionsPage from '@/modules/org/PositionsPage'
import EmployeesPage from '@/modules/org/EmployeesPage'
import SitesPage from '@/modules/org/SitesPage'
import UnitsPage from '@/modules/org/UnitsPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessLang, HarnessScreen, HarnessState } from './types'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id,
  entity_type: type,
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})

const LEGAL = [
  rec('le-1', 'org_legal_entity', { code: 'GATEA-LE1', name: 'Demo Holding LLP', bin: '163956876601' }),
  rec('le-2', 'org_legal_entity', { code: 'GATEA-LE2', name: 'Demo Service LLP', bin: '210940012345' }),
  rec('le-3', 'org_legal_entity', { code: 'GATEA-LE0', name: 'Old Trading LLP', bin: '050140001234', active: false }),
]
const SITES = [
  rec('s-1', 'org_site', { code: 'GATEA-S-ALA', name: 'Almaty office', legal_entity_id: 'le-1' }),
  rec('s-2', 'org_site', { code: 'GATEA-S-AST', name: 'Astana depot', legal_entity_id: 'le-2' }),
  rec('s-3', 'org_site', { code: 'GATEA-S-OLD', name: 'Karaganda yard', legal_entity_id: 'le-3', active: false }),
]
const unit = (id: string, code: string, name: string, le: string, site: string, parent?: string) =>
  rec(id, 'org_unit', { code, name, legal_entity_id: le, site_id: site, ...(parent ? { parent } : {}) })
const UNITS = [
  unit('u-ho', 'GATEA-OU-HO', 'Head office', 'le-1', 's-1'),
  unit('u-fin', 'GATEA-OU-FIN', 'Finance department', 'le-1', 's-1', 'u-ho'),
  unit('u-acc', 'GATEA-OU-ACC', 'Accounting', 'le-1', 's-1', 'u-fin'),
  unit('u-pay', 'GATEA-OU-PAY', 'Payroll group', 'le-1', 's-1', 'u-acc'),
  unit('u-it', 'GATEA-OU-IT', 'IT department', 'le-1', 's-1', 'u-ho'),
  unit('u-svc', 'GATEA-OU-SVC', 'Service company', 'le-2', 's-2'),
  unit('u-wh', 'GATEA-OU-WH', 'Warehouse team', 'le-2', 's-2', 'u-svc'),
  unit('u-wha', 'GATEA-OU-WHA', 'Warehouse shift A', 'le-2', 's-2', 'u-wh'),
  rec('u-old', 'org_unit', { code: 'GATEA-OU-OLD', name: 'Closed department', legal_entity_id: 'le-3', site_id: 's-3', active: false }),
]

const pos = (id: string, code: string, name: string, unitId: string, active = true) =>
  rec(id, 'org_position', { code, name, org_unit_id: unitId, active })
const POSITIONS = [
  pos('p-acc', 'GATEA-POS-ACC', 'Chief accountant', 'u-acc'),
  pos('p-acc2', 'GATEA-POS-ACC2', 'Accountant', 'u-acc'),
  pos('p-pay', 'GATEA-POS-PAY', 'Payroll specialist', 'u-pay'),
  pos('p-it', 'GATEA-POS-IT', 'System administrator', 'u-it'),
  pos('p-wh', 'GATEA-POS-WH', 'Warehouse keeper', 'u-wha'),
  pos('p-old', 'GATEA-POS-OLD', 'Courier', 'u-wh', false),
]
const emp = (id: string, code: string, fullName: string, unitId: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'org_employee', { code, full_name: fullName, org_unit_id: unitId, ...extra })
const EMPLOYEES = [
  emp('e-1', 'GATEA-E001', 'Aigerim Sarsenova', 'u-acc', { position_id: 'p-acc', user_id: 'usr-1' }),
  emp('e-2', 'GATEA-E002', 'Nurlan Bekov', 'u-acc', { position_id: 'p-acc2' }),
  emp('e-3', 'GATEA-E003', 'Dana Omarova', 'u-pay', { position_id: 'p-pay' }),
  emp('e-4', 'GATEA-E004', 'Timur Akhmetov', 'u-it', { position_id: 'p-it', user_id: 'usr-2' }),
  emp('e-5', 'GATEA-E005', 'Saule Kenzhebaeva', 'u-wha', { position_id: 'p-wh' }),
  emp('e-6', 'GATEA-E006', 'Marat Iskakov', 'u-wh', { active: false }),
]
const USERS = [
  { id: 'usr-1', display_name: 'Aigerim Sarsenova', email: 'aigerim@demo.invalid' },
  { id: 'usr-2', display_name: 'Timur Akhmetov', email: 'timur@demo.invalid' },
  { id: 'usr-3', display_name: 'Dana Omarova', email: 'dana@demo.invalid' },
]

interface Clause {
  field: string
  op: string
  value?: unknown
}

function queryRoute(): FixtureRoute {
  return {
    match: (path, method) => method === 'POST' && path === '/api/v1/entities/query',
    reply: (state, _path, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
      const all = [...LEGAL, ...SITES, ...UNITS, ...POSITIONS, ...EMPLOYEES].filter(r => r.entity_type === b.entity_type)
      const onlyActive = (b.filters ?? []).some(f => f.field === 'active' && f.value === true)
      const items = state === 'empty' ? [] : all.filter(r => !onlyActive || r.field_values['active'] === true)
      return { status: 200, body: { items, next_cursor: null } }
    },
  }
}

function usersRoute(): FixtureRoute {
  return {
    match: (path, method) => method === 'GET' && path === '/api/v1/identity/users',
    reply: () => ({ status: 200, body: { items: USERS, next_cursor: null } }),
  }
}

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
} as unknown as AuthContextValue

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['OrgStructureWrite', 'OrgEmployeesWrite'] },
}

/** Opens the record of the given tree row once it is on screen, so the screenshot shows the detail panel. */
function AutoOpen({ nodeId, active, then }: { nodeId: string; active: boolean; then?: string }) {
  useEffect(() => {
    if (!active) return
    let frame = 0
    let tries = 0
    const clickThen = () => {
      const button = document.querySelector<HTMLElement>(`[data-testid="${then}"]`)
      if (button) button.click()
      else if (tries++ < 120) frame = requestAnimationFrame(clickThen)
    }
    const tick = () => {
      const row = document.querySelector<HTMLElement>(`.lf-tree__row[data-node-id="${nodeId}"]`)
      if (row) {
        row.click()
        if (then) frame = requestAnimationFrame(clickThen)
      } else if (tries++ < 120) frame = requestAnimationFrame(tick)
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
  }, [nodeId, active, then])
  return null
}

function OrgHarness(props: { lang: HarnessLang; state: HarnessState; nodeId: string; children: ReactNode; then?: string }) {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <main className="lf-content">
          {props.children}
          <AutoOpen nodeId={props.nodeId} active={props.state === 'default'} then={props.then} />
        </main>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

export const orgLegal: HarnessScreen = {
  name: 'org-legal',
  routes: [queryRoute()],
  render: ({ lang, state }) => (
    <OrgHarness lang={lang} state={state} nodeId="le-1">
      <LegalEntitiesPage />
    </OrgHarness>
  ),
}

export const orgSites: HarnessScreen = {
  name: 'org-sites',
  routes: [queryRoute()],
  render: ({ lang, state }) => (
    <OrgHarness lang={lang} state={state} nodeId="s-1">
      <SitesPage />
    </OrgHarness>
  ),
}

export const orgUnits: HarnessScreen = {
  name: 'org-units',
  routes: [queryRoute()],
  render: ({ lang, state }) => (
    <OrgHarness lang={lang} state={state} nodeId="u-acc">
      <UnitsPage />
    </OrgHarness>
  ),
}

export const orgPositions: HarnessScreen = {
  name: 'org-positions',
  routes: [queryRoute()],
  render: ({ lang, state }) => (
    <OrgHarness lang={lang} state={state} nodeId="p-acc">
      <PositionsPage />
    </OrgHarness>
  ),
}

export const orgEmployees: HarnessScreen = {
  name: 'org-employees',
  routes: [queryRoute(), usersRoute()],
  render: ({ lang, state }) => (
    <OrgHarness lang={lang} state={state} nodeId="e-1">
      <EmployeesPage />
    </OrgHarness>
  ),
}

/** The create-child form of the first unit: shows the legal company pre-filled with the parent's (task T-1181). */
export const orgUnitsNewChild: HarnessScreen = {
  name: 'org-units-new-child',
  routes: [queryRoute()],
  render: ({ lang, state }) => (
    <OrgHarness lang={lang} state={state} nodeId="u-acc" then="org-add-child">
      <UnitsPage />
    </OrgHarness>
  ),
}
