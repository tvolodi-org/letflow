// @vitest-environment jsdom
/** T-2811 (designer D1): a notification step names its recipient as a DECLARED variable, and the Edit-diagram screen lets
 *  the user declare one. V1 the undeclared name gives an error that names the fix, V2 the user declares the variable on
 *  the screen and the problem goes, V3 the recipient field is a picker of the declared variables with an "add" entry,
 *  V4 the declaration is saved with the graph, V5 the labels exist in en, ru and kk. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { DeclaredVariable, ProcessDefinition } from '@/types/api'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { DiagramEditPane } from '../DiagramEditPane'
expect.extend(jestDomMatchers)

vi.mock('@/api/definitions', () => ({
  definitionsApi: { update: vi.fn(), create: vi.fn(), get: vi.fn(), validate: vi.fn() },
}))
import { definitionsApi } from '@/api/definitions'

vi.mock('@/hooks/usePlatformFunctions', () => ({
  usePlatformFunctions: () => ({ data: { items: [] }, isPending: false, error: null, refetch: vi.fn() }),
}))
vi.mock('@/hooks/useNotificationTemplateCatalogue', () => ({
  useNotificationTemplateCatalogue: () => ({
    data: { items: [{ template_key: 'tenant_registered', placeholders: ['tenant_name'] }] },
    isPending: false,
    error: null,
    refetch: vi.fn(),
  }),
}))

class RO {
  constructor(private cb: ResizeObserverCallback) {}
  observe(el: Element) {
    this.cb([{ contentRect: { width: 1200, height: 600 }, target: el } as unknown as ResizeObserverEntry], this as unknown as ResizeObserver)
  }
  unobserve() {}
  disconnect() {}
}
Object.defineProperties(window.HTMLElement.prototype, {
  offsetHeight: { configurable: true, get: () => 600 },
  offsetWidth: { configurable: true, get: () => 1000 },
})

const UNDECLARED = { code: 'step_mapping_variable_undeclared', message: "Node 'notify' reads mapping admin_email: the variable is not among the definition's declared variable schemas" }

beforeEach(() => {
  vi.stubGlobal('ResizeObserver', RO)
  vi.stubGlobal('DOMMatrixReadOnly', class { m22 = 1 })
  // The server's rule, in miniature: the recipient must be among the variables the screen sends.
  vi.mocked(definitionsApi.validate).mockImplementation(async (_id, _graph, vars?: DeclaredVariable[]) => {
    if ((vars ?? []).some((v) => v.variable_key === 'admin_email')) return { status: 'valid', definition_id: 'd', findings: [] }
    throw Object.assign(new Error('invalid'), { status: 422, details: [UNDECLARED] })
  })
  vi.mocked(definitionsApi.update).mockImplementation(async (_id, body) => ({ ...DEF, graph: (body.graph ?? DEF.graph) as ProcessDefinition['graph'] }))
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.unstubAllGlobals()
})

const DEF: ProcessDefinition = {
  id: 'def-1',
  name: 'Register',
  version: '1.0.0',
  status: 'DRAFT',
  created_by: 'u',
  created_at: '2026-11-01T00:00:00Z',
  updated_at: '2026-11-02T00:00:00Z',
  variable_schemas: [{ variable_key: 'tenant_name', json_schema: { type: 'string' } }],
  graph: {
    nodes: [
      { id: 'start', node_type: 'START', label: null, attributes: { position: { x: 0, y: 0 } } },
      {
        id: 'notify',
        node_type: 'SERVICE_TASK',
        label: 'Notify',
        attributes: { position: { x: 0, y: 100 }, notify: { channel: 'email', template_key: 'tenant_registered', recipient: { var: 'admin_email' }, values: {} } },
      },
      { id: 'end', node_type: 'END', label: null, attributes: { position: { x: 0, y: 200 } } },
    ],
    edges: [
      { id: 'e1', source: 'start', target: 'notify' },
      { id: 'e2', source: 'notify', target: 'end' },
    ],
  },
}

function mount() {
  const qc = new QueryClient()
  return render(
    <QueryClientProvider client={qc}>
      <ProcessDiagramIntlProvider>
        <DiagramEditPane def={DEF} editorDirty={false} onDirtyChange={vi.fn()} onSaved={vi.fn()} onReload={vi.fn()} demo={{ selected: { kind: 'node', id: 'notify' } }} tenantId="t1" />
      </ProcessDiagramIntlProvider>
    </QueryClientProvider>,
  )
}

const declare = (name: string) => {
  fireEvent.change(screen.getByTestId('variables-add-name'), { target: { value: name } })
  fireEvent.click(screen.getByTestId('variables-add-submit'))
}

describe('T-2811 declaring a variable on the Edit-diagram screen', () => {
  it('V1 the undeclared recipient gives an error that names the fix', async () => {
    mount()
    const v = await screen.findByTestId('edit-violation', undefined, { timeout: 4000 })
    expect(v).toHaveTextContent(/Declare this variable under "Process variables"/)
  })

  it('V2 the user declares the variable on the screen and the problem disappears', async () => {
    mount()
    await screen.findByTestId('edit-violation', undefined, { timeout: 4000 })
    expect(screen.getByTestId('variable-row-tenant_name')).toBeInTheDocument()
    declare('admin_email')
    expect(screen.getByTestId('variable-row-admin_email')).toHaveTextContent('Added here, not saved yet')
    await waitFor(() => expect(screen.queryByTestId('edit-violation')).not.toBeInTheDocument(), { timeout: 4000 })
  })

  it('V3 the recipient is a picker of the declared variables with an add entry', async () => {
    mount()
    const picker = await screen.findByTestId('notify-step-recipient')
    const select = within(picker).getByRole('combobox')
    const labels = Array.from(select.querySelectorAll('option')).map((o) => o.textContent)
    expect(labels).toContain('tenant_name (string)')
    expect(labels.some((l) => l?.startsWith('admin_email') && l.includes('not declared'))).toBe(true)
    fireEvent.change(select, { target: { value: '__add_variable__' } })
    fireEvent.change(screen.getByTestId('notify-step-recipient-add-name'), { target: { value: 'admin_email' } })
    fireEvent.click(screen.getByTestId('notify-step-recipient-add-submit'))
    expect(screen.getByTestId('variable-row-admin_email')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByTestId('edit-violation')).not.toBeInTheDocument(), { timeout: 4000 })
  })

  it('V3b a name that is already declared or not usable is refused with words', async () => {
    mount()
    await screen.findByTestId('variables-panel')
    declare('tenant_name')
    expect(screen.getByTestId('variables-panel')).toHaveTextContent('already declared')
    declare('a.b')
    expect(screen.getByTestId('variables-panel')).toHaveTextContent('plain name')
  })

  it('V4 the declaration is saved with the graph', async () => {
    mount()
    await screen.findByTestId('edit-violation', undefined, { timeout: 4000 })
    declare('admin_email')
    await waitFor(() => expect(screen.queryByTestId('edit-violation')).not.toBeInTheDocument(), { timeout: 4000 })
    fireEvent.click(screen.getByTestId('edit-save'))
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalled())
    const body = vi.mocked(definitionsApi.update).mock.calls[0]![1]
    expect(body.variable_schemas).toEqual([
      { variable_key: 'tenant_name', json_schema: { type: 'string' } },
      { variable_key: 'admin_email', json_schema: { type: 'string' } },
    ])
  })

  it('V5 every label exists in en, ru and kk', () => {
    const keys = Object.keys(processDiagramMessages.en).filter((k) => k.startsWith('processDiagram.edit.vars.'))
    expect(keys.length).toBeGreaterThan(15)
    for (const k of keys) {
      expect(processDiagramMessages.ru[k], k).toBeTruthy()
      expect(processDiagramMessages.kk[k], k).toBeTruthy()
    }
  })
})
