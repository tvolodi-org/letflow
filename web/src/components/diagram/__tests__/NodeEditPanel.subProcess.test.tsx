// @vitest-environment jsdom
/** NodeEditPanel and the sub-process picker (T-2847, PILOT-SUB-4).
 *  S1 a tenant parent is offered only the processes it may call; the module-only stock_receipt is left out and
 *  the reason is said in plain words.  S2 a stock-module parent is offered stock_receipt.  S3 a chosen module-only
 *  child gets a plain message (not "definition not found").  S4 choosing the child shows its declared variables;
 *  ticking writes the node's `interface` (inputs/outputs), a new child drops the old mapping.  S5 ru and kk text.
 *  S6 an unreadable list keeps the plain name field. */
import { useState } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import type { DefinitionGraph, ProcessDefinition } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { NodeEditPanel } from '../NodeEditPanel'
import { readAttrs } from '@/utils/canvas/graphEdit'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
expect.extend(jestDomMatchers)

vi.mock('@/hooks/usePlatformFunctions', () => ({
  usePlatformFunctions: () => ({ data: { items: [] }, isPending: false, error: null, refetch: vi.fn() }),
}))
vi.mock('@/hooks/useNotificationTemplateCatalogue', () => ({
  useNotificationTemplateCatalogue: () => ({ data: { items: [] }, isPending: false, error: null, refetch: vi.fn() }),
}))

const mocks = vi.hoisted(() => ({ list: { current: {} as Record<string, unknown> }, detail: { current: {} as Record<string, unknown> } }))
vi.mock('@/hooks/useSubProcessChildren', () => ({
  useActiveDefinitions: () => mocks.list.current,
  useChildDefinition: () => mocks.detail.current,
}))

const def = (name: string, over: Partial<ProcessDefinition> = {}): ProcessDefinition => ({
  id: `id-${name}`,
  name,
  version: '3',
  status: 'ACTIVE',
  graph: { nodes: [{ id: 'start', node_type: 'START', label: null, attributes: null }], edges: [] },
  created_by: 'u',
  created_at: '',
  updated_at: '',
  ...over,
})

// stock_receipt ships with module_writes and the stock module stamp (module-only child).
const STOCK_RECEIPT = def('stock_receipt', {
  owner_module: 'stock',
  graph: { nodes: [{ id: 'post', node_type: 'HUMAN_TASK', label: null, attributes: { module_writes: [{ kind: 'document' }] } }], edges: [] },
  variable_schemas: [{ variable_key: 'document_id', json_schema: { type: 'string' } }],
})
const PLAIN = def('plain_child', { variable_schemas: [{ variable_key: 'customer_id', json_schema: { type: 'string' } }, { variable_key: 'result' }] })

const graphWith = (attributes: Record<string, unknown>): DefinitionGraph => ({
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'sub', node_type: 'SUB_PROCESS', label: 'Call', attributes },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [],
})

let latest: DefinitionGraph = graphWith({})
function Harness({ attributes, owner = null }: { attributes: Record<string, unknown>; owner?: string | null }) {
  const [graph, setGraph] = useState(() => graphWith(attributes))
  latest = graph
  return (
    <ProcessDiagramIntlProvider>
      <NodeEditPanel
        graph={graph}
        nodeId="sub"
        onApply={(r) => r.ok && setGraph(r.graph)}
        onClose={() => {}}
        onSelectEdge={() => {}}
        problems={[]}
        parentOwnerModule={owner}
      />
    </ProcessDiagramIntlProvider>
  )
}
const subAttrs = () => readAttrs(latest.nodes[1]!)
const options = () => within(screen.getByTestId('edit-field-sub-definition')).getAllByRole('option').map((o) => o.textContent)

beforeEach(() => {
  useUiLocaleStore.getState().setLocale('en')
  mocks.list.current = { data: { items: [STOCK_RECEIPT, PLAIN] }, isPending: false, error: null }
  mocks.detail.current = { data: PLAIN, isPending: false, error: null }
})
afterEach(cleanup)

