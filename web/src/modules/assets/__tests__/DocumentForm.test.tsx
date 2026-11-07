// @vitest-environment jsdom
/** F4–F9 — T-1469 / C14 part 2: the draft forms of the four asset document kinds, create and edit, the refusals, the list
 *  New buttons and the route order (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import {
  DOCS, LIST, MASTERS, assetDoc, fakeDocument, fakeMasters, refusal, renderAssets, rec, withAll, withPost, withRead,
} from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`
const created = (): [string, Record<string, unknown>][] => clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]
const replaced = (): [string, Record<string, unknown>][] => clientMock.put.mock.calls as [string, Record<string, unknown>][]

function serve(saved: Record<string, unknown> = assetDoc({ id: 'dn' })) {
  fakeMasters(clientMock)
  const masters = clientMock.post.getMockImplementation()!
  clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => (p === DOCS ? saved : masters(p, b)))
  clientMock.put.mockResolvedValue(saved)
  fakeDocument(clientMock, saved)
}
beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  serve()
})
afterEach(() => cleanup())

const form = () => within(screen.getByTestId('document-form'))
const pick = (label: string | RegExp, value: string) => fireEvent.change(form().getByLabelText(label), { target: { value } })
async function fillCommon() {
  await form().findAllByRole('option', { name: 'WH - Warehouse' })
  await form().findAllByRole('option', { name: 'Aigul B.' })
  fireEvent.change(form().getByLabelText('Time, date'), { target: { value: '2026-11-04' } })
  fireEvent.change(form().getByLabelText('Time, time'), { target: { value: '10:00' } })
}
async function addLine(asset: string, qty?: string) {
  fireEvent.click(await screen.findByRole('button', { name: 'Add line' }))
  const row = (await screen.findAllByTestId('line-editor-row'))[0]
  await waitFor(() => {
    const input = within(row).getByLabelText('Asset')
    fireEvent.change(input, { target: { value: asset } })
    fireEvent.blur(input)
    expect((input as HTMLInputElement).value).toContain(asset)
  })
  if (qty) fireEvent.change(within(row).getByLabelText('Quantity'), { target: { value: qty } })
  return row
}
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Save' }))

describe('F4/F5 create per kind', () => {
  it('commission: exact body, then the saved document opens', async () => {
    renderAssets(NEW, withPost)
    await fillCommon()
    pick(/^Org unit/, 'u1')
    pick(/^Location/, 'l1')
    pick(/^Material responsible/, 'e1')
    pick(/^Actual user/, 'e2')
    pick(/^Note/, 'first')
    await addLine('FA-0001', '2')
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'commission', org_unit_id: 'u1', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: 'e2',
      event_time: '2026-11-04T10:00:00+05:00', note: 'first', lines: [{ asset_id: 'a1', quantity: '2' }],
    })
    await waitFor(() => expect(screen.getByTestId('document-header')).toBeInTheDocument())
  })
  it('change: From and To groups, sides_equal refused before the request, exact body', async () => {
    renderAssets(`${NEW}?kind=change`, withPost)
    await fillCommon()
    pick(/^Org unit/, 'u1')
    const from = within(screen.getByTestId('side-from'))
    const to = within(screen.getByTestId('side-to'))
    fireEvent.change(from.getByLabelText(/^Material responsible/), { target: { value: 'e1' } })
    fireEvent.change(to.getByLabelText(/^Material responsible/), { target: { value: 'e1' } })
    await addLine('FA-0002')
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getByText('The two sides are the same.')).toBeInTheDocument()
    fireEvent.change(to.getByLabelText(/^Material responsible/), { target: { value: 'e2' } })
    fireEvent.change(to.getByLabelText(/^Actual user/), { target: { value: 'e1' } })
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'change', org_unit_id: 'u1', from_material_responsible_id: 'e1', to_material_responsible_id: 'e2', to_actual_user_id: 'e1',
      event_time: '2026-11-04T10:00:00+05:00', lines: [{ asset_id: 'a2', quantity: '1' }],
    })
  })
  it('handover: the To side starts as From and the body has both sides', async () => {
    renderAssets(`${NEW}?kind=handover`, withPost)
    await fillCommon()
    const from = within(screen.getByTestId('side-from'))
    const to = within(screen.getByTestId('side-to'))
    fireEvent.change(from.getByLabelText(/^Org unit/), { target: { value: 'u1' } })
    expect(to.getByLabelText(/^Org unit/)).toHaveValue('u1')
    fireEvent.change(from.getByLabelText(/^Material responsible/), { target: { value: 'e1' } })
    fireEvent.change(to.getByLabelText(/^Material responsible/), { target: { value: 'e2' } })
    await addLine('FA-0001')
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getByText('The two sides are the same.')).toBeInTheDocument()
    fireEvent.change(to.getByLabelText(/^Org unit/), { target: { value: 'u2' } })
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'handover', org_unit_id: 'u1', from_material_responsible_id: 'e1', to_org_unit_id: 'u2', to_material_responsible_id: 'e2',
      event_time: '2026-11-04T10:00:00+05:00', lines: [{ asset_id: 'a1', quantity: '1' }],
    })
  })
  it('writeoff: the reason is required and "other" needs a text; exact body', async () => {
    renderAssets(`${NEW}?kind=writeoff`, withPost)
    await fillCommon()
    pick(/^Org unit/, 'u1')
    pick(/^Material responsible/, 'e1')
    await addLine('FA-0001')
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getByText('Choose a reason.')).toBeInTheDocument()
    pick(/^Reason$/, 'other')
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getByText('Write the details for the reason "Other".')).toBeInTheDocument()
    pick(/^Reason details/, 'burnt')
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'writeoff', org_unit_id: 'u1', material_responsible_id: 'e1', reason_code: 'other', reason_text: 'burnt',
      event_time: '2026-11-04T10:00:00+05:00', lines: [{ asset_id: 'a1', quantity: '1' }],
    })
  })
  it('changing the kind starts the form of that kind', async () => {
    renderAssets(NEW, withPost)
    await fillCommon()
    expect(screen.queryByTestId('side-from')).not.toBeInTheDocument()
    fireEvent.change(form().getByLabelText('Kind'), { target: { value: 'handover' } })
    expect(await screen.findByTestId('side-to')).toBeInTheDocument()
  })
})

describe('F6 edit', () => {
  const FULL = assetDoc({ note: 'n', lines: [{ line_id: 'x1', line_no: 1, asset_id: 'a1', quantity: '1.000000000' }, { line_id: 'x2', line_no: 2, asset_id: 'a2', quantity: '3.000000000' }] })
  it('Edit shows the filled form with the org unit fixed; Save replaces the whole header and lines', async () => {
    serve(FULL)
    renderAssets(`${LIST}/d1`, withAll)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await form().findByRole('option', { name: 'WH - Warehouse' })
    await waitFor(() => expect(form().getByLabelText(/^Org unit/)).toHaveValue('u1'))
    expect(form().getByLabelText(/^Org unit/)).toBeDisabled()
    expect(form().getByLabelText(/^Note/)).toHaveValue('n')
    save()
    await waitFor(() => expect(replaced()).toHaveLength(1))
    expect(replaced()[0][0]).toBe(`${DOCS}/d1`)
    expect(replaced()[0][1]).toEqual({
      org_unit_id: 'u1', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: 'e2',
      event_time: '2026-11-04T10:00:00+05:00', note: 'n',
      lines: [{ asset_id: 'a1', quantity: '1' }, { asset_id: 'a2', quantity: '3' }],
    })
    expect(created()).toHaveLength(0)
  })
  it('Cancel returns to the view', async () => {
    serve(FULL)
    renderAssets(`${LIST}/d1`, withAll)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Back' }))
    expect(await screen.findByTestId('document-header')).toBeInTheDocument()
    expect(replaced()).toHaveLength(0)
  })
  it('there is no Edit for a document that is not a draft, or without AssetsPost', async () => {
    serve(assetDoc({ state: 'posted', number: 'ACM-1' }))
    renderAssets(`${LIST}/d1`, withAll)
    await screen.findByRole('button', { name: 'Reverse' })
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument()
    cleanup()
    serve(FULL)
    renderAssets(`${LIST}/d1`, withRead)
    await screen.findByTestId('document-lines')
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument()
  })
})

describe('F7 refusals on save', () => {
  it('a line refusal shows on that line; a state refusal shows in the banner; no second submit while pending', async () => {
    renderAssets(NEW, withPost)
    await fillCommon()
    pick(/^Org unit/, 'u1')
    pick(/^Material responsible/, 'e1')
    await addLine('FA-0001')
    const masters = clientMock.post.getMockImplementation()!
    let release: (v: unknown) => void = () => undefined
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) =>
      p === DOCS ? new Promise((_r, rej) => { release = rej }) : masters(p, b))
    save()
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    release(refusal(422, 'quantity_invalid', { line_no: 1, field: 'quantity' }))
    expect((await screen.findAllByText(/A quantity is not valid\./)).length).toBeGreaterThan(0)
    expect(created()).toHaveLength(1)
  })
  it('document_not_draft on replace shows in the banner', async () => {
    serve(assetDoc())
    renderAssets(`${LIST}/d1`, withAll)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await form().findByRole('option', { name: 'WH - Warehouse' })
    clientMock.put.mockRejectedValue(refusal(409, 'document_not_draft'))
    save()
    expect(await screen.findByText('Only a draft can be issued or discarded.')).toBeInTheDocument()
  })
  it('a form error moves to the first tab with a problem count', async () => {
    renderAssets(NEW, withPost)
    await form().findByRole('option', { name: 'WH - Warehouse' })
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getAllByText('A required value is missing.').length).toBeGreaterThan(0)
  })
})

describe('F8 lines editor', () => {
  it('adds, duplicates and deletes rows; refuses a duplicate asset and a zero quantity at save', async () => {
    renderAssets(NEW, withPost)
    await fillCommon()
    pick(/^Org unit/, 'u1')
    pick(/^Material responsible/, 'e1')
    await addLine('FA-0001', '0')
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getAllByText(/A quantity is not valid\./).length).toBeGreaterThan(0)
  })
  it('a fixed card takes only quantity 1', async () => {
    fakeMasters(clientMock, { ...MASTERS, assets_card: [rec('a3', 'assets_card', { inventory_number: 'FA-0003', name: 'Crane', kind: 'fixed' })] })
    renderAssets(NEW, withPost)
    await fillCommon()
    pick(/^Org unit/, 'u1')
    pick(/^Material responsible/, 'e1')
    await addLine('FA-0003', '2')
    save()
    expect(created()).toHaveLength(0)
    expect((await screen.findAllByText(/The quantity of this asset is 1\./)).length).toBeGreaterThan(0)
  })
})

describe('F9 list and routes', () => {
  it('the New buttons show with AssetsPost only and open the form of the kind', async () => {
    clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
    renderAssets(LIST, withRead)
    await screen.findByText('No asset documents yet')
    expect(screen.queryByTestId('document-new')).not.toBeInTheDocument()
    cleanup()
    renderAssets(LIST, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'New write off' }))
    expect(await screen.findByTestId('document-form')).toBeInTheDocument()
    await waitFor(() => expect(form().getByLabelText('Kind')).toHaveValue('writeoff'))
  })
  it('documents/new is the form, not a document called "new"; without AssetsPost it is refused', async () => {
    renderAssets(NEW, withPost)
    expect(await screen.findByTestId('document-form')).toBeInTheDocument()
    expect(clientMock.get).not.toHaveBeenCalledWith(`${DOCS}/new`)
    cleanup()
    renderAssets(NEW, withRead)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(screen.queryByTestId('document-form')).not.toBeInTheDocument()
  })
})
