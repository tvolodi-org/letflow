/** Harness fixtures of T-2045: the two behaviour changes in the diagram editor.
 *  1. pd-edit-just-saved-prop — DiagramEditPane opened with justSaved={true} (new prop path, shows "Saved." on open).
 *  2. pd-edit-add-step-result — DiagramEditPane with a graph that has an extra Human Task node placed to the right,
 *     simulating the viewport-fitted state after clicking "Add step". The existing nodes have no explicit positions
 *     so dagre lays them out; the extra node has an explicit far-right position to demonstrate that fitView brings
 *     it into view.
 */
import { useIntl } from 'react-intl'
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DiagramEditPane } from '@/components/diagram/DiagramEditPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null = null) => ({ id, node_type, label, attributes })

const BASE_GRAPH: DefinitionGraph = {
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

// Simulates the graph after clicking "Add step": the new HUMAN_TASK node is placed to the
// right of the rightmost existing node (dagre LR layout ends around x=1200 for this graph;
// addStep places it at max_x + 280). The node has an explicit position so withLayoutPositions
// leaves it in place; the other nodes get auto positions from dagre.
const GRAPH_WITH_ADDED: DefinitionGraph = {
  nodes: [
    ...BASE_GRAPH.nodes,
    n('n_human_task_new', 'HUMAN_TASK', null, { position: { x: 1600, y: 0 } }),
  ],
  edges: BASE_GRAPH.edges,
}

const DEF: ProcessDefinition = {
  id: 'def-harness-fix',
  name: 'purchase_request',
  version: '1.0.0',
  description: '',
  status: 'DRAFT',
  graph: BASE_GRAPH,
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-02T09:00:00Z',
}

const ROUTES: FixtureRoute[] = [
  { match: (p, m) => m === 'POST' && p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: DEF.id } }) },
  { match: (p, m) => m === 'GET' && p.endsWith(`/definitions/${DEF.id}`), reply: () => ({ status: 200, body: DEF }) },
  { match: (p, m) => m === 'GET' && p.endsWith('/definitions/def-harness-fix-added'), reply: () => ({ status: 200, body: { ...DEF, id: 'def-harness-fix-added', graph: GRAPH_WITH_ADDED } }) },
]

function HarnessHeader({ title }: { title: string }): ReactElement {
  const intl = useIntl()
  return <PageHeader eyebrow={intl.formatMessage({ id: 'processDiagram.edit.pageEyebrow' })} title={title} lede={intl.formatMessage({ id: 'processDiagram.edit.pageLede' })} />
}

function Frame({ title, children }: { title: string; children: ReactElement }): ReactElement {
  return (
    <ProcessDiagramIntlProvider>
      <div className="lf-main">
        <main className="lf-content">
          <HarnessHeader title={title} />
          {children}
        </main>
      </div>
    </ProcessDiagramIntlProvider>
  )
}

export const diagramEditorFixScreens: HarnessScreen[] = [
  {
    // The pane opened immediately after a version-copy save: justSaved prop shows the "Saved." banner at once.
    name: 'pd-edit-just-saved-prop',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (just saved)">
        <DiagramEditPane
          def={DEF}
          justSaved
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
        />
      </Frame>
    ),
  },
  {
    // T-2812 (D2): saved draft with one open problem: amber banner, never green.
    name: 'pd-edit-saved-1-problem',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (saved, 1 problem)">
        <DiagramEditPane
          def={DEF}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{ saved: true, violations: [{ code: 'step_mapping_variable_undeclared', message: "Node 'check' reads mapping admin_email: the variable is not declared" }] }}
        />
      </Frame>
    ),
  },
  {
    name: 'pd-edit-saved-2-problems',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (saved, 2 problems)">
        <DiagramEditPane
          def={DEF}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{
            saved: true,
            violations: [
              { code: 'step_mapping_variable_undeclared', message: "Node 'check' reads mapping admin_email: the variable is not declared" },
              { code: 'node_unreachable', message: "Node 'order' is not reachable from the start" },
            ],
          }}
        />
      </Frame>
    ),
  },
  {
    // The editor after clicking "Add step": an extra Human Task node is to the far right; fitView
    // brings it into the viewport. The node is unconnected to show it was just added.
    name: 'pd-edit-add-step-result',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (after Add step)">
        <DiagramEditPane
          def={{ ...DEF, id: 'def-harness-fix-added', graph: GRAPH_WITH_ADDED }}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{ selected: { kind: 'node', id: 'n_human_task_new' } }}
        />
      </Frame>
    ),
  },
  {
    // T-2813 (D3): the save-error banner in plain words, the raw code only under details.
    name: 'pd-err-notify',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (save error)">
        <DiagramEditPane
          def={DEF}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{ error: { kind: 'other', code: 'notify_malformed', status: 422, message: 'Unprocessable Entity' } }}
        />
      </Frame>
    ),
  },
  {
    // T-2813 (D3): the save-error banner in plain words, the raw code only under details.
    name: 'pd-err-platform',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (save error)">
        <DiagramEditPane
          def={DEF}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{ error: { kind: 'other', code: 'platform_call_function_unknown', status: 422, message: 'Unprocessable Content' } }}
        />
      </Frame>
    ),
  },
  {
    // T-2813 (D3): the save-error banner in plain words, the raw code only under details.
    name: 'pd-err-409',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (save error)">
        <DiagramEditPane
          def={DEF}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{ error: { kind: 'not_draft', code: 'http_409', status: 409, message: 'Definition is not DRAFT' } }}
        />
      </Frame>
    ),
  },
  {
    // T-2813 (D3): the save-error banner in plain words, the raw code only under details.
    name: 'pd-err-fallback',
    routes: ROUTES,
    render: () => (
      <Frame title="Purchase request (save error)">
        <DiagramEditPane
          def={DEF}
          editorDirty={false}
          onDirtyChange={() => {}}
          onSaved={() => {}}
          onReload={() => {}}
          demo={{ error: { kind: 'other', status: 500, message: 'Internal Server Error' } }}
        />
      </Frame>
    ),
  },
]
