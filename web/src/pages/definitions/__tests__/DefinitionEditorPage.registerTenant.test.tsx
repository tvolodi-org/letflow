// @vitest-environment jsdom
/**
 * T-2738 (pilot gap G9c): the platform operator opens `platform.register_tenant` in the designer on QA and the page
 * showed the error boundary (React error 185, maximum update depth). The component tests passed because they mount
 * the edit pane alone with the hooks mocked. This one goes through the REAL page component, the REAL edit pane and
 * the REAL catalogue hooks, with only the network layer faked, and opens the shipped graph.
 * R1 the diagram edit view renders with the platform_call and the notify steps (no error boundary),
 * R2 a platform_call step opens its panel with the function picker, R3 the notify step opens its settings.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, render, fireEvent, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Component, type ReactNode } from 'react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
expect.extend(jestDomMatchers)

globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as unknown as typeof ResizeObserver

vi.mock('@/components/canvas/NodePalette', () => ({ default: () => <div /> }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => <div /> }))
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useParams: vi.fn(), useBlocker: vi.fn(() => ({ state: 'unblocked' as const })) }
})
vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useValidateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useActivateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/auth/useTenantContext', () => ({ useTenantContext: vi.fn() }))
vi.mock('@/api/definitions', () => ({
  definitionsApi: { promote: vi.fn(), exportJson: vi.fn(), update: vi.fn(), validate: vi.fn().mockRejectedValue({ status: 422, details: [{ code: 'variable_never_collected', message: 'x' }, { code: 'undeclared_variable_reference', message: 'y' }] }) },
}))
// The catalogue as the server publishes it (`TenantFamily`): all five functions the graph calls, with the real
// input types (the id of a tenant is a uuid, the slug a string) and source classes.
vi.mock('@/api/platformFunctions', () => {
  const inp = (name: string, type: string, source_class: string) => ({ name, type, required: true, source_class })
  const entry = (name: string, inputs: unknown[], outputs: unknown[], idem: string[]) => ({
    name,
    family: 'platform',
    version: '1',
    permission: 'TenantsManage',
    platform_tenant_only: true,
    idempotency_inputs: idem,
    inputs,
    outputs,
    side_effects: [{ text: 'writes', class: 'write_tenant_registry' }],
  })
  const items = [
    entry('tenant.validate', [inp('slug', 'string', 'start'), inp('name', 'string', 'start')], [], ['slug']),
    entry('tenant.create', [inp('slug', 'string', 'start'), inp('name', 'string', 'start')], [{ name: 'tenant_id', type: 'uuid' }], ['slug']),
    entry('tenant.provision', [inp('tenant_id', 'uuid', 'step')], [{ name: 'schema_name', type: 'string' }], ['tenant_id']),
    entry('tenant.bind_realm', [inp('tenant_id', 'uuid', 'step'), inp('realm_id', 'string', 'start')], [], ['tenant_id']),
    entry('tenant.grant_first_admins', [inp('tenant_id', 'uuid', 'step'), inp('admin_email', 'string', 'start')], [], ['tenant_id']),
    entry('tenant.install_default_modules', [inp('tenant_id', 'uuid', 'step')], [], ['tenant_id']),
  ]
  return { platformFunctionsApi: { list: vi.fn().mockResolvedValue({ items }) } }
})
vi.mock('@/api/notificationTemplates', async () => {
  const f = await import('@/dev/harness/fixtures/registerTenantDesigner')
  return { notificationTemplatesApi: { catalogue: vi.fn().mockResolvedValue(f.TEMPLATES), list: vi.fn().mockResolvedValue(f.TEMPLATES) } }
})

import { useParams } from 'react-router-dom'
import { useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { DEF as FIXTURE_DEF } from '@/dev/harness/fixtures/registerTenantDesigner'

// T-2742: the graph is the document the SEED writes (`Letflow.PlatformProcesses.Definition.graph/0`), read from the
// copy `definition_test.exs` keeps equal to it -- not a hand-made fixture. It carries no `label` and no `attributes`
// key on a node that has none, exactly as the server sends it.
const SEED_GRAPH = JSON.parse(readFileSync(resolve(process.cwd(), '../test/fixtures/platform_processes/register_tenant_graph.json'), 'utf8'))
const DEF = { ...FIXTURE_DEF, graph: SEED_GRAPH } as unknown as typeof FIXTURE_DEF

class Boundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null }
  static getDerivedStateFromError(error: Error) {
    return { error }
  }
  render() {
    return this.state.error ? <div data-testid="boundary">{this.state.error.message}</div> : this.props.children
  }
}

function arrange(status: string = DEF.status) {
  vi.mocked(useParams).mockReturnValue({ id: DEF.id })
  vi.mocked(useDefinition).mockReturnValue({ data: { ...DEF, status }, isLoading: false, isError: false, error: null, refetch: vi.fn() } as unknown as ReturnType<typeof useDefinition>)
  vi.mocked(useAuth).mockReturnValue({
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    session: { token: 't', display_name: 'Op', tenant_slug: 'platform', tenant_id: 'tid-platform', tenant_type: 'platform' },
  } as unknown as ReturnType<typeof useAuth>)
  vi.mocked(useTenantContext).mockReturnValue({
    tenantType: 'platform',
    tenantSlug: 'platform',
    tenantId: 'tid-platform',
    tenantDisplayName: 'Platform',
    isUnknown: false,
  } as unknown as ReturnType<typeof useTenantContext>)
}

async function openPage(status?: string) {
  arrange(status)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  vi.spyOn(console, 'error').mockImplementation(() => {})
  render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={accessState('platformAdmin')}>
        <MemoryRouter>
          <Boundary>
            <DefinitionEditorPage />
          </Boundary>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

async function openEditView() {
  await openPage()
  const user = userEvent.setup()
  await user.click(await screen.findByTestId('definition-view-edit'))
  return user
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('T-2738 platform.register_tenant in the real designer page', () => {
  it('R0 renders the shipped graph default view (does not cover the render loop)', async () => {
    await openPage()
    expect(await screen.findByTestId('definition-view-edit')).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 1500))
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it('R0b renders a DRAFT copy in the Editor view (does not cover the render loop)', async () => {
    await openPage('DRAFT')
    expect(await screen.findByTestId('definition-editor-view')).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 1500))
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it('R1 renders the shipped graph steps (does not cover the render loop)', async () => {
    await openEditView()
    expect(await screen.findByTestId('rf__node-notify', {}, { timeout: 8000 })).toBeInTheDocument()
    expect(screen.getByTestId('rf__node-validate')).toBeInTheDocument()
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it.each(['validate', 'create', 'provision', 'bind_realm', 'grant_first_admins'])('R2 renders the platform_call step %s panel (does not cover the render loop)', async (id) => {
    await openEditView()
    fireEvent.click(await screen.findByTestId(`rf__node-${id}`, {}, { timeout: 8000 }))
    expect(await screen.findByTestId('edit-platform-call')).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 300))
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it('R3 renders the notify step settings (does not cover the render loop)', async () => {
    await openEditView()
    fireEvent.click(await screen.findByTestId('rf__node-notify', {}, { timeout: 8000 }))
    await waitFor(() => expect(screen.getByDisplayValue('tenant_registered')).toBeInTheDocument())
    expect(screen.queryByTestId('boundary')).toBeNull()
  })
})

describe('T-2742 the designer shows the shipped platform_call steps', () => {
  it('S1 the read-only diagram labels the steps by the function names, not "Service task"', async () => {
    await openPage()
    for (const fn of ['validate', 'create', 'provision', 'bind_realm', 'grant_first_admins', 'notify']) {
      const node = await screen.findByTestId(`rf__node-${fn}`, {}, { timeout: 8000 })
      expect(node).toHaveTextContent(fn)
      expect(node).not.toHaveTextContent(/Service task/i)
    }
  })

  it('S2 the read-only side panel of a platform_call step names the function; no "other attributes"', async () => {
    await openPage()
    fireEvent.click(await screen.findByTestId('rf__node-validate', {}, { timeout: 8000 }))
    expect(await screen.findByTestId('details-platform-function')).toHaveTextContent('tenant.validate')
    expect(screen.queryByText(/other attributes/i)).toBeNull()
  })

  it('S3 the read-only side panel of the notify step names the template and the recipient variable', async () => {
    await openPage()
    fireEvent.click(await screen.findByTestId('rf__node-notify', {}, { timeout: 8000 }))
    expect(await screen.findByTestId('details-notify-template')).toHaveTextContent('tenant_registered')
    expect(screen.getByTestId('diagram-node-details')).toHaveTextContent('admin_email')
    expect(screen.queryByText(/other attributes/i)).toBeNull()
  })

  it('S4 the edit view labels the nodes by function and its panel has the function picker', async () => {
    await openEditView()
    const node = await screen.findByTestId('rf__node-provision', {}, { timeout: 8000 })
    expect(node).toHaveTextContent('provision')
    expect(node).not.toHaveTextContent(/Service task/i)
    fireEvent.click(node)
    expect(await screen.findByTestId('edit-platform-call')).toBeInTheDocument()
    await waitFor(() => expect(within(screen.getByTestId('platform-call-editor')).getByDisplayValue('tenant.provision')).toBeInTheDocument())
    expect(await screen.findByTestId('platform-arg-var-tenant_id')).toHaveValue('tenant_id')
  })

  it('S5 the notify step in the edit view has the template picker with the registered key', async () => {
    await openEditView()
    const node = await screen.findByTestId('rf__node-notify', {}, { timeout: 8000 })
    expect(node).toHaveTextContent('notify')
    fireEvent.click(node)
    await waitFor(() => expect(screen.getByDisplayValue('tenant_registered')).toBeInTheDocument())
    expect(screen.getByTestId('notify-step-recipient')).toHaveValue('admin_email')
  })

  it('S6 a fresh open of the shipped definition shows no "unsaved local draft" banner (Viewer and Editor views)', async () => {
    await openPage()
    await screen.findByTestId('definition-view-edit')
    await new Promise((r) => setTimeout(r, 1000))
    expect(screen.queryByTestId('draft-banner')).toBeNull()
    cleanup()
    await openPage('DRAFT')
    await screen.findByTestId('definition-editor-view')
    await new Promise((r) => setTimeout(r, 1500))
    expect(screen.queryByTestId('draft-banner')).toBeNull()
  })
})
