// @vitest-environment jsdom
/** NodeEditPanel and the platform call (T-2599, pilot gap G5a): the step panel shows the function picker for a
 *  step that calls a platform function, and the route kinds of a step stay EXCLUSIVE — a step carries a platform
 *  call OR a script, never both (the server refuses a node that carries both).
 *  N1 the picker is shown with the function and its arguments, N2 the step can be switched onto a platform
 *  function (the script binding is dropped), N3 a platform call can be dropped for a script, N4 the announcement of
 *  that drop names the platform call (a platform call replaces no service binding and asks for no script key). */
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import type { DefinitionGraph, PlatformFunctionEntry } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { NodeEditPanel } from '../NodeEditPanel'
import { readAttrs } from '@/utils/canvas/graphEdit'
expect.extend(jestDomMatchers)

// T-2599: the panel reads the COMPILED catalogue through a tenant-scoped query; the answer is fixed here so the
// test says what the picker does with it.
vi.mock('@/hooks/usePlatformFunctions', () => ({
  usePlatformFunctions: () => ({ data: { items: CATALOGUE_ENTRIES }, isPending: false, error: null, refetch: vi.fn() }),
}))

afterEach(cleanup)

const ENTRY: PlatformFunctionEntry = {
  name: 'platform.validate_registration',
  family: 'platform',
  version: '1',
  permission: 'TenantsManage',
  platform_tenant_only: true,
  idempotency_inputs: ['slug'],
  inputs: [{ name: 'slug', type: 'string', required: true, source_class: 'start' }],
  outputs: [{ name: 'normalized_slug', type: 'string' }],
  side_effects: [{ text: 'reads nothing and writes nothing', class: 'read' }],
}

const CATALOGUE_ENTRIES = [ENTRY]

const graphWith = (attributes: Record<string, unknown>): DefinitionGraph => ({
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'call', node_type: 'SERVICE_TASK', label: 'Call', attributes },
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

describe('NodeEditPanel — the platform call', () => {
  it('N1 the picker is shown with the function and its arguments', () => {
    render(
      <Harness
        attributes={{
          platform_call: {
            function: 'platform.validate_registration',
            args: { slug: { var: 'tenant_slug' } },
            reads: { tenant_slug: 'string' },
            writes: {},
          },
        }}
      />,
    )
    expect(screen.getByTestId('edit-platform-call')).toBeInTheDocument()
    expect(screen.getByTestId('platform-call-function')).toBeInTheDocument()
    expect(screen.getByTestId('platform-arg-slug')).toBeInTheDocument()
    expect(screen.queryByTestId('edit-field-script-key')).not.toBeInTheDocument()
  })

  it('N2 the step can be switched onto a platform function; the script binding is dropped', () => {
    render(<Harness attributes={{ script_key: 'budget_check', script_version: 1 }} />)
    expect(screen.getByTestId('edit-field-script-key')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('edit-use-platform-function'))
    const attrs = callAttrs()
    expect(attrs.platform_call).toMatchObject({ function: 'platform.validate_registration' })
    expect(attrs.script_key).toBeUndefined()
    expect(attrs.script_version).toBeUndefined()
  })

  it('N3 a platform call can be dropped for a script', () => {
    render(
      <Harness
        attributes={{
          platform_call: { function: 'platform.validate_registration', args: {}, reads: {}, writes: {} },
        }}
      />,
    )
    fireEvent.click(screen.getByTestId('edit-use-script-from-platform'))
    expect(callAttrs().platform_call).toBeUndefined()
    // The announcement names the platform call: no service binding was replaced and no script key is asked for.
    expect(announced).toBe('The platform function was removed; the step has no route until a script is named.')
    expect(announced).not.toContain('Service binding replaced by a script')
  })
})