describe('NodeEditPanel — the sub-process picker', () => {
  it('S1 a tenant parent is offered only callable processes and told why stock_receipt is missing', () => {
    render(<Harness attributes={{}} />)
    expect(options().join('|')).toContain('plain_child (version 3)')
    expect(options().join('|')).not.toContain('stock_receipt')
    expect(screen.getByTestId('sub-module-only')).toHaveTextContent('1 process is not listed')
    expect(screen.getByTestId('sub-module-only')).toHaveTextContent('only a process of the same module')
  })

  it('S2 a stock-module parent is offered stock_receipt; another module is not', () => {
    const { unmount } = render(<Harness attributes={{}} owner="stock" />)
    expect(options().join('|')).toContain('stock_receipt (version 3)')
    expect(screen.queryByTestId('sub-module-only')).not.toBeInTheDocument()
    unmount()
    render(<Harness attributes={{}} owner="assets" />)
    expect(options().join('|')).not.toContain('stock_receipt')
  })

  it('S3 a chosen module-only child from a tenant parent gets a plain message', () => {
    render(<Harness attributes={{ definition_name: 'stock_receipt' }} />)
    const msg = screen.getByTestId('sub-chosen-refused')
    expect(msg).toHaveTextContent('belongs to a module')
    expect(msg).not.toHaveTextContent(/not[ _]found/i)
    expect(screen.queryByTestId('sub-variables')).not.toBeInTheDocument()
  })

  it('S4 the child variables are shown; ticking writes the interface; a new child drops it', () => {
    render(<Harness attributes={{}} />)
    fireEvent.change(within(screen.getByTestId('edit-field-sub-definition')).getByRole('combobox'), { target: { value: 'plain_child' } })
    expect(subAttrs().definition_name).toBe('plain_child')
    expect(subAttrs().interface).toBeUndefined()
    expect(screen.getByTestId('sub-var-customer_id')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('sub-in-customer_id'))
    fireEvent.click(screen.getByTestId('sub-out-result'))
    expect(subAttrs().interface).toEqual({
      inputs: [{ name: 'customer_id', json_schema: { type: 'string' }, required: false }],
      outputs: [{ name: 'result', json_schema: {}, required: false }],
    })
    fireEvent.click(screen.getByTestId('sub-in-customer_id'))
    expect((subAttrs().interface as { inputs: unknown[] }).inputs).toEqual([])
    fireEvent.change(within(screen.getByTestId('edit-field-sub-definition')).getByRole('combobox'), { target: { value: '' } })
    expect(subAttrs().interface).toBeUndefined()
    expect(subAttrs().definition_name).toBeUndefined()
  })

  it('S5 the picker text is in ru and kk', () => {
    useUiLocaleStore.getState().setLocale('ru')
    const { unmount } = render(<Harness attributes={{ definition_name: 'stock_receipt' }} />)
    expect(screen.getByTestId('sub-chosen-refused')).toHaveTextContent('принадлежит модулю')
    expect(screen.getByTestId('sub-module-only')).toHaveTextContent('только процесс того же модуля')
    unmount()
    useUiLocaleStore.getState().setLocale('kk')
    render(<Harness attributes={{ definition_name: 'stock_receipt' }} />)
    expect(screen.getByTestId('sub-chosen-refused')).toHaveTextContent('модульге тиесілі')
  })

  it('S6 an unreadable list keeps the plain name field', () => {
    mocks.list.current = { data: undefined, isPending: false, error: { status: 500 } }
    render(<Harness attributes={{}} />)
    fireEvent.change(screen.getByTestId('edit-field-sub-definition'), { target: { value: 'x_flow' } })
    expect(subAttrs().definition_name).toBe('x_flow')
    expect(screen.getByTestId('sub-error')).toBeInTheDocument()
  })
})
