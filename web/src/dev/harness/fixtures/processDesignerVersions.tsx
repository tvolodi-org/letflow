/** Harness fixtures of T-1588 (slice 3A): the Versions view of the definition page. Invented data; the pane runs
 *  against the fake `GET /api/v1/definitions` (which also answers a definition with an overlapping name, to show the
 *  exact-name filter). States: default (list + diff), empty (one version), loading, error; plus "no differences",
 *  "same version twice" and a diff with a step list at 390 px. */
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DefinitionVersionsPane } from '@/components/diagram/DefinitionVersionsPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { DefinitionViewSwitch } from '@/components/diagram/DefinitionViewSwitch'
import { PageHeader } from '@/components/ui/PageHeader'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import type { FixtureRoute, HarnessScreen } from '../types'

/** A signed-in stand-in: the harness has no login; only `session.tenant_id` (a cache key part) is read. */
const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' }, isAuthenticated: true } as unknown as AuthContextValue

const n = (id: string, node_type: NodeType, label: string | null, attributes: object | null = null) => ({ id, node_type, label, attributes })

const V1: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit request', { role: 'EMPLOYEE' }),
    n('review', 'HUMAN_TASK', 'Review by clerk', { role: 'CLERK' }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e_1', source: 'start', target: 'submit' },
    { id: 'e_2', source: 'submit', target: 'review' },
    { id: 'e_3', source: 'review', target: 'end' },
  ],
}
const V2: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit request', { role: 'EMPLOYEE' }),
    n('review', 'HUMAN_TASK', 'Review by clerk', { role: 'SENIOR_CLERK' }),
    n('approve', 'HUMAN_TASK', 'Approve by head', { role: 'HEAD_OF_UNIT' }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e_1', source: 'start', target: 'submit' },
    { id: 'e_2', source: 'submit', target: 'review' },
    { id: 'e_3', source: 'review', target: 'approve' },
    { id: 'e_4', source: 'approve', target: 'end' },
  ],
}
const V3: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit request', { role: 'EMPLOYEE' }),
    n('review', 'HUMAN_TASK', 'Review by clerk', { role: 'SENIOR_CLERK' }),
    n('check', 'EXCLUSIVE_GATEWAY', 'Amount over limit?'),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e_1', source: 'start', target: 'submit' },
    { id: 'e_2', source: 'submit', target: 'review' },
    { id: 'e_3', source: 'review', target: 'check' },
    { id: 'e_4', source: 'check', target: 'end', condition: 'amount <= 1000' },
  ],
}

const ver = (id: string, version: string, status: ProcessDefinition['status'], graph: DefinitionGraph, day: string, name = 'purchase-request'): ProcessDefinition => ({
  id,
  name,
  version,
  status,
  graph,
  description: '',
  created_by: '7c1f0a52-3d0e-4b0a-9c3a-1f4d2e8b6a10',
  created_at: `2026-11-${day}T09:30:00Z`,
  updated_at: `2026-11-${day}T09:30:00Z`,
})

const D3 = ver('d3', '3', 'DRAFT', V3, '09')
const D2 = ver('d2', '2', 'ACTIVE', V2, '05')
const D1 = ver('d1', '1', 'DEPRECATED', V1, '01')
// A definition whose name contains this one: the server's substring filter returns it too; the pane must not show it.
const FOREIGN = ver('dx', '7', 'ACTIVE', V1, '08', 'purchase-request-urgent')

function listRoute(items: ProcessDefinition[]): FixtureRoute {
  return {
    match: (p, m) => m === 'GET' && p === '/api/v1/definitions',
    reply: (state) =>
      state === 'error'
        ? { status: 500, body: { title: 'Internal Server Error', status: 500 } }
        : { status: 200, body: { items: state === 'empty' ? [items[items.length - 1]] : items, next_cursor: null } },
  }
}

function frame(def: ProcessDefinition, initialBaseId?: string): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
    <ProcessDiagramIntlProvider>
      <div className="lf-main">
        <main className="lf-content">
          <PageHeader eyebrow="Definitions" title={def.name} lede="Versions of this definition." />
          <div className="lf-pd__toolbar">
            <DefinitionViewSwitch view="versions" onChange={() => {}} unsaved={false} canEditDiagram canShowVersions />
          </div>
          <DefinitionVersionsPane def={def} initialBaseId={initialBaseId} />
        </main>
      </div>
    </ProcessDiagramIntlProvider>
    </AuthContext.Provider>
  )
}

export const processDesignerVersionsScreens: HarnessScreen[] = [
  { name: 'pd-versions', routes: [listRoute([D3, FOREIGN, D2, D1])], render: ({ state }) => frame(state === 'empty' ? D1 : D3) },
  { name: 'pd-versions-wide', routes: [listRoute([D3, FOREIGN, D2, D1])], render: () => frame(D3, 'd1') },
  { name: 'pd-versions-same', routes: [listRoute([ver('s2', '2', 'DRAFT', V1, '09'), ver('s1', '1', 'ACTIVE', V1, '01')])], render: () => frame(ver('s2', '2', 'DRAFT', V1, '09')) },
  { name: 'pd-versions-twice', routes: [listRoute([D3, D2, D1])], render: () => frame(D3, 'd3') },
]
