/** Harness fixtures of T-1563 (process designer, slice 2): the diagram in EDIT mode. Invented data. The pane runs for
 *  real (draft, history, toolbar, panel, step list under 640 px); the starting selection, problems and banners come from
 *  its `demo` prop because the screenshot tool cannot click. Same screens serve the Playwright drag spec. */
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DiagramEditPane, type DiagramEditPaneProps } from '@/components/diagram/DiagramEditPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null = null) => ({ id, node_type, label, attributes })

const GRAPH: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit purchase request', { role: 'EMPLOYEE' }),
    n('check', 'SERVICE_TASK', 'Check budget', { script_key: 'budget_check', script_version: 1 }),
    n('amount', 'EXCLUSIVE_GATEWAY', 'Amount over limit?'),
    n('approve', 'HUMAN_TASK', 'Approve as head of unit', { role: 'HEAD_OF_UNIT' }),
    n('order', 'SUB_PROCESS', 'Place order', { definition_name: 'procurement_order' }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'submit' },
    { id: 'e2', source: 'submit', target: 'check' },
    { id: 'e3', source: 'check', target: 'amount' },
    { id: 'e4', source: 'amount', target: 'approve', condition: 'amount > 100000' },
    { id: 'e5', source: 'amount', target: 'order', is_default: true },
    { id: 'e6', source: 'approve', target: 'order' },
    { id: 'e7', source: 'order', target: 'end' },
  ],
}

const DEF: ProcessDefinition = {
  id: 'def-harness',
  name: 'purchase_request',
  version: '1.0.0',
  description: '',
  status: 'DRAFT',
  graph: GRAPH,
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-02T09:00:00Z',
}

// The live check and the stale check call the real API client; the harness answers like a clean server.
const ROUTES: FixtureRoute[] = [
  { match: (p, m) => m === 'POST' && p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: DEF.id } }) },
  { match: (p, m) => m === 'GET' && p.endsWith(`/definitions/${DEF.id}`), reply: () => ({ status: 200, body: DEF }) },
]

function frame(title: string, props: Partial<DiagramEditPaneProps> & { def?: ProcessDefinition }): ReactElement {
  return (
    <ProcessDiagramIntlProvider>
      <div className="lf-main">
        <main className="lf-content">
          <PageHeader eyebrow="Definitions" title={title} lede="Edit the process in the diagram; saved as a draft version." />
          <DiagramEditPane def={props.def ?? DEF} editorDirty={false} onDirtyChange={() => {}} onSaved={() => {}} onReload={() => {}} demo={props.demo} />
        </main>
      </div>
    </ProcessDiagramIntlProvider>
  )
}

export const processDesignerEditScreens: HarnessScreen[] = [
  { name: 'pd-edit', routes: ROUTES, render: () => frame('Purchase request', {}) },
  { name: 'pd-edit-panel', routes: ROUTES, render: () => frame('Purchase request', { demo: { selected: { kind: 'node', id: 'submit' } } }) },
  {
    name: 'pd-edit-violations',
    routes: ROUTES,
    render: () =>
      frame('Purchase request', {
        demo: {
          selected: { kind: 'node', id: 'approve' },
          violations: [
            { code: 'missing_role', message: "Node 'approve' (HUMAN_TASK) is missing a non-empty 'role' attribute." },
            { code: 'undeclared_variable_reference', message: "Edge 'e4' (from EXCLUSIVE_GATEWAY node 'amount') condition references undeclared variable 'amount'" },
          ],
        },
      }),
  },
  { name: 'pd-edit-edge', routes: ROUTES, render: () => frame('Purchase request', { demo: { selected: { kind: 'edge', id: 'e4' } } }) },
  {
    name: 'pd-edit-conflict',
    routes: ROUTES,
    render: () => frame('Purchase request', { demo: { error: { kind: 'not_draft', message: 'only a DRAFT definition can be modified' } } }),
  },
  { name: 'pd-edit-saved', routes: ROUTES, render: () => frame('Purchase request', { demo: { saved: true } }) },
  { name: 'pd-edit-copy', routes: ROUTES, render: () => frame('Purchase request', { def: { ...DEF, status: 'ACTIVE' } }) },
]
