// @vitest-environment jsdom
/** L1, V1, A1, E1 — T-1334 / C14: the asset document list, view, actions and refusals (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { DOC_KINDS, DOC_REASONS } from '../documents/documentsModel'
import { assetsMessages } from '../assetsMessages'
import {
  DOCS, LIST, assetDoc, fakeDocument, fakeMasters, postsTo, refusal, renderAssets, routeCalls, withAll, withPost, withRead, withReverse,
} from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const locale = vi.hoisted(() => ({ current: 'en' }))
vi.mock('@/i18n/uiLocaleStore', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  useUiLocale: () => locale.current,
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const VIEW = `${LIST}/d1`
const BUTTONS = ['Issue', 'Discard', 'Reverse', 'Edit', 'Retry posting', 'Cancel document']
const present = () => BUTTONS.filter((b) => screen.queryByRole('button', { name: b }) !== null)

beforeEach(() => {
  locale.current = 'en'
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  fakeDocument(clientMock, assetDoc())
})
afterEach(() => cleanup())

describe('L1 list', () => {
  it('reads the list with no filter key, shows number or draft mark, kind, time, unit and state, and has no New button', async () => {
    clientMock.get.mockResolvedValue({
      rows: [
        { id: 'd1', kind: 'commission', state: 'draft', number: null, org_unit_id: 'u1', event_time: '2026-11-04T05:00:00Z' },
        { id: 'd2', kind: 'writeoff', state: 'posted', number: 'AWO-2026-000001', org_unit_id: 'u2', event_time: '2026-11-03T05:00:00Z' },
      ],
      next_cursor: null,
    })
    renderAssets(LIST)
    const rows = await screen.findAllByTestId('document-row')
    expect(routeCalls(clientMock, 'documents')[0]).toEqual({})
    expect(rows[0]).toHaveTextContent('Draft')
    expect(rows[0]).toHaveTextContent('Commission')
    expect(rows[0]).toHaveTextContent('Nov 4, 2026 10:00')
    await waitFor(() => expect(rows[0]).toHaveTextContent('WH - Warehouse'))
    expect(rows[1]).toHaveTextContent('AWO-2026-000001')
    expect(rows[1]).toHaveTextContent('Posted')
    expect(rows[1]).toHaveTextContent('Write off')
    expect(present()).toEqual([])
  })
  it('L1b T-1875 an admin with AssetsPost sees one New button per kind next to the list rows; handover opens the new form', async () => {
    clientMock.get.mockResolvedValue({
      rows: [
        { id: 'd1', kind: 'commission', state: 'draft', number: null, org_unit_id: 'u1', event_time: '2026-11-04T05:00:00Z' },
        { id: 'd2', kind: 'writeoff', state: 'posted', number: 'AWO-2026-000001', org_unit_id: 'u2', event_time: '2026-11-03T05:00:00Z' },
      ],
      next_cursor: null,
    })
    renderAssets(LIST, withPost)
    expect(await screen.findAllByTestId('document-row')).toHaveLength(2)
    // NM-A1: the creation entry is the header's New menu, not a control of the list pane
    const trigger = within(screen.getByTestId('page-header-actions')).getByTestId('document-new')
    expect(within(screen.getByTestId('document-list')).queryByRole('button', { name: /^New/ })).toBeNull()
    expect(within(screen.getByTestId('document-list')).queryByTestId('document-new')).toBeNull()
    fireEvent.click(trigger)
    const items = within(screen.getByRole('menu', { name: 'New document' })).getAllByRole('menuitem')
    expect(items.map((b) => b.textContent)).toEqual(DOC_KINDS.map((k) => assetsMessages.en[`assets.doc.kind.${k}`]))
    // NM-A2: choosing a kind opens its form
    fireEvent.click(items[DOC_KINDS.indexOf('handover')]!)
    await screen.findByTestId('document-form')
  })
  it('NM-A2 the Opening item opens the opening form', async () => {
    renderAssets(LIST, withPost)
    fireEvent.click(await screen.findByTestId('document-new'))
    fireEvent.click(screen.getByRole('menuitem', { name: 'Opening' }))
    expect(await screen.findByTestId('opening-time-info')).toBeInTheDocument()
  })
  it('NM-A3 the menu is in Russian and Kazakh', async () => {
    for (const l of ['ru', 'kk'] as const) {
      locale.current = l
      renderAssets(LIST, withPost)
      const trigger = await screen.findByTestId('document-new')
      expect(trigger).toHaveTextContent(assetsMessages[l]['assets.doc.action.new'])
      fireEvent.click(trigger)
      const items = within(screen.getByRole('menu')).getAllByRole('menuitem')
      expect(items.map((b) => b.textContent)).toEqual(DOC_KINDS.map((k) => assetsMessages[l][`assets.doc.kind.${k}`]))
      cleanup()
    }
  })
  it('sends only kind, state and org_unit_id, and the cursor of Load more', async () => {
    clientMock.get.mockResolvedValueOnce({ rows: [{ id: 'd1', kind: 'change', state: 'draft', number: null, org_unit_id: 'u1', event_time: null }], next_cursor: 'c1' })
    clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
    renderAssets(LIST)
    fireEvent.click(await screen.findByTestId('load-more'))
    await waitFor(() => expect(routeCalls(clientMock, 'documents')).toHaveLength(2))
    expect(routeCalls(clientMock, 'documents')[1]).toEqual({ cursor: 'c1' })
  })
  it('shows the empty text, the loading skeleton and the error with Retry', async () => {
    clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
    renderAssets(LIST)
    expect(await screen.findByText('No asset documents yet')).toBeInTheDocument()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockReturnValue(new Promise(() => {}))
    renderAssets(LIST)
    expect(await screen.findByTestId('document-list-loading')).toBeInTheDocument()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(refusal(500))
    renderAssets(LIST)
    expect(await screen.findByText('The data could not be loaded.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
  it('is not reachable without AssetsRead and sends no request', async () => {
    renderAssets(LIST, { status: 'ready', info: { roles: [], platform_tenant: false, permissions: [] } })
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(clientMock.get).not.toHaveBeenCalled()
  })
})

describe('V1 view', () => {
  it('shows the commission header with names, the lines in line order with asset names, and no tenant id in any request', async () => {
    renderAssets(VIEW)
    await screen.findByTestId('document-lines')
    expect(clientMock.get).toHaveBeenCalledWith(`${DOCS}/d1`)
    const rows = screen.getAllByTestId('line-row')
    await waitFor(() => expect(rows[0]).toHaveTextContent('FA-0001 - Delivery van'))
    expect(rows[1]).toHaveTextContent('FA-0002 - Laptop')
    const head = screen.getByTestId('document-header')
    await waitFor(() => expect(head).toHaveTextContent('WH - Warehouse'))
    expect(head).toHaveTextContent('R1 - Room 1')
    expect(head).toHaveTextContent('Aigul B.')
    expect(head).toHaveTextContent('Marat K.')
    expect(JSON.stringify(clientMock.get.mock.calls)).not.toContain('tid-assets')
  })
  it('change and handover show a From and a To group; commission and writeoff none; writeoff shows its reason', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'change', from_material_responsible_id: 'e1', from_actual_user_id: null, to_material_responsible_id: 'e2', to_actual_user_id: null }))
    renderAssets(VIEW)
    await screen.findByTestId('view-side-from')
    expect(screen.getByTestId('view-side-to')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('view-side-to')).toHaveTextContent('Marat K.'))
    cleanup()
    fakeDocument(clientMock, assetDoc({ kind: 'handover', to_org_unit_id: 'u2', from_location_id: 'l1', to_location_id: null, from_material_responsible_id: 'e1', to_material_responsible_id: 'e2' }))
    renderAssets(VIEW)
    await waitFor(() => expect(screen.getByTestId('view-side-to')).toHaveTextContent('IT - IT dept'))
    cleanup()
    fakeDocument(clientMock, assetDoc({ kind: 'writeoff', reason_code: 'lost', reason_text: 'Left on a train' }))
    renderAssets(VIEW)
    await screen.findByTestId('document-header')
    expect(screen.queryByTestId('view-side-from')).not.toBeInTheDocument()
    expect(screen.getByTestId('document-header')).toHaveTextContent('Lost')
    expect(screen.getByTestId('document-header')).toHaveTextContent('Left on a train')
  })
  it('posted shows the posting group and a Movements link; mismatch warns; issued waits with a link to the inbox', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'posted', number: 'ACM-1', posted_at: '2026-11-04T06:00:00Z', posted_by: 'u-poster' }))
    renderAssets(VIEW)
    await screen.findByTestId('document-lines')
    expect(screen.getByTestId('document-header')).toHaveTextContent('Nov 4, 2026 11:00')
    expect(screen.getByRole('link', { name: 'Movements' })).toHaveAttribute('href', '/admin/assets/movements?document_id=d1')
    expect(screen.queryByText('Posting needs a check.')).not.toBeInTheDocument()
    cleanup()
    fakeDocument(clientMock, assetDoc({ state: 'posted', posting_check: 'mismatch' }))
    renderAssets(VIEW)
    expect(await screen.findByText('Posting needs a check.')).toBeInTheDocument()
    cleanup()
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-2' }))
    renderAssets(VIEW)
    expect(await screen.findByText('The document is issued and waits for its post task in the inbox.')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open the inbox' })).toHaveAttribute('href', '/tasks')
  })
  it('a 404 shows the info state, not a crash', async () => {
    clientMock.get.mockRejectedValue(refusal(404))
    renderAssets(VIEW)
    expect(await screen.findByText(/Nothing to show here/)).toBeInTheDocument()
  })
})

describe('A1 actions', () => {
  it('draft: Issue posts with no body after a confirm; Discard deletes after a confirm', async () => {
    renderAssets(VIEW, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Issue' }))
    expect(postsTo(clientMock, 'd1/issue')).toHaveLength(0)
    fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(postsTo(clientMock, 'd1/issue')).toEqual([[`${DOCS}/d1/issue`]]))
    await waitFor(() => expect(clientMock.get.mock.calls.filter(([p]) => p === `${DOCS}/d1`).length).toBeGreaterThan(1))
    fireEvent.click(screen.getByRole('button', { name: 'Discard' }))
    expect(clientMock.delete).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(clientMock.delete).toHaveBeenCalledWith(`${DOCS}/d1`))
  })
  it('posted: Reverse needs a reason; sends {reason_code} or {reason_code:other, reason_text}; blocks other without text and 501 characters', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'posted', number: 'ACM-1' }))
    renderAssets(VIEW, withReverse)
    fireEvent.click(await screen.findByRole('button', { name: 'Reverse' }))
    const dlg = await screen.findByTestId('reason-dialog')
    fireEvent.click(within(dlg).getByRole('button', { name: 'Reverse' }))
    expect(postsTo(clientMock, 'd1/reverse')).toHaveLength(0)
    const select = within(dlg).getByRole('combobox')
    fireEvent.change(select, { target: { value: 'other' } })
    fireEvent.click(within(dlg).getByRole('button', { name: 'Reverse' }))
    expect(await within(dlg).findByText('Write the details for the reason "Other".')).toBeInTheDocument()
    expect(postsTo(clientMock, 'd1/reverse')).toHaveLength(0)
    fireEvent.change(within(dlg).getByRole('textbox'), { target: { value: 'x'.repeat(501) } })
    fireEvent.click(within(dlg).getByRole('button', { name: 'Reverse' }))
    expect(postsTo(clientMock, 'd1/reverse')).toHaveLength(0)
    fireEvent.change(within(dlg).getByRole('textbox'), { target: { value: 'Duplicate entry' } })
    fireEvent.click(within(dlg).getByRole('button', { name: 'Reverse' }))
    await waitFor(() => expect(postsTo(clientMock, 'd1/reverse')).toEqual([[`${DOCS}/d1/reverse`, { reason_code: 'other', reason_text: 'Duplicate entry' }]]))
  })
  it('posted: a reason without text sends the code alone', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'posted', number: 'ACM-1' }))
    renderAssets(VIEW, withReverse)
    fireEvent.click(await screen.findByRole('button', { name: 'Reverse' }))
    const dlg = await screen.findByTestId('reason-dialog')
    fireEvent.change(within(dlg).getByRole('combobox'), { target: { value: 'wrong_quantity' } })
    fireEvent.click(within(dlg).getByRole('button', { name: 'Reverse' }))
    await waitFor(() => expect(postsTo(clientMock, 'd1/reverse')).toEqual([[`${DOCS}/d1/reverse`, { reason_code: 'wrong_quantity' }]]))
  })
  it('buttons follow the atom and the state; Edit is for a draft with AssetsPost; there is never a Retry or Cancel', async () => {
    renderAssets(VIEW, withRead)
    await screen.findByTestId('document-lines')
    expect(present()).toEqual([])
    cleanup()
    renderAssets(VIEW, withReverse)
    await screen.findByTestId('document-lines')
    expect(present()).toEqual([])
    cleanup()
    renderAssets(VIEW, withAll)
    await screen.findByRole('button', { name: 'Issue' })
    expect(present()).toEqual(['Issue', 'Discard', 'Edit'])
    for (const state of ['issued', 'reversed', 'cancelled']) {
      cleanup()
      fakeDocument(clientMock, assetDoc({ state, number: 'ACM-1' }))
      renderAssets(VIEW, withAll)
      await screen.findByTestId('document-lines')
      expect(present(), state).toEqual([])
    }
    cleanup()
    fakeDocument(clientMock, assetDoc({ state: 'posted', number: 'ACM-1' }))
    renderAssets(VIEW, withAll)
    await screen.findByRole('button', { name: 'Reverse' })
    expect(present()).toEqual(['Reverse'])
  })
})

describe('E1 refusals', () => {
  it('every reason of the closed list shows its own text in the issue dialog', async () => {
    renderAssets(VIEW, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Issue' }))
    for (const reason of DOC_REASONS) {
      clientMock.post.mockRejectedValueOnce(refusal(409, reason))
      fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
      expect(await screen.findByText(assetsMessages.en[`assets.doc.error.${reason}`], {}, { timeout: 3000 }), reason).toBeInTheDocument()
    }
  }, 60000)
  it('a line number prefixes the text; a surprise reason and a 500 get their generic texts; 403 and 404 their own', async () => {
    renderAssets(VIEW, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Issue' }))
    const confirm = () => fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
    clientMock.post.mockRejectedValueOnce(refusal(422, 'quantity_invalid', { line_no: 3 }))
    confirm()
    expect(await screen.findByText('Line 3: A quantity is not valid.')).toBeInTheDocument()
    clientMock.post.mockRejectedValueOnce(refusal(409, 'something_new'))
    confirm()
    expect(await screen.findByText('The action was refused.')).toBeInTheDocument()
    clientMock.post.mockRejectedValueOnce(refusal(500))
    confirm()
    expect(await screen.findByText('The action failed. Try again.')).toBeInTheDocument()
    clientMock.post.mockRejectedValueOnce(refusal(403))
    confirm()
    expect(await screen.findByText('You may not do this.')).toBeInTheDocument()
    clientMock.post.mockRejectedValueOnce(refusal(404))
    confirm()
    expect(await screen.findByText('The document was not found. It may have been removed.')).toBeInTheDocument()
  })
})
