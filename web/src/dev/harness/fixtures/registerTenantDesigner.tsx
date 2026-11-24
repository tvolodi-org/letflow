/** Harness fixture of T-2607 (pilot gap G19): the pilot's registration definition `platform.register_tenant`
 *  in the process designer -- the screen the Playwright spec of this gap drives.
 *
 *  The graph is the DOCUMENT the seed writes into the platform tenant
 *  (`Letflow.PlatformProcesses.Definition.graph()`, `lib/letflow/platform_processes/definition.ex`): the chain
 *  validate -> create -> provision -> bind_realm -> grant_first_admins -> notify -> end. Every `platform_call`
 *  carries the function, its typed arguments and the reads and writes the catalogue entry of the family declares
 *  (`Letflow.PlatformFunctions.TenantFamily`), and the notify step is the mail channel of the pilot: the
 *  registered template `tenant_registered`, the recipient read from the variable `admin_email`, and the three
 *  placeholders of the template.
 *
 *  It is a COPY -- the web app cannot read the server's module -- so every node below names the entry it is
 *  copied from. A change of the document is a change of this file.
 *
 *  The definition is ACTIVE version 1, the state the seed leaves it in: a version that runs, and an edit that
 *  becomes a NEW version. The catalogue reads answer the registered templates and the platform functions, so the
 *  step panel of the designer runs for real: the "Send a notification" button is there and the template picker
 *  offers the registered keys.
 */
import { useIntl } from 'react-intl'
import type { ReactElement } from 'react'
import type { DefinitionGraph, NodeType, ProcessDefinition } from '@/types/api'
import { DiagramEditPane, type DiagramEditPaneProps } from '@/components/diagram/DiagramEditPane'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null, attributes: Record<string, unknown> | null = null) => ({ id, node_type, label, attributes })

/** A catalogue call of the tenant family: the function, the arguments (each read from a variable) and the
 *  typed mapping the catalogue entry declares. A uuid is declared as a string: the instance variables hold it
 *  as one. */
const call = (
  fn: string,
  args: Record<string, { var: string }>,
  reads: Record<string, string>,
  writes: Record<string, string>,
) => ({ platform_call: { function: fn, args, reads, writes } })

const GRAPH: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    // tenant.validate -- the slug and the name of the start form; it reads the tenant registry and writes nothing.
    n('validate', 'SERVICE_TASK', null, call('tenant.validate', { slug: { var: 'slug' }, name: { var: 'name' } }, { slug: 'string', name: 'string' }, {})),
    // tenant.create -- the same two arguments; it writes the id of the new tenant.
    n('create', 'SERVICE_TASK', null, call('tenant.create', { slug: { var: 'slug' }, name: { var: 'name' } }, { slug: 'string', name: 'string' }, { tenant_id: 'string' })),
    // tenant.provision -- the id of the new tenant; it writes the name of its schema.
    n('provision', 'SERVICE_TASK', null, call('tenant.provision', { tenant_id: { var: 'tenant_id' } }, { tenant_id: 'string' }, { schema_name: 'string' })),
    // tenant.bind_realm -- the id of the new tenant and the realm of the start form.
    n('bind_realm', 'SERVICE_TASK', null, call('tenant.bind_realm', { tenant_id: { var: 'tenant_id' }, realm_id: { var: 'realm_id' } }, { tenant_id: 'string', realm_id: 'string' }, {})),
    // tenant.grant_first_admins -- the id of the new tenant and the address of its first administrator.
    n('grant_first_admins', 'SERVICE_TASK', null, call('tenant.grant_first_admins', { tenant_id: { var: 'tenant_id' }, admin_email: { var: 'admin_email' } }, { tenant_id: 'string', admin_email: 'string' }, {})),
    // The notification step: the registered template, the recipient read from a variable and the values.
    n('notify', 'SERVICE_TASK', null, {
      notify: {
        template_key: 'tenant_registered',
        recipient: { var: 'admin_email' },
        values: {
          tenant_name: { var: 'name' },
          tenant_slug: { var: 'slug' },
          registered_by: { var: 'admin_email' },
        },
      },
    }),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'validate' },
    { id: 'e2', source: 'validate', target: 'create' },
    { id: 'e3', source: 'create', target: 'provision' },
    { id: 'e4', source: 'provision', target: 'bind_realm' },
    { id: 'e5', source: 'bind_realm', target: 'grant_first_admins' },
    { id: 'e6', source: 'grant_first_admins', target: 'notify' },
    { id: 'e7', source: 'notify', target: 'end' },
  ],
}

const DEF: ProcessDefinition = {
  id: 'def-harness-register-tenant',
  name: 'platform.register_tenant',
  version: '1',
  description: 'Register a tenant: validate, create, provision and migrate, bind the realm and the first administrator, notify.',
  status: 'ACTIVE',
  graph: GRAPH,
  created_by: 'harness',
  created_at: '2026-11-21T09:00:00Z',
  updated_at: '2026-11-21T09:00:00Z',
}

/** The registered notification templates (`Letflow.NotificationTemplates.Registry`): the key and the NAMES of
 *  the placeholders it accepts. */
const TEMPLATES = {
  items: [
    { template_key: 'tenant_registered', placeholders: ['tenant_name', 'tenant_slug', 'registered_by'] },
    { template_key: 'task_assigned', placeholders: ['task_name', 'process_name', 'assignee_name'] },
  ],
}

/** The platform function catalogue of the tenant family (`Letflow.PlatformFunctions.TenantFamily`). */
const PLATFORM_FUNCTIONS = {
  items: [
    {
      name: 'tenant.validate',
      family: 'platform',
      version: '1',
      permission: 'TenantsManage',
      platform_tenant_only: true,
      idempotency_inputs: ['slug'],
      inputs: [
        { name: 'slug', type: 'string', required: true, source_class: 'start' },
        { name: 'name', type: 'string', required: true, source_class: 'start' },
      ],
      outputs: [],
      side_effects: [{ text: 'reads the tenant registry', class: 'read' }],
    },
    {
      name: 'tenant.create',
      family: 'platform',
      version: '1',
      permission: 'TenantsManage',
      platform_tenant_only: true,
      idempotency_inputs: ['slug'],
      inputs: [
        { name: 'slug', type: 'string', required: true, source_class: 'start' },
        { name: 'name', type: 'string', required: true, source_class: 'start' },
      ],
      outputs: [{ name: 'tenant_id', type: 'uuid' }],
      side_effects: [{ text: 'writes the tenant registry row', class: 'write_tenant_registry' }],
    },
  ],
}

const ROUTES: FixtureRoute[] = [
  { match: (p, m) => m === 'POST' && p.endsWith('/validate'), reply: () => ({ status: 200, body: { status: 'valid', findings: [], definition_id: DEF.id } }) },
  { match: (p, m) => m === 'GET' && p.endsWith(`/definitions/${DEF.id}`), reply: () => ({ status: 200, body: DEF }) },
  { match: (p, m) => m === 'GET' && p.endsWith('/api/v1/notification-templates/catalogue'), reply: () => ({ status: 200, body: TEMPLATES }) },
  { match: (p, m) => m === 'GET' && p.endsWith('/api/v1/platform-functions'), reply: () => ({ status: 200, body: PLATFORM_FUNCTIONS }) },
]

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

export const registerTenantDesignerScreens: HarnessScreen[] = [
  // The registration definition in the designer, as the seed leaves it: a version that runs.
  { name: 'pd-register-tenant', routes: ROUTES, render: () => frame(DEF.name, {}) },
]
