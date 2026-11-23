/** Harness fixtures of T-2600 (pilot gap G5b): the NOTIFICATION STEP form of a service step — the channel, the
 *  template picker, the recipient and the values. Invented data — the catalogue answers with two registered
 *  templates. The step panel runs for real (the picker, its rows and the load states); the starting selection
 *  comes from the `demo` prop because the screenshot tool cannot click. The catalogue read goes through the
 *  fixture seam, so the failed state is the real one. One screen per state: the shot tool names its files after
 *  the screen, so a second state would overwrite the first. The catalogue read's own transient states (loading,
 *  empty) are not screens here: they are a hint line inside the panel, and the component test F6 of
 *  `NotifyStepEditor.test.tsx` proves them. */
import { useIntl } from 'react-intl'
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DiagramEditPane, type DiagramEditPaneProps } from '@/components/diagram/DiagramEditPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null = null) => ({ id, node_type, label, attributes })

/** The mail channel: a template, the variable the address is read from and two declared values. */
const NOTIFY_EMAIL = {
  channel: 'email',
  template_key: 'tenant_registered',
  recipient: { var: 'admin_email' },
  values: {
    tenant_name: { var: 'tenant_name' },
    tenant_slug: { var: 'tenant_slug' },
    registered_by: { const: 'Platform administrator' },
  },
}

/** The file channel: a template and the name the file is stored under (no recipient — the channels are
 *  exclusive). */
const NOTIFY_FILE = {
  channel: 'file',
  template_key: 'tenant_registered',
  file_name: 'registration-notice',
  values: { tenant_name: { var: 'tenant_name' } },
}

/** A step whose recipient is missing: the form shows the problem the server would refuse it with. */
const NOTIFY_INVALID = {
  channel: 'email',
  template_key: 'tenant_registered',
  values: { tenant_name: { var: 'tenant_name' } },
}

const GRAPH: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit registration', { role: 'EMPLOYEE' }),
    n('notify', 'SERVICE_TASK', 'Notify the administrator', { notify: NOTIFY_EMAIL }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'submit' },
    { id: 'e2', source: 'submit', target: 'notify' },
    { id: 'e3', source: 'notify', target: 'end' },
  ],
}

const DEF: ProcessDefinition = {
  id: 'def-harness-notify',
  name: 'platform_register_tenant',
  version: '1.0.0',
  description: '',
  status: 'DRAFT',
  graph: GRAPH,
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-02T09:00:00Z',
}

/** The same definition with another notification: the file channel. */
const FILE_DEF: ProcessDefinition = {
  ...DEF,
  graph: {
    ...GRAPH,
    nodes: GRAPH.nodes.map((node) =>
      node.id === 'notify' ? { ...node, attributes: { notify: NOTIFY_FILE } } : node,
    ),
  },
}

/** The same definition with a notification the server would refuse: no recipient. */
const INVALID_DEF: ProcessDefinition = {
  ...DEF,
  graph: {
    ...GRAPH,
    nodes: GRAPH.nodes.map((node) =>
      node.id === 'notify' ? { ...node, attributes: { notify: NOTIFY_INVALID } } : node,
    ),
  },
}

const CATALOGUE = {
  items: [
    { template_key: 'tenant_registered', placeholders: ['tenant_name', 'tenant_slug', 'registered_by'] },
    { template_key: 'task_assigned', placeholders: ['task_name', 'process_name', 'assignee_name'] },
  ],
}

/** The catalogue read of one screen: the registered templates or a failure. */
type CatalogueMode = 'entries' | 'failed'

function catalogueRoute(mode: CatalogueMode): FixtureRoute {
  return {
    match: (p, m) => m === 'GET' && p.endsWith('/api/v1/notification-templates/catalogue'),
    reply: () => {
      if (mode === 'failed') return { status: 500, body: { title: 'Fixture error', status: 500 } }
      return { status: 200, body: { items: CATALOGUE.items } }
    },
  }
}

function routes(mode: CatalogueMode, def: ProcessDefinition = DEF): FixtureRoute[] {
  return [
    { match: (p, m) => m === 'POST' && p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: def.id } }) },
    { match: (p, m) => m === 'GET' && p.endsWith(`/definitions/${def.id}`), reply: () => ({ status: 200, body: def }) },
    catalogueRoute(mode),
  ]
}

function HarnessHeader({ title }: { title: string }): ReactElement {
  const intl = useIntl()
  return <PageHeader eyebrow={intl.formatMessage({ id: 'processDiagram.edit.pageEyebrow' })} title={title} lede={intl.formatMessage({ id: 'processDiagram.edit.pageLede' })} />
}

function frame(title: string, props: Partial<DiagramEditPaneProps> & { def?: ProcessDefinition }): ReactElement {
  return (
    <ProcessDiagramIntlProvider>
      <div className="lf-main">
        <main className="lf-content">
          <HarnessHeader title={title} />
          <DiagramEditPane def={props.def ?? DEF} editorDirty={false} onDirtyChange={() => {}} onSaved={() => {}} onReload={() => {}} demo={props.demo} />
        </main>
      </div>
    </ProcessDiagramIntlProvider>
  )
}

const SELECTED = { selected: { kind: 'node' as const, id: 'notify' } }

export const notifyStepPickerScreens: HarnessScreen[] = [
  // The mail channel: the template, the recipient variable and the declared values.
  { name: 'pd-notify-email', routes: routes('entries'), render: () => frame('Register tenant', { demo: SELECTED }) },
  // The file channel: the file name instead of the recipient.
  { name: 'pd-notify-file', routes: routes('entries', FILE_DEF), render: () => frame('Register tenant', { demo: SELECTED, def: FILE_DEF }) },
  // A step the server would refuse: the form shows the problem.
  { name: 'pd-notify-invalid', routes: routes('entries', INVALID_DEF), render: () => frame('Register tenant', { demo: SELECTED, def: INVALID_DEF }) },
  // The catalogue could not be read.
  { name: 'pd-notify-error', routes: routes('failed'), render: () => frame('Register tenant', { demo: SELECTED }) },
]
