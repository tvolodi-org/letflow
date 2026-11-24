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
import { screen, cleanup, waitFor, render, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { Component, type ReactNode } from 'react'
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
import { DEF as FIXTURE_DEF } from '@/dev/harness/fixtures/registerTenantDesigner'

// The document as the SERVER sends it: `Definition.graph/0` carries no `label` and no `attributes` key on a node
// that has none (the harness fixture writes explicit nulls), and the id of the screen is the real one's.
const strip = <T extends Record<string, unknown>>(o: T) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined))
const DEF = { ...FIXTURE_DEF, graph: { ...FIXTURE_DEF.graph, nodes: FIXTURE_DEF.graph.nodes.map((n) => strip(n as unknown as Record<string, unknown>)) } } as unknown as typeof FIXTURE_DEF

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
  it('R0 opening the page shows the default view without the error boundary', async () => {
    await openPage()
    expect(await screen.findByTestId('definition-view-edit')).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 1500))
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it('R0b a DRAFT copy opens in the canvas Editor view without the error boundary', async () => {
    await openPage('DRAFT')
    expect(await screen.findByTestId('definition-editor-view')).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 1500))
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it('R1 renders the steps without the error boundary', async () => {
    await openEditView()
    expect(await screen.findByTestId('rf__node-notify', {}, { timeout: 8000 })).toBeInTheDocument()
    expect(screen.getByTestId('rf__node-validate')).toBeInTheDocument()
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it.each(['validate', 'create', 'provision', 'bind_realm', 'grant_first_admins'])('R2 the platform_call step %s opens its panel with the function picker', async (id) => {
    await openEditView()
    fireEvent.click(await screen.findByTestId(`rf__node-${id}`, {}, { timeout: 8000 }))
    expect(await screen.findByTestId('edit-platform-call')).toBeInTheDocument()
    await new Promise((r) => setTimeout(r, 300))
    expect(screen.queryByTestId('boundary')).toBeNull()
  })

  it('R3 the notify step opens its settings', async () => {
    await openEditView()
    fireEvent.click(await screen.findByTestId('rf__node-notify', {}, { timeout: 8000 }))
    await waitFor(() => expect(screen.getByDisplayValue('tenant_registered')).toBeInTheDocument())
    expect(screen.queryByTestId('boundary')).toBeNull()
  })
})
