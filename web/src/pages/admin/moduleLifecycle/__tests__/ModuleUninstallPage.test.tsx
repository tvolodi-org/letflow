// @vitest-environment jsdom
/**
 * REQ-630 — module lifecycle admin page: gating (G), uninstall (U), open work (O), uniform 404 (N),
 * other answers (X), reactivate (R). The API client is mocked at the module boundary; the real
 * router element, access gate, react-query hooks and page run.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES, accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { P } from '@/auth/access'
import { NAV_ITEMS } from '@/components/layout/AppShell'
import { router } from '@/router'
import { FORBIDDEN_MESSAGE, GENERIC_MESSAGE, NOT_FOUND_MESSAGE, describeModuleTransitionError } from '../moduleLifecycleErrors'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    isAuthenticated: true,
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: null,
      tenant_slug: 'fixture-co',
      tenant_display_name: 'Fixture Co',
      tenant_id: 'tid-fixture-co',
      tenant_type: 'production',
    },
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))

vi.mock('@/api/client', () => ({
  client: { get: vi.fn(), post: vi.fn() },
}))

import { client } from '@/api/client'

const PATH = 'admin/module-lifecycle'
// Versions carry no digits so the whole page text can be checked for stray numbers.
const MODULES = [
  { module_id: 'exam', version: 'alpha' },
  { module_id: 'wms', version: 'beta' },
]

function renderRoute(fixture: AccessFixtureName) {
  const root = router.routes.find((r) => r.path === '/')
  const element = root?.children?.find((c) => c.path === PATH)?.element
  if (!element) throw new Error('route not found')
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={accessState(fixture)}>
        <MemoryRouter initialEntries={['/' + PATH]}>
          <Routes>
            <Route path={'/' + PATH} element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const modulesGets = () => vi.mocked(client.get).mock.calls.filter((c) => c[0] === '/api/v1/me/modules').length
const apiError = (status: number, details: unknown) => Object.assign(new Error('x'), { status, details })

beforeEach(() => {
  vi.stubEnv('VITE_MODULES_UNINSTALL_ENABLED', 'true')
  vi.mocked(client.get).mockResolvedValue({ installed_modules: MODULES })
  vi.mocked(client.post).mockReset()
})
afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  vi.clearAllMocks()
})

async function uninstall(id: string, rationale: string) {
  fireEvent.change(await screen.findByTestId('uninstall-rationale'), { target: { value: rationale } })
  fireEvent.click(await screen.findByTestId(`uninstall-${id}`))
  fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
}

function reactivate(id: string, rationale: string) {
  fireEvent.change(screen.getByTestId('reactivate-module-id'), { target: { value: id } })
  fireEvent.change(screen.getByTestId('reactivate-rationale'), { target: { value: rationale } })
  fireEvent.click(screen.getByTestId('reactivate-submit'))
}

describe('G gating', () => {
  it('G1 holder with the flag on sees the page; nav entry is gated by ModulesManage', async () => {
    renderRoute('tenantAdmin')
    expect(await screen.findByRole('heading', { name: 'Module lifecycle' })).toBeInTheDocument()
    const item = NAV_ITEMS.find((n) => n.to === '/admin/module-lifecycle')
    expect(item?.label).toBe('Module lifecycle')
    expect(item?.permission).toBe(P.ModulesManage)
    expect(item?.enabled?.()).toBe(true)
  })

  const NON_HOLDERS = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter(
    (k) => !(ACCESS_FIXTURES[k].permissions as readonly string[]).includes(P.ModulesManage),
  )
  it('G2 non-holders get PermissionDenied and no request', () => {
    expect(NON_HOLDERS.length).toBeGreaterThan(0)
    for (const f of NON_HOLDERS) {
      renderRoute(f)
      expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
      expect(screen.queryByRole('heading', { name: 'Module lifecycle' })).toBeNull()
      cleanup()
    }
    expect(client.get).not.toHaveBeenCalled()
  })

  it('G3 flag off renders not-found and the nav entry is hidden', () => {
    vi.stubEnv('VITE_MODULES_UNINSTALL_ENABLED', '')
    renderRoute('tenantAdmin')
    expect(screen.getByTestId('not-found-page')).toBeInTheDocument()
    expect(NAV_ITEMS.find((n) => n.to === '/admin/module-lifecycle')?.enabled?.()).toBe(false)
    expect(client.get).not.toHaveBeenCalled()
  })

  it('G4 no new permission atom', () => {
    expect(P.ModulesManage).toBe('ModulesManage')
    expect(Object.keys(P).filter((k) => /Uninstall|Lifecycle/.test(k))).toEqual([])
  })
})

describe('U uninstall happy path', () => {
  it('U1 blank rationale disables; confirm posts once; success shown; list refetched', async () => {
    renderRoute('tenantAdmin')
    const btn = await screen.findByTestId('uninstall-exam')
    expect(btn).toBeDisabled()
    fireEvent.change(screen.getByTestId('uninstall-rationale'), { target: { value: '   ' } })
    expect(btn).toBeDisabled()
    expect(screen.getByText('wms')).toBeInTheDocument()

    vi.mocked(client.post).mockResolvedValue({ module_id: 'exam', status: 'uninstalled' })
    const before = modulesGets()
    await uninstall('exam', 'closing the pilot')
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Module exam is now uninstalled.'))
    expect(client.post).toHaveBeenCalledTimes(1)
    expect(client.post).toHaveBeenCalledWith('/api/v1/tenant/modules/exam/uninstall', { rationale: 'closing the pilot' })
    await waitFor(() => expect(modulesGets()).toBeGreaterThan(before))
  })
})

describe('O open work', () => {
  it('O1 shows both counts, no success, keeps the list and the input', async () => {
    renderRoute('tenantAdmin')
    vi.mocked(client.post).mockRejectedValue(apiError(409, { code: 'open_work_exists', open_instances: 2, open_tasks: 3 }))
    await uninstall('exam', 'closing the pilot')
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('Open instances: 2')
    expect(alert).toHaveTextContent('Open tasks: 3')
    // AC "no other number": the alert holds exactly the digits 2 and 3.
    expect(alert.textContent?.match(/\d+/g)).toEqual(['2', '3'])
    expect(screen.queryByRole('status')).toBeNull()
    expect(screen.getByText('exam')).toBeInTheDocument()
    expect(screen.getByTestId('uninstall-rationale')).toHaveValue('closing the pilot')
  })
})

describe('N uniform 404', () => {
  it('N1 uninstall and reactivate show one text, free of flag or state hints', async () => {
    renderRoute('tenantAdmin')
    vi.mocked(client.post).mockRejectedValue(apiError(404, { detail: 'feature disabled' }))
    await uninstall('exam', 'closing the pilot')
    const first = (await screen.findByRole('alert')).textContent
    cleanup()
    renderRoute('tenantAdmin')
    await screen.findByTestId('uninstall-exam')
    reactivate('exam', 'again')
    const second = (await screen.findByRole('alert')).textContent
    expect(first).toBe(NOT_FOUND_MESSAGE)
    expect(second).toBe(NOT_FOUND_MESSAGE)
    expect(first).not.toMatch(/flag|disabled|uninstalled|not installed/i)
  })

  it('N2 the mapper ignores the 404 body', () => {
    for (const details of [{}, { detail: 'module is not installed' }, { code: 'x' }, undefined]) {
      expect(describeModuleTransitionError(apiError(404, details))).toEqual({ kind: 'message', text: NOT_FOUND_MESSAGE })
    }
  })
})

describe('X other answers', () => {
  const cases: Array<[string, unknown, RegExp | string]> = [
    ['X1 dependents', apiError(409, { code: 'dependents_installed', dependents: ['exam-reports'] }), 'exam-reports'],
    ['X2 upgrade', apiError(409, { code: 'upgrade_required' }), /upgrade/],
    ['X3 422', apiError(422, { detail: 'rationale is required' }), 'rationale is required'],
    ['X4 403', apiError(403, {}), FORBIDDEN_MESSAGE],
    ['X5 500', apiError(500, {}), GENERIC_MESSAGE],
  ]
  it.each(cases)('%s', async (_n, err, text) => {
    renderRoute('tenantAdmin')
    vi.mocked(client.post).mockRejectedValue(err)
    await uninstall('exam', 'closing the pilot')
    expect(await screen.findByRole('alert')).toHaveTextContent(text)
    expect(screen.queryByRole('status')).toBeNull()
    expect(screen.getByTestId('uninstall-rationale')).toHaveValue('closing the pilot')
  })

  it('X6 unknown 409 code, non-ApiError and malformed open_work fall back to generic', () => {
    const generic = { kind: 'message', text: GENERIC_MESSAGE }
    expect(describeModuleTransitionError(apiError(409, { code: 'other' }))).toEqual(generic)
    expect(describeModuleTransitionError(new Error('boom'))).toEqual(generic)
    expect(describeModuleTransitionError(null)).toEqual(generic)
    expect(describeModuleTransitionError(apiError(409, { code: 'open_work_exists', open_instances: 'x' }))).toEqual(generic)
    expect(describeModuleTransitionError(apiError(422, {}))).toEqual(generic)
  })
})

describe('R reactivate', () => {
  it('R1 posts once, shows success, refetches the list, explains the typed id', async () => {
    renderRoute('tenantAdmin')
    await screen.findByTestId('uninstall-exam')
    expect(screen.getByText(/Uninstalled modules are not listed/)).toBeInTheDocument()
    vi.mocked(client.post).mockResolvedValue({ module_id: 'exam', status: 'active' })
    const before = modulesGets()
    reactivate('exam', 'pilot resumed')
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Module exam is now active.'))
    expect(client.post).toHaveBeenCalledTimes(1)
    expect(client.post).toHaveBeenCalledWith('/api/v1/tenant/modules/exam/reactivate', { rationale: 'pilot resumed' })
    await waitFor(() => expect(modulesGets()).toBeGreaterThan(before))
  })

  it('R2 an error keeps the id and rationale', async () => {
    renderRoute('tenantAdmin')
    await screen.findByTestId('uninstall-exam')
    vi.mocked(client.post).mockRejectedValue(apiError(404, {}))
    reactivate('exam', 'pilot resumed')
    expect(await screen.findByRole('alert')).toHaveTextContent(NOT_FOUND_MESSAGE)
    expect(screen.getByTestId('reactivate-module-id')).toHaveValue('exam')
    expect(screen.getByTestId('reactivate-rationale')).toHaveValue('pilot resumed')
  })

  it('R3 the button is disabled while either field is blank', async () => {
    renderRoute('tenantAdmin')
    await screen.findByTestId('uninstall-exam')
    const btn = screen.getByTestId('reactivate-submit')
    expect(btn).toBeDisabled()
    fireEvent.change(screen.getByTestId('reactivate-module-id'), { target: { value: 'exam' } })
    expect(btn).toBeDisabled()
    fireEvent.change(screen.getByTestId('reactivate-rationale'), { target: { value: 'why' } })
    expect(btn).toBeEnabled()
    fireEvent.change(screen.getByTestId('reactivate-module-id'), { target: { value: ' ' } })
    expect(btn).toBeDisabled()
  })
})
