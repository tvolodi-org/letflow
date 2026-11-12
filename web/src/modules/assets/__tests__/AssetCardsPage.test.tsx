// @vitest-environment jsdom
/** P1–P9 — T-1333 / C13: the asset card screen: list, filters, detail panel, create, edit, retire, write errors,
 *  keyboard, languages. A fake server answers /entities/query; the writes are recorded. */
import { accessibleFormProblems } from '@/test-utils/a11yForm'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { fakeServer, problem, queryBodies, rec, renderAssets, withoutAtom, writeCalls } from './assetsTestKit'
import { assetsMessages } from '../assetsMessages'

expect.extend(jestDomMatchers)

const locale = vi.hoisted(() => ({ current: 'en' }))
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
vi.mock('@/i18n/uiLocaleStore', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  useUiLocale: () => locale.current,
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const en = assetsMessages.en
const card = (id: string, no: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'assets_card', { inventory_number: no, name: `Asset ${no}`, kind: 'fixed', org_unit_id: 'u-1', ...extra })
const DATA = {
  assets_card: [
    card('c-1', 'FA-1', { acquisition_cost: '1500.50', book_value: '900.25', acquisition_date: '2024-02-03' }),
    card('c-2', 'LV-2', { kind: 'low_value', org_unit_id: 'u-2' }),
    card('c-3', 'IA-3', { kind: 'intangible', valid_until: '2027-06-30' }),
    card('c-4', 'FA-4', { active: false, acquisition_cost: '77.00' }),
  ],
  org_unit: [
    rec('u-1', 'org_unit', { code: 'U1', name: 'Head office' }),
    rec('u-2', 'org_unit', { code: 'U2', name: 'Warehouse team' }),
    rec('u-3', 'org_unit', { code: 'U3', name: 'Old unit', active: false }),
  ],
}
const PATH = '/admin/assets/cards'
const field = (name: string) => document.querySelector(`[name="${name}"]`) as HTMLInputElement
const open = async (no: string) => {
  fireEvent.click(await screen.findByText(no))
  return screen.findByRole('form')
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  locale.current = 'en'
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('P1 list and states', () => {
  it('shows the active cards with number, name, kind, org unit name and a status pill', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    expect(await screen.findByText('FA-1')).toBeInTheDocument()
    expect(screen.getByText('Asset FA-1')).toBeInTheDocument()
    expect(screen.getAllByText('Low-value asset').length).toBeGreaterThan(1)
    expect(screen.getAllByText('Head office').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Active').length).toBeGreaterThan(0)
    expect(screen.queryByText('FA-4')).not.toBeInTheDocument()
    expect(screen.queryByText('u-1')).not.toBeInTheDocument()
  })

  it('shows the skeleton while loading', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => undefined))
    renderAssets(PATH)
    expect(await screen.findByLabelText('Loading content')).toBeInTheDocument()
    expect(screen.getByTestId('asset-create')).toBeInTheDocument()
  })

  it('shows a retry banner on a load error and loads again on retry', async () => {
    let fail = true
    fakeServer(clientMock, DATA)
    const answer = clientMock.post.getMockImplementation() as (p: string, b: unknown) => Promise<unknown>
    clientMock.post.mockImplementation(async (p: string, b: unknown) => {
      if (fail) throw problem(500, {})
      return answer(p, b)
    })
    renderAssets(PATH)
    const retry = await screen.findByRole('button', { name: 'Retry' })
    fail = false
    fireEvent.click(retry)
    expect(await screen.findByText('FA-1')).toBeInTheDocument()
  })

  it('shows the empty state with a create action', async () => {
    fakeServer(clientMock, { assets_card: [], org_unit: DATA.org_unit })
    renderAssets(PATH)
    expect(await screen.findByText(en['assets.page.emptyTitle'])).toBeInTheDocument()
    fireEvent.click(within(screen.getByTestId('empty-state')).getByRole('button', { name: en['assets.common.create'] }))
    expect(await screen.findByRole('form', { name: en['assets.page.createTitle'] })).toBeInTheDocument()
  })
})

describe('P2 filters', () => {
  it('sends kind and org unit as server filters, drops the active filter with Show retired, clears', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await screen.findByText('FA-1')
    expect(queryBodies(clientMock, 'assets_card')[0]['filters']).toContainEqual({ field: 'active', op: 'eq', value: true })
    fireEvent.change(field('filter_kind'), { target: { value: 'low_value' } })
    await waitFor(() => expect(screen.queryByText('FA-1')).not.toBeInTheDocument())
    expect(screen.getByText('LV-2')).toBeInTheDocument()
    expect(queryBodies(clientMock, 'assets_card').at(-1)?.['filters']).toContainEqual({ field: 'kind', op: 'eq', value: 'low_value' })
    fireEvent.change(field('filter_org_unit'), { target: { value: 'u-1' } })
    expect(await screen.findByText(en['assets.page.noMatchTitle'])).toBeInTheDocument()
    expect(queryBodies(clientMock, 'assets_card').at(-1)?.['filters']).toContainEqual({ field: 'org_unit_id', op: 'eq', value: 'u-1' })
    fireEvent.click(screen.getAllByRole('button', { name: en['assets.common.clear'] })[0])
    expect(await screen.findByText('FA-1')).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText(en['assets.common.showRetired']))
    expect(await screen.findByText('FA-4')).toBeInTheDocument()
    expect(queryBodies(clientMock, 'assets_card').at(-1)?.['filters']).not.toContainEqual({ field: 'active', op: 'eq', value: true })
  })
})

