// @vitest-environment jsdom
/** S2 (style) — GH 3608 / REQ-670: the page states and the panel rules of the positions and employees screens
 *  (loading skeleton, empty with action, load error with retry, write error next to the field, success toast,
 *  no permission hides the actions, retired behind Show retired, Escape and the close button, the transfer dialog). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { clearAllToasts } from '@/hooks/useToast'
import EmployeesPage from '../EmployeesPage'
import PositionsPage from '../PositionsPage'
import { render } from '@testing-library/react'
import { fakeServer, problem, rec, renderOrg, withEmployeesAtom, withoutAtom } from './orgTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const U1 = rec('u-1', 'org_unit', { code: 'U1', name: 'Unit U1', legal_entity_id: 'le-1', site_id: 's-1' })
const P1 = rec('p-1', 'org_position', { code: 'P1', name: 'Pos P1', org_unit_id: 'u-1' })
const P2 = rec('p-2', 'org_position', { code: 'P2', name: 'Pos P2', org_unit_id: 'u-1', active: false })
const E1 = rec('e-1', 'org_employee', { code: 'E1', full_name: 'Emp E1', org_unit_id: 'u-1', position_id: 'p-1' })
const E2 = rec('e-2', 'org_employee', { code: 'E2', full_name: 'Emp E2', org_unit_id: 'u-1', active: false })
const DATA = { org_unit: [U1], org_position: [P1, P2], org_employee: [E1, E2] }
const EMPTY = { org_unit: [], org_position: [], org_employee: [] }
const SCREENS = [
  { path: '/admin/org/positions', create: 'Create position', first: 'Pos P1', retired: 'Pos P2' },
  { path: '/admin/org/employees', create: 'Create employee', first: 'Emp E1', retired: 'Emp E2' },
]

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  clientMock.get.mockReset()
  clientMock.get.mockResolvedValue({ items: [], next_cursor: null })
  clearAllToasts()
})
afterEach(() => cleanup())

describe.each(SCREENS)('S2 states: $path', ({ path, create, first, retired }) => {
  it('shows skeleton rows while the list loads', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => undefined))
    renderOrg(path, withEmployeesAtom)
    expect(await screen.findByTestId('org-skeleton')).toHaveAttribute('aria-busy', 'true')
  })

  it('shows the empty state with a create action that opens the panel', async () => {
    fakeServer(clientMock, EMPTY)
    renderOrg(path, withEmployeesAtom)
    const empty = await screen.findByTestId('org-empty')
    fireEvent.click(within(empty).getByRole('button', { name: create }))
    expect(screen.getByRole('form')).toBeInTheDocument()
  })

  it('shows a banner with Retry when the load fails, and loads on retry', async () => {
    let fail = true
    clientMock.post.mockImplementation(async (_p: string, body: { entity_type: string }) => {
      if (fail) throw { status: 500, message: 'x', code: '500' }
      return { items: (DATA as Record<string, unknown[]>)[body.entity_type] ?? [], next_cursor: null }
    })
    renderOrg(path, withEmployeesAtom)
    const retry = await screen.findByTestId('org-retry')
    expect(screen.getByRole('alert')).toHaveTextContent('The list could not be loaded.')
    fail = false
    fireEvent.click(retry)
    expect(await screen.findByText(first)).toBeInTheDocument()
  })

  it('hides every write action without the permission', async () => {
    fakeServer(clientMock, DATA)
    const Page = path.endsWith('positions') ? PositionsPage : EmployeesPage
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <AccessStateProvider state={withoutAtom}>
          <Page />
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    fireEvent.click(await screen.findByText(first))
    expect(screen.queryByTestId('org-create')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-retire')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-transfer-open')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-save')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Name', { exact: false })).toHaveAttribute('readonly')
  })

  it('keeps retired rows behind Show retired and marks them with a word', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(path, withEmployeesAtom)
    await screen.findByText(first)
    expect(screen.queryByText(retired)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('checkbox', { name: 'Show retired' }))
    const item = (await screen.findByText(retired)).closest('[role="treeitem"]') as HTMLElement
    expect(within(item).getByText('Retired')).toBeInTheDocument()
  })

  it('shows a write error next to the field, and a success toast after a save', async () => {
    let fail = true
    fakeServer(clientMock, DATA, () => {
      if (fail) throw problem(422, { reason: 'field_invalid', field: path.endsWith('positions') ? 'name' : 'full_name' })
      return {}
    })
    renderOrg(path, withEmployeesAtom)
    fireEvent.click(await screen.findByText(first))
    fireEvent.click(screen.getByTestId('org-save'))
    const field = await screen.findByLabelText(path.endsWith('positions') ? 'Name' : 'Full name')
    await waitFor(() => expect(field).toHaveAttribute('aria-invalid', 'true'))
    expect(field.closest('.lf-field')).toHaveTextContent('A value is not valid.')
    fail = false
    fireEvent.click(screen.getByTestId('org-save'))
    expect(await screen.findByTestId('toast-message')).toHaveTextContent('Saved')
  })

  it('keeps the panel open across rows, closes with the close button and with Escape', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(path, withEmployeesAtom)
    fireEvent.click(await screen.findByText(first))
    expect(screen.getByTestId('detail-header')).toHaveTextContent(first)
    fireEvent.click(screen.getByRole('button', { name: 'Close panel' }))
    expect(screen.queryByRole('form')).not.toBeInTheDocument()
    expect(screen.getByTestId('org-pick')).toBeInTheDocument()
    fireEvent.click(screen.getByText(first))
    fireEvent.keyDown(screen.getByTestId('org-save'), { key: 'Escape' })
    expect(screen.queryByRole('form')).not.toBeInTheDocument()
  })

  it('does not close the panel when Escape closes the retire dialog', async () => {
    fakeServer(clientMock, DATA)
    renderOrg(path, withEmployeesAtom)
    fireEvent.click(await screen.findByText(first))
    fireEvent.click(screen.getByTestId('org-retire'))
    fireEvent.keyDown(await screen.findByTestId('confirm-dialog-confirm'), { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('confirm-dialog-confirm')).not.toBeInTheDocument())
    expect(screen.getByRole('form')).toBeInTheDocument()
  })
})

describe('S2 transfer dialog', () => {
  it('shows the refusal inside the dialog, keeps it open, and toasts on success', async () => {
    let fail = true
    fakeServer(clientMock, DATA, () => {
      if (fail) throw problem(422, { reason: 'position_inactive' })
      return {}
    })
    renderOrg('/admin/org/employees', withEmployeesAtom)
    fireEvent.click(await screen.findByText('Emp E1'))
    fireEvent.click(screen.getByTestId('org-transfer-open'))
    fireEvent.click(screen.getByTestId('org-transfer-confirm'))
    expect(await screen.findByTestId('org-transfer-error')).toBeInTheDocument()
    fail = false
    fireEvent.click(screen.getByTestId('org-transfer-confirm'))
    expect(await screen.findByTestId('toast-message')).toHaveTextContent('Employee transferred')
    await waitFor(() => expect(screen.queryByTestId('org-transfer')).not.toBeInTheDocument())
  })

  it('closes on Escape without closing the panel', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/employees', withEmployeesAtom)
    fireEvent.click(await screen.findByText('Emp E1'))
    fireEvent.click(screen.getByTestId('org-transfer-open'))
    fireEvent.keyDown(screen.getByTestId('org-transfer-confirm'), { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('org-transfer')).not.toBeInTheDocument())
    expect(screen.getByRole('form')).toBeInTheDocument()
  })
})
