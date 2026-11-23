/** Harness fixtures of T-2599 (pilot gap G5a): the FUNCTION PICKER of a service step and its typed var/const
 *  argument mapping. Invented data — the catalogue answers with two platform functions. The step panel runs for
 *  real (the picker, its argument rows and the load states); the starting selection comes from the `demo` prop
 *  because the screenshot tool cannot click. The catalogue read goes through the fixture seam, so the loading and
 *  the failed states are the real ones. One screen per state: the shot tool names its files after the screen,
 *  so a second state would overwrite the first. */
import { useIntl } from 'react-intl'
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DiagramEditPane, type DiagramEditPaneProps } from '@/components/diagram/DiagramEditPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null = null) => ({ id, node_type, label, attributes })

const PLATFORM_CALL = {
  function: 'platform.validate_registration',
  args: {
    slug: { var: 'tenant_slug' },
    display_name: { const: 'Acme' },
    email: { var: 'admin_email' },
  },
  reads: { tenant_slug: 'string', admin_email: 'string' },
  writes: { normalized_slug: 'string' },
}

const GRAPH: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit registration', { role: 'EMPLOYEE' }),
    n('call', 'SERVICE_TASK', 'Validate registration', { platform_call: PLATFORM_CALL }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'submit' },
    { id: 'e2', source: 'submit', target: 'call' },
    { id: 'e3', source: 'call', target: 'end' },
  ],
}

const DEF: ProcessDefinition = {
  id: 'def-harness-platform',
  name: 'platform_register_tenant',
  version: '1.0.0',
  description: '',
  status: 'DRAFT',
  graph: GRAPH,
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-02T09:00:00Z',
}

const CATALOGUE = {
  items: [
    {
      name: 'platform.validate_registration',
      family: 'platform',
      version: '1',
      permission: 'TenantsManage',
      platform_tenant_only: true,
      idempotency_inputs: ['slug'],
      inputs: [
        { name: 'slug', type: 'string', required: true, source_class: 'start' },
        { name: 'display_name', type: 'string', required: true, source_class: 'start' },
        { name: 'email', type: 'string', required: true, source_class: 'start' },
      ],
      outputs: [
        { name: 'normalized_slug', type: 'string' },
        { name: 'email_domain', type: 'string' },
      ],
      side_effects: [{ text: 'reads nothing and writes nothing', class: 'read' }],
    },
    {
      name: 'tenant.provision',
      family: 'platform',
      version: '1',
      permission: 'TenantsManage',
      platform_tenant_only: true,
      idempotency_inputs: ['tenant_id'],
      inputs: [{ name: 'tenant_id', type: 'uuid', required: true, source_class: 'step' }],
      outputs: [{ name: 'schema_name', type: 'string' }],
      side_effects: [{ text: 'creates the tenant schema', class: 'ddl' }],
    },
  ],
}

/** The catalogue read of one screen: the entries, an empty list, a request that never answers, or a failure. */
type CatalogueMode = 'entries' | 'empty' | 'pending' | 'failed'

function catalogueRoute(mode: CatalogueMode): FixtureRoute {
  return {
    match: (p, m) => m === 'GET' && p.endsWith('/api/v1/platform-functions'),
    pending: mode === 'pending',
    reply: () => {
      if (mode === 'failed') return { status: 500, body: { title: 'Fixture error', status: 500 } }
      return { status: 200, body: { items: mode === 'empty' ? [] : CATALOGUE.items } }
    },
  }
}

function routes(mode: CatalogueMode): FixtureRoute[] {
  return [
    { match: (p, m) => m === 'POST' && p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: DEF.id } }) },
    { match: (p, m) => m === 'GET' && p.endsWith(`/definitions/${DEF.id}`), reply: () => ({ status: 200, body: DEF }) },
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

const SELECTED = { selected: { kind: 'node' as const, id: 'call' } }

export const platformCallPickerScreens: HarnessScreen[] = [
  // The palette with the chosen function and its typed argument rows (the variable / fixed value mapping).
  { name: 'pd-platform-picker', routes: routes('entries'), render: () => frame('Register tenant', { demo: SELECTED }) },
  // No platform function is available in this tenant: the catalogue answers an empty list.
  { name: 'pd-platform-empty', routes: routes('empty'), render: () => frame('Register tenant', { demo: SELECTED }) },
  // The catalogue is still loading.
  { name: 'pd-platform-loading', routes: routes('pending'), render: () => frame('Register tenant', { demo: SELECTED }) },
  // The catalogue could not be read.
  { name: 'pd-platform-error', routes: routes('failed'), render: () => frame('Register tenant', { demo: SELECTED }) },
]