describe('P3 detail panel', () => {
  it('opens the card with its values as stored, valid_until only for intangible, no raw ids', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-1')
    expect(field('inventory_number').value).toBe('FA-1')
    expect(field('acquisition_cost').value).toBe('1500.50')
    expect(field('book_value').value).toBe('900.25')
    expect(screen.queryByLabelText(new RegExp(en['assets.field.validUntil']))).not.toBeInTheDocument()
    expect(screen.getByText(en['assets.section.depHint'])).toBeInTheDocument()
    expect(screen.queryByText('u-1')).not.toBeInTheDocument()
    fireEvent.click(screen.getByText('IA-3'))
    await waitFor(() => expect(screen.getAllByLabelText(new RegExp(en['assets.field.validUntil'])).length).toBeGreaterThan(0))
  })
})

describe('P4 create', () => {
  it('posts the filled keys with an idempotency key, no active, no tenant key; toast and reload', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    fireEvent.click(await screen.findByTestId('asset-create'))
    await screen.findByRole('form', { name: en['assets.page.createTitle'] })
    // K4: Save is enabled; a click on the empty form explains instead of staying silent
    expect(screen.getByTestId('asset-save')).toBeEnabled()
    fireEvent.click(screen.getByTestId('asset-save'))
    expect(screen.getAllByText(en['assets.error.required'])).toHaveLength(2)
    expect(field('inventory_number')).toHaveAttribute('aria-invalid', 'true')
    await waitFor(() => expect(field('inventory_number')).toHaveFocus())
    expect(accessibleFormProblems(screen.getByRole('form'))).toEqual([]) // K1/K2
    expect(writeCalls(clientMock)).toHaveLength(0)
    fireEvent.change(field('inventory_number'), { target: { value: 'FA-9' } })
    fireEvent.change(field('name'), { target: { value: 'New van' } })
    expect(document.querySelector('[name="org_unit_id"]')).toBeNull()
    expect(screen.getByText(en['assets.form.holderHint'])).toBeInTheDocument()
    fireEvent.change(field('acquisition_cost'), { target: { value: '12.5' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.method).toBe('POST')
    expect(call.path).toBe('/api/v1/modules/assets/cards')
    expect(call.body).toEqual({
      kind: 'fixed', inventory_number: 'FA-9', name: 'New van', acquisition_cost: '12.5',
      idempotency_key: expect.any(String),
    })
    expect(await screen.findByText(en['assets.toast.created'])).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByTestId('asset-save')).not.toBeInTheDocument())
    await waitFor(() => expect(queryBodies(clientMock, 'assets_card').length).toBeGreaterThan(1))
  })

  it('blocks Save and names the field for a malformed decimal', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    fireEvent.click(await screen.findByTestId('asset-create'))
    await screen.findByRole('form')
    fireEvent.change(field('inventory_number'), { target: { value: 'X' } })
    fireEvent.change(field('name'), { target: { value: 'Y' } })
    fireEvent.change(field('book_value'), { target: { value: '1,5' } })
    expect(screen.getByText(en['assets.error.decimalFormat'])).toBeInTheDocument()
    expect(field('book_value')).toHaveAttribute('aria-invalid', 'true')
    fireEvent.click(screen.getByTestId('asset-save'))
    expect(writeCalls(clientMock)).toHaveLength(0)
    await waitFor(() => expect(field('book_value')).toHaveFocus())
  })
})

describe('P5 edit', () => {
  it('patches only the changed keys, null for a cleared optional, kind is read-only, Save disabled while clean', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-1')
    expect(field('kind')).toBeDisabled()
    expect(screen.getByTestId('asset-save')).toBeDisabled()
    fireEvent.change(field('name'), { target: { value: 'Renamed' } })
    fireEvent.change(field('acquisition_cost'), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.method).toBe('PATCH')
    expect(call.path).toBe('/api/v1/modules/assets/cards/c-1')
    expect(call.body).toEqual({ name: 'Renamed', acquisition_cost: null, idempotency_key: expect.any(String) })
    expect(await screen.findByText(en['assets.toast.updated'])).toBeInTheDocument()
  })
})

