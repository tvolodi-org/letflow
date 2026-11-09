/** Harness fixtures of T-1520: the read-only process diagram (definition view, steps list, node details, instance
 *  path in ACTIVE / COMPLETED / ERROR, history incomplete, large definition, unsaved-preview badge). Invented data;
 *  shapes follow the real API (attributes as a JSON string, timeline items as timeline_item/2 returns them). */
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, TimelineEntry } from '@/types/api'
import ProcessDiagram from '@/components/diagram/ProcessDiagram'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { DefinitionViewSwitch } from '@/components/diagram/DefinitionViewSwitch'
import { Skeleton } from '@/components/ui/Skeleton'
import { PageHeader } from '@/components/ui/PageHeader'
import { deriveInstancePath, timelineEvidence, type PathInstance } from '@/utils/canvas/instancePath'
import type { HarnessScreen, HarnessState } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: object | null = null) => ({
  id,
  node_type,
  label,
  attributes: attributes === null ? null : JSON.stringify(attributes),
})

const GRAPH: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit purchase request', {
      role: 'EMPLOYEE',
      form_schema: { properties: { item: { title: 'Item' }, amount: { title: 'Amount' }, reason: { title: 'Reason' } } },
    }),
    n('check', 'SERVICE_TASK', 'Check budget', { service_id: 'budget-api', script_key: 'budget_check' }),
    n('amount', 'EXCLUSIVE_GATEWAY', 'Amount over limit?'),
    n('fork', 'PARALLEL_GATEWAY', 'Two approvals'),
    n('head', 'HUMAN_TASK', 'Approve as head of unit', { role: 'HEAD_OF_UNIT', distinct_from: ['submit'] }),
    n('finance', 'HUMAN_TASK', 'Approve as finance', { role: 'FINANCE', module_writes: [{ handler: 'post_document' }] }),
    n('join', 'PARALLEL_GATEWAY', 'Both approved'),
    n('wait', 'TIMER', 'Cooling-off', { duration_iso8601: 'PT2H' }),
    n('order', 'SUB_PROCESS', 'Place order', { definition_name: 'procurement_order' }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'submit' },
    { id: 'e2', source: 'submit', target: 'check' },
    { id: 'e3', source: 'check', target: 'amount' },
    { id: 'e4', source: 'amount', target: 'fork', condition: 'amount > 100000' },
    { id: 'e5', source: 'amount', target: 'order', is_default: true },
    { id: 'e6', source: 'fork', target: 'head' },
    { id: 'e7', source: 'fork', target: 'finance' },
    { id: 'e8', source: 'head', target: 'join' },
    { id: 'e9', source: 'finance', target: 'join' },
    { id: 'e10', source: 'join', target: 'wait' },
    { id: 'e11', source: 'wait', target: 'order' },
    { id: 'e12', source: 'order', target: 'end' },
  ],
}

let seq = 0
const ev = (event_type: string, node_id: string | null): TimelineEntry => {
  seq += 1
  return {
    event_id: `h-${seq}`,
    event_type,
    sequence_num: seq,
    instance_id: 'inst-h',
    timestamp: '2026-11-09T09:00:00Z',
    node_id,
    task_id: null,
    metadata: {},
    actor_display_name: 'Harness',
    description: event_type,
  }
}
const started = () => [ev('INSTANCE_STARTED', null)]
const done = (...ids: string[]) => [...started(), ...ids.map((id) => ev(id === 'check' ? 'SERVICE_TASK_COMPLETED' : 'TASK_COMPLETED', id))]

function frame(title: string, body: ReactElement, extra?: ReactElement): ReactElement {
  return (
    <ProcessDiagramIntlProvider>
      <div className="lf-main">
        <main className="lf-content">
          <PageHeader eyebrow="Definitions" title={title} lede="Read-only diagram drawn from the definition." />
          {extra}
          {body}
        </main>
      </div>
    </ProcessDiagramIntlProvider>
  )
}

function instanceScreen(name: string, inst: PathInstance, entries: TimelineEntry[], complete = true): HarnessScreen {
  return {
    name,
    routes: [],
    render: () => {
      const path = deriveInstancePath(GRAPH, inst, timelineEvidence(entries, { complete }))
      const reason = typeof inst.error_detail?.reason === 'string' ? inst.error_detail.reason : null
      return frame('Purchase request · instance', <ProcessDiagram graph={GRAPH} path={path} errorReason={reason} live={inst.status === 'ACTIVE'} onRetry={complete ? undefined : () => {}} />)
    },
  }
}

const LARGE: DefinitionGraph = {
  nodes: [n('s', 'START', null), ...Array.from({ length: 420 }, (_, i) => n(`t${i}`, 'HUMAN_TASK', `Step ${i + 1}`))],
  edges: Array.from({ length: 420 }, (_, i) => ({ id: `l${i}`, source: i === 0 ? 's' : `t${i - 1}`, target: `t${i}` })),
}

function definitionBody(state: HarnessState): ReactElement {
  if (state === 'loading') {
    return (
      <div data-testid="diagram-loading" aria-busy="true">
        <Skeleton />
        <Skeleton />
        <Skeleton />
      </div>
    )
  }
  if (state === 'empty') return <ProcessDiagram graph={{ nodes: [], edges: [] }} />
  if (state === 'error') return <ProcessDiagram graph={null} />
  return <ProcessDiagram graph={GRAPH} />
}

export const processDiagramScreens: HarnessScreen[] = [
  { name: 'pd-definition', routes: [], render: ({ state }) => frame('Purchase request', definitionBody(state)) },
  { name: 'pd-selected', routes: [], render: () => frame('Purchase request', <ProcessDiagram graph={GRAPH} initialSelected="head" />) },
  { name: 'pd-steps', routes: [], render: () => frame('Purchase request', <ProcessDiagram graph={GRAPH} initialMode="steps" />) },
  { name: 'pd-large', routes: [], render: () => frame('Large definition', <ProcessDiagram graph={LARGE} />) },
  {
    name: 'pd-unsaved',
    routes: [],
    render: () =>
      frame(
        'Purchase request',
        <ProcessDiagram graph={GRAPH} />,
        <div className="lf-pd__toolbar">
          <DefinitionViewSwitch view="diagram" onChange={() => {}} unsaved />
        </div>,
      ),
  },
  instanceScreen('pd-instance-active', { status: 'ACTIVE', current_nodes: ['finance'] }, done('submit', 'check', 'head')),
  instanceScreen('pd-instance-completed', { status: 'COMPLETED', current_nodes: [] }, done('submit', 'check')),
  instanceScreen(
    'pd-instance-error',
    { status: 'ERROR', current_nodes: ['check'], error_detail: { affected: { kind: 'node', node_id: 'check' }, reason: 'Budget service timed out' } },
    done('submit'),
  ),
  instanceScreen(
    'pd-instance-error-unattributed',
    { status: 'ERROR', current_nodes: ['check'], error_detail: { affected: { kind: 'field', key: 'amount' }, reason: 'amount is not a number' } },
    done('submit'),
  ),
  instanceScreen('pd-instance-incomplete', { status: 'ACTIVE', current_nodes: ['finance'] }, done('submit', 'head'), false),
]
