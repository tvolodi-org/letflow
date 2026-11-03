// @vitest-environment jsdom
/** S1 (style) — GH 3609 / REQ-669: the page states and the panel rules of the three org-structure screens
 *  (loading skeleton, empty with action, load error with retry, write error next to the field, success toast,
 *  no permission hides the actions, Escape and the close button, the panel stays open across rows). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { clearAllToasts } from '@/hooks/useToast'
import LegalEntitiesPage from '../LegalEntitiesPage'
import SitesPage from '../SitesPage'
import UnitsPage from '../UnitsPage'
import { fakeServer, problem, rec, renderOrg, withAtom, withoutAtom } from './orgTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const LE1 = rec('le-1', 'org_legal_entity', { code: 'LE1', name: 'Alpha LLP', bin: '123456789012' })
const LE2 = rec('le-2', 'org_legal_entity', { code: 'LE2', name: 'Beta LLP', bin: '210987654321' })
const DATA = { org_legal_entity: [LE1, LE2], org_site: [], org_unit: [] }

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  clearAllToasts()
})
afterEach(() => cleanup())

function renderPage(page: React.ReactElement, access = withAtom) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>{page}</AccessStateProvider>
    </QueryClientProvider>,
  )
}

describe('S1 states', () => {
  it('shows skeleton rows while the list loads', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => undefined))
    renderOrg('/admin/org/legal-entities')
    expect(await screen.findByTestId('org-skeleton')).toHaveAttribute('aria-busy', 'true')
    expect(screen.getAllByTestId('skeleton').length).toBeGreaterThan(0)
  })

  it('shows the empty state with a create action that opens the panel', async () => {
    fakeServer(clientMock, { org_legal_entity: [], org_site: [], org_unit: [] })
    renderOrg('/admin/org/sites')
    const empty = await screen.findByTestId('org-empty')
    fireEvent.click(within(empty).getByRole('button', { name: 'Create site' }))
    expect(screen.getByRole('form')).toBeInTheDocument()
    expect(screen.getByTestId('detail-header')).toHaveTextContent('New site')
  })

  it('shows a banner with Retry when the load fails, and loads on retry', async () => {
    let fail = true
    clientMock.post.mockImplementation(async () => {
      if (fail) throw { status: 500, message: 'x', code: '500' }
      return { items: [LE1], next_cursor: null }
    })
    renderOrg('/admin/org/legal-entities')
    const retry = await screen.findByTestId('org-retry')
    expect(screen.getByRole('alert')).toHaveTextContent('The list could not be loaded.')
    fail = false
    fireEvent.click(retry)
    expect(await screen.findByText('Alpha LLP')).toBeInTheDocument()
    expect(screen.queryByTestId('org-retry')).not.toBeInTheDocument()
  })

  it('shows a write error next to the field and in the banner', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(422, { reason: 'field_invalid', field: 'name' })
    })
    renderOrg('/admin/org/legal-entities')
    fireEvent.click(await screen.findByText('Alpha LLP'))
    fireEvent.click(screen.getByTestId('org-save'))
    const name = await screen.findByLabelText('Name')
    await waitFor(() => expect(name).toHaveAttribute('aria-invalid', 'true'))
    expect(name.closest('.lf-field')).toHaveTextContent('A value is not valid.')
    expect(screen.getByRole('alert')).toHaveTextContent('A value is not valid.')
  })

  it('shows a success toast after a save', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/legal-entities')
    fireEvent.click(await screen.findByText('Alpha LLP'))
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Alpha 2' } })
    expect(screen.getByTestId('form-actions-hint')).toHaveTextContent('Unsaved changes')
    fireEvent.click(screen.getByTestId('org-save'))
    expect(await screen.findByTestId('toast-message')).toHaveTextContent('Saved')
  })

  it('hides every write action without the permission', async () => {
    fakeServer(clientMock, { ...DATA, org_site: [rec('s-1', 'org_site', { code: 'S1', name: 'Main site', legal_entity_id: 'le-1' })] })
    renderPage(<SitesPage />, withoutAtom)
    fireEvent.click(await screen.findByText('Main site'))
    expect(screen.queryByTestId('org-create')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-retire')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-save')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Name')).toHaveAttribute('readonly')
  })

  it('hides the unit actions and the empty-state action without the permission', async () => {
    fakeServer(clientMock, { org_legal_entity: [], org_site: [], org_unit: [] })
    renderPage(<UnitsPage />, withoutAtom)
    const empty = await screen.findByTestId('org-empty')
    expect(within(empty).queryByRole('button')).not.toBeInTheDocument()
    expect(screen.queryByTestId('org-create')).not.toBeInTheDocument()
  })

  it('keeps retired companies behind Show retired and marks them with a word', async () => {
    const old = { ...LE2, field_values: { ...LE2.field_values, active: false } }
    fakeServer(clientMock, { org_legal_entity: [LE1, old], org_site: [], org_unit: [] })
    renderPage(<LegalEntitiesPage />)
    await screen.findByText('Alpha LLP')
    expect(screen.queryByText('Beta LLP')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('checkbox', { name: 'Show retired' }))
    const item = (await screen.findByText('Beta LLP')).closest('[role="treeitem"]') as HTMLElement
    expect(within(item).getByText('Retired')).toBeInTheDocument()
  })
})

describe('S1 panel', () => {
  it('stays open across rows, closes with the close button and with Escape', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/legal-entities')
    const tree = await screen.findByRole('tree')
    fireEvent.click(within(tree).getByText('Alpha LLP'))
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Alpha LLP')
    fireEvent.click(within(tree).getByText('Beta LLP'))
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Beta LLP')
    expect((screen.getByLabelText('BIN') as HTMLInputElement).value).toBe('210987654321')

    fireEvent.click(screen.getByRole('button', { name: 'Close panel' }))
    expect(screen.queryByRole('form')).not.toBeInTheDocument()
    expect(screen.getByTestId('org-pick')).toBeInTheDocument()

    fireEvent.click(within(tree).getByText('Alpha LLP'))
    fireEvent.keyDown(screen.getByLabelText('Name'), { key: 'Escape' })
    expect(screen.queryByRole('form')).not.toBeInTheDocument()
  })

  it('does not close the panel when Escape closes the retire dialog', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/legal-entities')
    fireEvent.click(await screen.findByText('Alpha LLP'))
    fireEvent.click(screen.getByTestId('org-retire'))
    const confirm = await screen.findByTestId('confirm-dialog-confirm')
    fireEvent.keyDown(confirm, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('confirm-dialog-confirm')).not.toBeInTheDocument())
    expect(screen.getByRole('form')).toBeInTheDocument()
  })

  it('moves tree focus with the arrow keys', async () => {
    fakeServer(clientMock, DATA)
    renderOrg('/admin/org/legal-entities')
    const first = (await screen.findByText('Alpha LLP')).closest('.lf-tree__row') as HTMLElement
    first.focus()
    fireEvent.keyDown(first, { key: 'ArrowDown' })
    const second = screen.getByText('Beta LLP').closest('.lf-tree__row') as HTMLElement
    await waitFor(() => expect(second).toHaveFocus())
    fireEvent.keyDown(second, { key: 'Enter' })
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Beta LLP')
  })
})