describe('P6 retire', () => {
  it('confirms, posts only the idempotency key, toasts; the card is hidden and then read-only under Show retired', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-1')
    fireEvent.click(screen.getByRole('button', { name: en['assets.common.retire'] }))
    const dialog = await screen.findByRole('dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: en['assets.common.retire'] }))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.path).toBe('/api/v1/modules/assets/cards/c-1/retire')
    expect(call.body).toEqual({ idempotency_key: expect.any(String) })
    expect(await screen.findByText(en['assets.toast.retired'])).toBeInTheDocument()
  })

  it('a retired card opens as read-only facts with no Edit or Retire', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await screen.findByText('FA-1')
    fireEvent.click(screen.getByLabelText(en['assets.common.showRetired']))
    fireEvent.click(await screen.findByText('FA-4'))
    expect(await screen.findByText('77.00')).toBeInTheDocument()
    expect(screen.queryByTestId('asset-save')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: en['assets.common.retire'] })).not.toBeInTheDocument()
  })
})

describe('P7 write errors', () => {
  async function saveWith(err: unknown) {
    fakeServer(clientMock, DATA, () => {
      throw err
    })
    renderAssets(PATH)
    await open('FA-1')
    fireEvent.change(field('name'), { target: { value: 'Changed' } })
    fireEvent.click(screen.getByTestId('asset-save'))
  }

  it('shows the message of each reason, marks the field and keeps the form open', async () => {
    const cases: [string, string | null][] = [
      ['currency_mismatch', 'currency'],
      ['card_inactive', null],
    ]
    for (const [reason, name] of cases) {
      clientMock.post.mockReset()
      await saveWith(problem(422, { reason }))
      expect(await screen.findByRole('alert')).toHaveTextContent(en[`assets.error.${reason}`])
      expect(screen.getByTestId('asset-save')).toBeInTheDocument()
      if (name) expect(field(name)).toHaveAttribute('aria-invalid', 'true')
      cleanup()
    }
  })

  it('marks the inventory number for record_payload_invalid and names the fields', async () => {
    await saveWith(problem(422, { reason: 'record_payload_invalid', fields: ['inventory_number'] }))
    expect(await screen.findByRole('alert')).toHaveTextContent(en['assets.error.record_payload_invalid'].replace('{fields}', 'inventory_number'))
    expect(field('inventory_number')).toHaveAttribute('aria-invalid', 'true')
  })

  it('maps 409 and 403', async () => {
    await saveWith(problem(409, { reason: 'idempotency_key_reuse' }))
    expect(await screen.findByRole('alert')).toHaveTextContent(en['assets.error.idempotency_key_reuse'])
    cleanup()
    clientMock.post.mockReset()
    await saveWith(problem(403, {}))
    expect(await screen.findByRole('alert')).toHaveTextContent(en['assets.error.forbidden'])
  })

  it('a 404 closes the panel, says so and reloads the list', async () => {
    await saveWith(problem(404, {}))
    expect(await screen.findByRole('alert')).toHaveTextContent(en['assets.error.notFound'])
    await waitFor(() => expect(screen.queryByTestId('asset-save')).not.toBeInTheDocument())
    await waitFor(() => expect(queryBodies(clientMock, 'assets_card').length).toBeGreaterThan(1))
  })
})

describe('P8 panel keyboard', () => {
  it('closes with the close button and with Escape, but not while the retire dialog is open', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-1')
    fireEvent.click(screen.getByRole('button', { name: en['assets.common.close'] }))
    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    expect(screen.getByTestId('asset-pick-hint')).toBeInTheDocument()
    const form = await open('FA-1')
    fireEvent.keyDown(form, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
    await open('LV-2')
    fireEvent.click(screen.getByRole('button', { name: en['assets.common.retire'] }))
    await screen.findByRole('dialog')
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' })
    expect(screen.getByRole('form')).toBeInTheDocument()
  })
})

describe('P9 languages', () => {
  it('renders titles and labels from the ru and kk catalogs', async () => {
    for (const l of ['ru', 'kk'] as const) {
      locale.current = l
      fakeServer(clientMock, DATA)
      renderAssets(PATH)
      expect(await screen.findByText(assetsMessages[l]['assets.page.title'])).toBeInTheDocument()
      expect((await screen.findAllByText(assetsMessages[l]['assets.kind.low_value'])).length).toBeGreaterThan(1)
      await open('FA-1')
      expect(screen.getAllByText(assetsMessages[l]['assets.section.depreciation']).length).toBeGreaterThan(0)
      cleanup()
      clientMock.post.mockReset()
    }
  })
})

describe('P10 permission', () => {
  it('shows the forbidden page without the atom and sends no query', async () => {
    renderAssets(PATH, withoutAtom)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(clientMock.post).not.toHaveBeenCalled()
  })
})
