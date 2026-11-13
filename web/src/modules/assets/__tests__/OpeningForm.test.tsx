// @vitest-environment jsdom
/** O-L1, O-L2, O-F1, O-F3, O-C1, O-CH1..3, O-I1, O-V1, O-V2, O-IMP1..3, O-PERM — T-1877: the asset opening document on
 *  the Asset documents screen: New button, create form, check, issue, views, import from Excel (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import type { AccessState } from '@/auth/access/types'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DOCS, LIST, MASTERS, assetDoc, fakeDocument, fakeMasters, postsTo, refusal, rec, renderAssets, withPost } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const saveBlobMock = vi.hoisted(() => vi.fn())
vi.mock('@/lib/saveBlob', () => ({ saveBlob: saveBlobMock }))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), postRaw: vi.fn(), postBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const access = (...permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })
const withImport = access('AssetsRead', 'AssetsPost', 'AssetsReverse', 'EntitiesRecordsImport', 'EntitiesRecordsExport')
const NEW = `${LIST}/new?kind=opening`
const DATA = {
  ...MASTERS,
  assets_card: [
    rec('a1', 'assets_card', { inventory_number: 'FA-0001', name: 'Delivery van', kind: 'fixed', acquisition_cost: '1500000.00', accumulated_depreciation: '300000.00', acquisition_date: '2019-03-01' }),
    rec('a2', 'assets_card', { inventory_number: 'IA-0002', name: 'Licence', kind: 'intangible' }),
  ],
}
const created = (): [string, Record<string, unknown>][] => clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]
const replaced = (): [string, Record<string, unknown>][] => clientMock.put.mock.calls as [string, Record<string, unknown>][]

const OPENING = (over: Record<string, unknown> = {}) =>
  assetDoc({
    id: 'd1', kind: 'opening', event_time: null, location_id: undefined, material_responsible_id: undefined, actual_user_id: undefined,
    external_ref_system: 'erp', external_ref_id: 'OP-1', note: 'start',
    lines: [
      { line_id: 'x1', line_no: 1, asset_id: 'a1', quantity: '1.000000000', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: null, external_ref_system: 'erp', external_ref_id: 'r1' },
      { line_id: 'x2', line_no: 2, asset_id: 'a2', quantity: '1.000000000', location_id: null, material_responsible_id: 'e2', actual_user_id: 'e1', external_ref_system: 'erp', external_ref_id: 'r2' },
    ],
    ...over,
  })

function serve(saved: Record<string, unknown> = OPENING()) {
  fakeMasters(clientMock, DATA)
  const masters = clientMock.post.getMockImplementation()!
  clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => (p === DOCS ? saved : masters(p, b)))
  clientMock.put.mockResolvedValue(saved)
  fakeDocument(clientMock, saved)
}
beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  saveBlobMock.mockReset()
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
  serve()
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

const form = () => within(screen.getByTestId('document-form'))
const formReady = async () => within(await screen.findByTestId('document-form'))
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Save' }))
const importBtn = () => screen.getByRole('button', { name: 'Import lines from Excel' })
async function openEdit(doc: Record<string, unknown>, state: AccessState = withImport) {
  serve(doc)
  renderAssets(`${LIST}/d1`, state)
  fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
  await screen.findByTestId('document-form')
  await waitFor(() => expect(screen.getAllByTestId('line-editor-row').length).toBeGreaterThan(0))
}

describe('O-L1/O-L2 the sixth kind', () => {
  it('the list has six New buttons, the last is New opening and leads to ?kind=opening', async () => {
    renderAssets(LIST, withPost)
    const btn = await screen.findByRole('button', { name: 'New opening' })
    expect(screen.getAllByRole('button', { name: /^New (commission|change of holder|hand over|write off|change of kind|opening)$/ })).toHaveLength(6)
    fireEvent.click(btn)
    expect(await screen.findByTestId('opening-time-info')).toBeInTheDocument()
  })
  it('the direct address shows org unit, note, external pair, the time info line, no time field, and the opening columns', async () => {
    renderAssets(NEW, withPost)
    await (await formReady()).findAllByRole('option', { name: 'WH - Warehouse' })
    expect(form().getByLabelText(/^Org unit/)).toBeInTheDocument()
    expect(form().getByLabelText(/^Note/)).toBeInTheDocument()
    expect(form().getByLabelText(/^External system/)).toBeInTheDocument()
    expect(form().getByLabelText(/^External id/)).toBeInTheDocument()
    expect(form().queryByLabelText('Time, date')).not.toBeInTheDocument()
    expect(form().queryByLabelText(/^Location/)).not.toBeInTheDocument()
    expect(screen.getByTestId('opening-time-info')).toHaveTextContent('no backdating')
    expect(screen.getByTestId('opening-card-hint')).toBeInTheDocument()
  })
})

describe('O-F1 create and O-C1 card info', () => {
  it('Save posts the exact body (no event time), and the card cost, depreciation and date are read-only text', async () => {
    renderAssets(NEW, withPost)
    await (await formReady()).findAllByRole('option', { name: 'WH - Warehouse' })
    fireEvent.change(form().getByLabelText(/^Org unit/), { target: { value: 'u1' } })
    fireEvent.click(await screen.findByRole('button', { name: 'Add line' }))
    const row = (await screen.findAllByTestId('line-editor-row'))[0]!
    await within(row).findAllByRole('option', { name: 'R1 - Room 1' })
    await waitFor(() => {
      const input = within(row).getByLabelText('Asset card')
      fireEvent.change(input, { target: { value: 'FA-0001' } })
      fireEvent.blur(input)
      expect((input as HTMLInputElement).value).toContain('FA-0001')
    })
    fireEvent.change(within(row).getByLabelText('Location'), { target: { value: 'l1' } })
    fireEvent.change(within(row).getByLabelText('Material responsible'), { target: { value: 'e1' } })
    // O-C1: the card's values appear as text, not as an input
    expect(row).toHaveTextContent('1,500,000')
    expect(row).toHaveTextContent('300,000')
    expect(row).toHaveTextContent('2019')
    expect(within(row).queryByDisplayValue('1500000.00')).not.toBeInTheDocument()
    expect(screen.getByTestId('opening-card-hint')).toHaveTextContent('come from the card')
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0]![1]).toEqual({
      kind: 'opening', org_unit_id: 'u1', lines: [{ asset_id: 'a1', material_responsible_id: 'e1', quantity: '1', location_id: 'l1' }],
    })
  })
  it('an empty form is refused before the request', async () => {
    renderAssets(NEW, withPost)
    await formReady()
    save()
    expect(created()).toHaveLength(0)
  })
})

describe('O-F3 edit keeps the external pairs', () => {
  it('Save replaces the whole document: header pair and every line pair go back, no kind and no event time', async () => {
    await openEdit(OPENING())
    await waitFor(() => expect(form().getByLabelText(/^Org unit/)).toHaveValue('u1'))
    save()
    await waitFor(() => expect(replaced()).toHaveLength(1))
    expect(replaced()[0]![0]).toBe(`${DOCS}/d1`)
    expect(replaced()[0]![1]).toEqual({
      org_unit_id: 'u1', note: 'start', external_ref_system: 'erp', external_ref_id: 'OP-1',
      lines: [
        { asset_id: 'a1', material_responsible_id: 'e1', quantity: '1', location_id: 'l1', external_ref_system: 'erp', external_ref_id: 'r1' },
        { asset_id: 'a2', material_responsible_id: 'e2', quantity: '1', actual_user_id: 'e1', external_ref_system: 'erp', external_ref_id: 'r2' },
      ],
    })
  })
})

describe('O-CH check, O-I1 issue, O-V views', () => {
  it('O-CH1 Check all lines lists every reason with the opening texts; O-CH2 an all-clear answer says so', async () => {
    serve(OPENING())
    clientMock.post.mockImplementation(async (p: string) => {
      if (p === `${DOCS}/d1/check`) {
        return {
          ok: false, header: ['org_unit_not_active'],
          lines: [
            { line_no: 1, reasons: ['asset_already_in_register', 'not_linked'], fields: [] },
            { line_no: 2, reasons: ['employee_not_active'], fields: ['material_responsible_id', 'actual_user_id'] },
          ],
        }
      }
      return { items: [], next_cursor: null }
    })
    renderAssets(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Check all lines' }))
    const result = await screen.findByTestId('check-result')
    const items = within(result).getAllByRole('listitem')
    expect(items).toHaveLength(5)
    expect(items[0]).toHaveTextContent('Document: The org unit is not active.')
    expect(items[1]).toHaveTextContent('Line 1: The asset is already in the register')
    expect(items[2]).toHaveTextContent('Line 1: The location is not active or not linked')
    expect(items[3]).toHaveTextContent('Line 2: The material responsible is not an active employee.')
    expect(items[4]).toHaveTextContent('Line 2: The actual user is not an active employee.')
    expect(postsTo(clientMock, 'd1/check')).toHaveLength(1)
    clientMock.post.mockImplementation(async () => ({ ok: true, header: [], lines: [{ line_no: 1, reasons: [], fields: [] }] }))
    fireEvent.click(screen.getByRole('button', { name: 'Check all lines' }))
    await waitFor(() => expect(screen.getByTestId('check-result')).toHaveTextContent('All lines pass the checks.'))
  })
  it('O-CH3 no Check button on a commission draft, on an issued opening, or without AssetsPost', async () => {
    serve(assetDoc())
    renderAssets(`${LIST}/d1`, withPost)
    await screen.findByRole('button', { name: 'Issue' })
    expect(screen.queryByRole('button', { name: 'Check all lines' })).not.toBeInTheDocument()
    cleanup()
    serve(OPENING({ state: 'issued', number: 'AOP-1' }))
    renderAssets(`${LIST}/d1`, withPost)
    await screen.findByTestId('document-header')
    expect(screen.queryByRole('button', { name: 'Check all lines' })).not.toBeInTheDocument()
    cleanup()
    serve(OPENING())
    renderAssets(`${LIST}/d1`, access('AssetsRead'))
    await screen.findByTestId('document-header')
    expect(screen.queryByRole('button', { name: 'Check all lines' })).not.toBeInTheDocument()
  })
  it('O-I1 Issue explains the second approver; a 422 on a line shows the opening text; 409 register_unreadable its own', async () => {
    serve(OPENING())
    renderAssets(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Issue' }))
    const dialog = await screen.findByRole('dialog')
    expect(dialog).toHaveTextContent('A second person with posting rights approves it in Tasks')
    const masters = clientMock.post.getMockImplementation()!
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === `${DOCS}/d1/issue`) throw refusal(422, 'asset_already_in_register', { line_no: 3 })
      return masters(p, b)
    })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Issue' }))
    await waitFor(() => expect(dialog).toHaveTextContent(/Line 3:.*already in the register/))
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === `${DOCS}/d1/issue`) throw refusal(409, 'register_unreadable')
      return masters(p, b)
    })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Issue' }))
    await waitFor(() => expect(dialog).toHaveTextContent('You need a read of the whole asset register'))
  })
  it('O-V1 an issued opening shows the approval banner and no Check or Issue', async () => {
    serve(OPENING({ state: 'issued', number: 'AOP-1' }))
    renderAssets(`${LIST}/d1`, withPost)
    expect(await screen.findByText('Waiting for a second person to approve the opening in Tasks.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Issue' })).not.toBeInTheDocument()
  })
  it('O-V2 a posted opening: header rows without an event time, the lines with names, Reverse by AssetsReverse', async () => {
    serve(OPENING({ state: 'posted', number: 'AOP-1', posted_at: '2026-11-05T05:00:00Z' }))
    renderAssets(`${LIST}/d1`, withImport)
    const header = await screen.findByTestId('document-header')
    expect(header).toHaveTextContent('AOP-1')
    expect(header).toHaveTextContent('Warehouse')
    expect(header).toHaveTextContent('erp')
    expect(header).toHaveTextContent('OP-1')
    expect(header).not.toHaveTextContent('Time')
    const lines = await screen.findByTestId('document-lines')
    await waitFor(() => expect(lines).toHaveTextContent('Room 1'))
    expect(lines).toHaveTextContent('Delivery van')
    expect(lines).toHaveTextContent('Aigul B.')
    expect(lines).toHaveTextContent('Marat K.')
    expect(screen.getByRole('button', { name: 'Reverse' })).toBeInTheDocument()
  })
})

describe('O-IMP import from Excel', () => {
  it('O-IMP1 a saved clean draft imports through the records route, reloads the lines and lists the refused row with its column', async () => {
    await openEdit(OPENING())
    await waitFor(() => expect(importBtn()).toBeEnabled())
    const fresh = OPENING({
      lines: [
        ...(OPENING()['lines'] as Record<string, unknown>[]),
        { line_id: 'x3', line_no: 3, asset_id: 'a1', quantity: '1.000000000', location_id: 'l1', material_responsible_id: 'e1', external_ref_system: 'erp', external_ref_id: 'r3' },
      ],
    })
    clientMock.get.mockImplementation(async (p: string) => (p === `${DOCS}/d1` ? fresh : { rows: [], next_cursor: null }))
    clientMock.postRaw.mockResolvedValue({
      results: [
        { status: 'ok', line: 1, outcome: 'created' },
        { status: 'error', line: 3, reason: { type: 'quantity_invalid', header: 'quantity' } },
      ],
    })
    fireEvent.click(importBtn())
    fireEvent.change(screen.getByTestId('lines-import-file'), { target: { files: [new File([new Uint8Array(10)], 'lines.xlsx')] } })
    const notice = await screen.findByTestId('lines-notice')
    expect(notice).toHaveTextContent('1 lines added, 1 refused')
    expect(notice).toHaveTextContent('quantity')
    expect(clientMock.postRaw).toHaveBeenCalledTimes(1)
    expect(clientMock.postRaw.mock.calls[0]![0]).toBe('/api/v1/entities/records/assets_opening_line/import?upsert_by=external_ref&atomic=true')
    await waitFor(() => expect(screen.getAllByTestId('line-editor-row')).toHaveLength(3))
  })
  it('O-IMP2 disabled with its reason: new form, no pair, unsaved change, no import permission', async () => {
    renderAssets(NEW, withImport)
    await screen.findByTestId('document-form')
    const first = await screen.findByTestId('lines-empty-import')
    expect(first).toBeDisabled()
    expect(first).toHaveAttribute('title', expect.stringContaining('Save the draft first'))
    cleanup()
    await openEdit(OPENING({ external_ref_system: null, external_ref_id: null }))
    await waitFor(() => expect(importBtn()).toBeDisabled())
    expect(importBtn()).toHaveAttribute('title', expect.stringContaining('Fill in the external system and id'))
    cleanup()
    await openEdit(OPENING())
    await waitFor(() => expect(importBtn()).toBeEnabled())
    fireEvent.change(screen.getAllByLabelText('Quantity')[0]!, { target: { value: '1' } })
    fireEvent.change(screen.getAllByLabelText('Material responsible')[0]!, { target: { value: 'e2' } })
    await waitFor(() => expect(importBtn()).toBeDisabled())
    expect(importBtn()).toHaveAttribute('title', expect.stringContaining('Save your changes first'))
    cleanup()
    await openEdit(OPENING(), withPost)
    await waitFor(() => expect(importBtn()).toBeDisabled())
    expect(importBtn()).toHaveAttribute('title', expect.stringContaining('no right to import'))
    expect(clientMock.postRaw).not.toHaveBeenCalled()
  })
  it('O-IMP3 the template button needs the export permission and downloads the template; the column hint is shown', async () => {
    clientMock.postBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    await openEdit(OPENING(), withImport)
    expect(screen.getByTestId('opening-import-help')).toHaveTextContent('header_id')
    fireEvent.click(screen.getByTestId('opening-template'))
    await waitFor(() => expect(saveBlobMock).toHaveBeenCalledTimes(1))
    expect(clientMock.postBlob.mock.calls[0]![0]).toContain('/records/assets_opening_line/export')
    expect(saveBlobMock.mock.calls[0]![1]).toBe('assets_opening_line-template.xlsx')
    cleanup()
    await openEdit(OPENING(), access('AssetsRead', 'AssetsPost', 'EntitiesRecordsImport'))
    expect(screen.queryByTestId('opening-template')).not.toBeInTheDocument()
  })
})

describe('O-PERM permission-based', () => {
  it('without AssetsPost the form at ?kind=opening shows no form', async () => {
    renderAssets(NEW, access('AssetsRead'))
    await waitFor(() => expect(screen.queryByTestId('document-form')).not.toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Save' })).not.toBeInTheDocument()
  })
})
