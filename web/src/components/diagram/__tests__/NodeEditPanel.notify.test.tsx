// @vitest-environment jsdom
/** NodeEditPanel and the notification step (T-2600, pilot gap G5b): the step panel shows the notification
 *  form for a step that sends a notification, and the route kinds of a step stay EXCLUSIVE — a step carries a
 *  notification OR a script, never both (the server refuses a node that carries both).
 *  N1 the notification form is shown with the channel and the template, N2 the step can be switched onto a
 *  notification (the script binding is dropped), N3 a notification can be dropped for a script, N4 the
 *  announcement of that drop names the notification. */
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import type { DefinitionGraph } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { NodeEditPanel } from '../NodeEditPanel'
import { readAttrs } from '@/utils/canvas/graphEdit'
expect.extend(jestDomMatchers)

// The platform function catalogue is read by the same panel (T-2599); this test is about the notification
// form, so that read is mocked away.
vi.mock('@/hooks/usePlatformFunctions', () => ({
  usePlatformFunctions: () => ({ data: { items: [] }, isPending: false, error: null, refetch: vi.fn() }),
}))

// T-2600: the panel reads the COMPILED template catalogue through a tenant-scoped query; the answer is fixed
// here so the test says what the form does with it.
vi.mock('@/hooks/useNotificationTemplateCatalogue', () => ({
  useNotificationTemplateCatalogue: () => ({
    data: { items: CATALOGUE_ITEMS },
    isPending: false,
    error: null,
    refetch: vi.fn(),
  }),
}))

afterEach(cleanup)

const CATALOGUE_ITEMS = [
  { template_key: 'tenant_registered', placeholders: ['tenant_name', 'tenant_slug', 'registered_by'] },
  { template_key: 'task_assigned', placeholders: ['task_name'] },
]

const graphWith = (attributes: Record<string, unknown>): DefinitionGraph => ({
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'call', node_type: 'SERVICE_TASK', label: 'Notify', attributes },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'call' },
    { id: 'e2', source: 'call', target: 'end' },
  ],
})

let latest: DefinitionGraph = graphWith({})
let announced = ''

function Harness({ attributes }: { attributes: Record<string, unknown> }) {
  const [graph, setGraph] = useState(() => graphWith(attributes))
  latest = graph
  return (
    <ProcessDiagramIntlProvider>
      <NodeEditPanel
        graph={graph}
        nodeId="call"
        onApply={(result, announce) => {
          if (result.ok) setGraph(result.graph)
          announced = announce ?? ''
        }}
        onClose={() => {}}
        onSelectEdge={() => {}}
        problems={[]}
      />
    </ProcessDiagramIntlProvider>
  )
}

const callAttrs = () => readAttrs(latest.nodes[1]!)

describe('NodeEditPanel — the notification step', () => {
  it('N1 the notification form is shown with the channel and the template', () => {
    render(
      <Harness
        attributes={{
          notify: {
            channel: 'email',
            template_key: 'tenant_registered',
            recipient: { var: 'admin_email' },
            values: { tenant_name: { var: 'tenant_name' } },
          },
        }}
      />,
    )
    expect(screen.getByTestId('edit-notify-step')).toBeInTheDocument()
    expect(screen.getByTestId('notify-step-editor')).toBeInTheDocument()
    expect(screen.getByTestId('notify-step-recipient')).toBeInTheDocument()
    expect(screen.queryByTestId('edit-field-script-key')).not.toBeInTheDocument()
  })

  it('N2 the step can be switched onto a notification; the script binding is dropped', () => {
    render(<Harness attributes={{ script_key: 'budget_check', script_version: 1 }} />)
    expect(screen.getByTestId('edit-field-script-key')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('edit-use-notification'))
    const attrs = callAttrs()
    expect(attrs.notify).toMatchObject({ template_key: 'tenant_registered' })
    expect(attrs.script_key).toBeUndefined()
    expect(attrs.script_version).toBeUndefined()
  })

  it('N3 a notification can be dropped for a script', () => {
    render(
      <Harness
        attributes={{
          notify: {
            channel: 'email',
            template_key: 'tenant_registered',
            recipient: { var: 'admin_email' },
            values: {},
          },
        }}
      />,
    )
    fireEvent.click(screen.getByTestId('edit-use-script-from-notify'))
    expect(callAttrs().notify).toBeUndefined()
    expect(screen.getByTestId('edit-field-script-key')).toBeInTheDocument()
  })

  it('N4 the announcement of that drop names the notification', () => {
    render(
      <Harness
        attributes={{
          notify: {
            channel: 'email',
            template_key: 'tenant_registered',
            recipient: { var: 'admin_email' },
            values: {},
          },
        }}
      />,
    )
    fireEvent.click(screen.getByTestId('edit-use-script-from-notify'))
    expect(announced).toBe('The notification was removed; the step has no route until a script is named.')
  })
})
