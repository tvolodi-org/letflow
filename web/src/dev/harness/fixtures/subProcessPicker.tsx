/** Harness fixtures of T-2847 (PILOT-SUB-4): the SUB_PROCESS step panel of the Edit-diagram screen.
 *  pd-sub-picker-tenant — a tenant-made parent: the list holds the plain process only, and says why the module
 *  process is missing; pd-sub-picker-mapped — the plain process chosen, its variables, one passed in, one taken back;
 *  pd-sub-picker-refused — a tenant parent whose chosen child is the module-only stock_receipt (plain message);
 *  pd-sub-picker-stock — a stock-module parent: stock_receipt is in the list. Invented data. */
import { useIntl } from 'react-intl'
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DiagramEditPane } from '@/components/diagram/DiagramEditPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null = null) => ({ id, node_type, label, attributes })

const graphWith = (attrs: Record<string, unknown>): DefinitionGraph => ({
  nodes: [n('start', 'START', null), n('call', 'SUB_PROCESS', 'Receive goods', attrs), n('end', 'END', null)],
  edges: [
    { id: 'e1', source: 'start', target: 'call' },
    { id: 'e2', source: 'call', target: 'end' },
  ],
})

const base = (id: string, name: string, over: Partial<ProcessDefinition>): ProcessDefinition => ({
  id,
  name,
  version: '2',
  status: 'ACTIVE',
  graph: graphWith({}),
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-02T09:00:00Z',
  ...over,
})

const PLAIN = base('def-sub-plain', 'goods_check', {
  variable_schemas: [
    { variable_key: 'supplier_id', json_schema: { type: 'string' } },
    { variable_key: 'check_result', json_schema: { type: 'string' } },
  ],
})
const STOCK_RECEIPT = base('def-sub-stock', 'stock_receipt', {
  owner_module: 'stock',
  graph: { nodes: [n('post', 'HUMAN_TASK', 'Post', { module_writes: [{ kind: 'document' }] })], edges: [] },
  variable_schemas: [{ variable_key: 'document_id', json_schema: { type: 'string' } }],
})

const parent = (id: string, attrs: Record<string, unknown>, owner: string | null): ProcessDefinition =>
  base(id, 'receive_and_check', { status: 'DRAFT', graph: graphWith(attrs), owner_module: owner })

const ROUTES: FixtureRoute[] = [
  { match: (p, m) => m === 'POST' && p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: 'x' } }) },
  { match: (p, m) => m === 'GET' && p.endsWith('/definitions/def-sub-plain'), reply: () => ({ status: 200, body: PLAIN }) },
  { match: (p, m) => m === 'GET' && p.endsWith('/definitions/def-sub-stock'), reply: () => ({ status: 200, body: STOCK_RECEIPT }) },
  { match: (p, m) => m === 'GET' && p.endsWith('/definitions'), reply: () => ({ status: 200, body: { items: [PLAIN, STOCK_RECEIPT], next_cursor: null } }) },
]

function Frame({ children }: { children: ReactElement }): ReactElement {
  const intl = useIntl()
  return (
    <div className="lf-main">
      <main className="lf-content">
        <PageHeader eyebrow={intl.formatMessage({ id: 'processDiagram.edit.pageEyebrow' })} title="Receive and check" lede={intl.formatMessage({ id: 'processDiagram.edit.pageLede' })} />
        {children}
      </main>
    </div>
  )
}

const screenOf = (name: string, def: ProcessDefinition): HarnessScreen => ({
  name,
  routes: ROUTES,
  render: () => (
    <ProcessDiagramIntlProvider>
      <Frame>
        <DiagramEditPane def={def} editorDirty={false} onDirtyChange={() => {}} onSaved={() => {}} onReload={() => {}} demo={{ selected: { kind: 'node', id: 'call' } }} />
      </Frame>
    </ProcessDiagramIntlProvider>
  ),
})

export const subProcessPickerScreens: HarnessScreen[] = [
  screenOf('pd-sub-picker-tenant', parent('p1', {}, null)),
  screenOf('pd-sub-picker-mapped', parent('p2', { definition_name: 'goods_check', interface: { inputs: [{ name: 'supplier_id', json_schema: { type: 'string' }, required: false }], outputs: [{ name: 'check_result', json_schema: { type: 'string' }, required: false }] } }, null)),
  screenOf('pd-sub-picker-refused', parent('p3', { definition_name: 'stock_receipt' }, null)),
  screenOf('pd-sub-picker-stock', parent('p4', { definition_name: 'stock_receipt' }, 'stock')),
]
