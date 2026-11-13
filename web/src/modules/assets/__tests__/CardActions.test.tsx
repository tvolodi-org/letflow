// @vitest-environment jsdom
/** W1–W8, U2 — T-1880 / D-135: the Actions menu and the Operations buttons of an asset card, the pre-filled document
 *  form, Back to card and the `?card=` deep link (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import type { AccessState } from '@/auth/access/types'
import { fakeServer, rec, renderAssets } from './assetsTestKit'
import { assetsMessages } from '../assetsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const en = assetsMessages.en
const access = (...permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })
const FULL = access('AssetsCardWrite', 'AssetsRead', 'AssetsPost')
const NO_POST = access('AssetsCardWrite', 'AssetsRead')
const NO_READ = access('AssetsCardWrite', 'AssetsPost')
const API = '/api/v1/modules/assets'
const CARDS = '/admin/assets/cards'
const ROW = { asset: 'c-1', org_unit: 'u-1', location: 'l-1', material_responsible: 'e-1', actual_user: 'e-2', unit_ref: 'pcs', quantity: '1.000000000' }
const DATA = {
  assets_card: [
    rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed' }),
    rec('c-3', 'assets_card', { inventory_number: 'FA-3', name: 'Asset FA-3', kind: 'fixed' }),
    rec('c-2', 'assets_card', { inventory_number: 'FA-2', name: 'Asset FA-2', kind: 'fixed' }),
    rec('c-5', 'assets_card', { inventory_number: 'FA-5', name: 'Asset FA-5', kind: 'fixed' }),
    rec('c-6', 'assets_card', { inventory_number: 'FA-6', name: 'Asset FA-6', kind: 'fixed' }),
    rec('c-8', 'assets_card', { inventory_number: 'FA-8', name: 'Asset FA-8', kind: 'fixed', active: false }),
  ],
  org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Head office' })],
  location_node: [rec('l-1', 'location_node', { code: 'L1', name: 'Main hall' })],
  org_employee: [rec('e-1', 'org_employee', { code: 'E1', full_name: 'Aigul Responsible' }), rec('e-2', 'org_employee', { code: 'E2', full_name: 'Bolat User' })],
}
// c-1 in the register; c-2 commission issued, not posted; c-3 never commissioned; c-5 in register (different holder); c-6 same as c-1
const FACTS: Record<string, { held: boolean; rows: unknown[] }> = {
  'c-1': { held: true, rows: [ROW] },
  'c-2': { held: true, rows: [] },
  'c-3': { held: false, rows: [] },
  'c-5': { held: true, rows: [{ ...ROW, asset: 'c-5', org_unit: 'u-2' }] },
  'c-6': { held: true, rows: [ROW] },
  'c-8': { held: false, rows: [] },
}
const reads = (suffix: string) => clientMock.get.mock.calls.filter(([p]) => String(p).endsWith(suffix))
const writes = () => [...clientMock.post.mock.calls.filter(([p]) => p !== '/api/v1/entities/query'), ...clientMock.put.mock.calls, ...clientMock.patch.mock.calls]

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeServer(clientMock, DATA)
  clientMock.get.mockImplementation(async (p: string, params?: Record<string, string>) => {
    const m = /\/cards\/([^/]+)\/lock$/.exec(p)
    if (m) return { posted: false, held: FACTS[m[1]]?.held ?? false }
    if (p === `${API}/balances`) return { rows: FACTS[params?.['asset'] ?? '']?.rows ?? [], next_cursor: null }
    return { rows: [], next_cursor: null }
  })
})
afterEach(() => cleanup())

// the line editor shows the picked card in the Asset field of the first line
const lineHas = async (number: string) => {
  const row = (await screen.findAllByTestId('line-editor-row'))[0]
  await waitFor(() => expect((within(row).getByLabelText('Asset') as HTMLInputElement).value).toContain(number))
  return row
}
const item = (id: string) => screen.getByTestId(`card-action-${id}`)
const op = (id: string) => screen.getByTestId(`card-op-${id}`)

describe('W2 W5 card panel: Operations buttons and the header menu', () => {
  it('a card in the register: Commission disabled with its reason, the other three open the form', async () => {
    renderAssets(CARDS, FULL)
    fireEvent.click(await screen.findByText('FA-1'))
    const section = await screen.findByTestId('asset-operations')
    await waitFor(() => expect(op('change')).toBeEnabled())
    expect(within(section).getAllByRole('button')).toHaveLength(4)
    expect(op('commission')).toBeDisabled()
    expect(op('commission')).toHaveAttribute('title', en['assets.cardActions.reason.held'])
    expect(screen.getByTestId('card-op-reason-commission')).toHaveTextContent(en['assets.cardActions.reason.held'])
    expect(op('handover')).toBeEnabled()
    expect(op('writeoff')).toBeEnabled()
    expect(screen.getByTestId('card-actions-panel-c-1')).toBeInTheDocument()
  })

  it('table: never commissioned, issued-not-posted and retired cards', async () => {
    renderAssets(CARDS, FULL)
    fireEvent.click(await screen.findByText('FA-3'))
    await waitFor(() => expect(op('commission')).toBeEnabled())
    expect(op('change')).toBeDisabled()
    expect(op('change')).toHaveAttribute('title', en['assets.cardActions.reason.notInRegister'])
    fireEvent.click(screen.getByText('FA-2'))
    await waitFor(() => expect(op('change')).toHaveAttribute('title', en['assets.cardActions.reason.pendingPosting']))
    expect(op('commission')).toBeDisabled()
    fireEvent.click(screen.getByRole('checkbox', { name: en['assets.common.showRetired'] }))
    fireEvent.click(await screen.findByText('FA-8'))
    await waitFor(() => expect(op('writeoff')).toHaveAttribute('title', en['assets.cardActions.reason.retired']))
    for (const id of ['commission', 'change', 'handover', 'writeoff']) expect(op(id)).toBeDisabled()
  })

  it('W4 each of the four buttons opens its document form with the card as the line', async () => {
    for (const [id, card, kindText] of [
      ['commission', 'FA-3', 'Commission'],
      ['change', 'FA-1', 'Change'],
      ['handover', 'FA-1', 'Hand over'],
      ['writeoff', 'FA-1', 'Write off'],
    ] as const) {
      renderAssets(CARDS, FULL)
      fireEvent.click(await screen.findByText(card))
      await waitFor(() => expect(op(id)).toBeEnabled())
      fireEvent.click(op(id))
      const form = await screen.findByTestId('document-form')
      expect(within(form).getByLabelText(/^Kind/)).toHaveDisplayValue(new RegExp(kindText, 'i'))
      await lineHas(card)
      cleanup()
    }
  })

  it('the header menu has the same four items and the same rule', async () => {
    renderAssets(CARDS, FULL)
    fireEvent.click(await screen.findByText('FA-1'))
    fireEvent.click(await screen.findByTestId('card-actions-panel-c-1'))
    await waitFor(() => expect(item('change')).not.toHaveAttribute('aria-disabled'))
    expect(item('commission')).toHaveAttribute('aria-disabled', 'true')
    expect(item('commission')).toHaveAttribute('title', en['assets.cardActions.reason.held'])
    expect(item('commission')).toHaveTextContent(en['assets.cardActions.reason.held'])
    fireEvent.click(item('commission')) // disabled: stays on the card screen
    expect(screen.queryByTestId('document-form')).not.toBeInTheDocument()
    fireEvent.keyDown(item('change'), { key: 'Escape' })
    expect(screen.queryByRole('menu')).not.toBeInTheDocument()
  })
})

describe('W3 card list rows', () => {
  it('every row has a trigger; opening one does not open the panel; facts are read only after opening', async () => {
    renderAssets(CARDS, FULL)
    await screen.findByText('FA-1')
    expect(screen.getByTestId('card-actions-c-1')).toBeInTheDocument()
    expect(screen.getByTestId('card-actions-c-3')).toBeInTheDocument()
    expect(reads('/lock')).toHaveLength(0)
    expect(reads('/balances')).toHaveLength(0)
    fireEvent.click(screen.getByTestId('card-actions-c-1'))
    await waitFor(() => expect(item('change')).not.toHaveAttribute('aria-disabled'))
    expect(reads('/lock')).toHaveLength(1)
    expect(reads('/balances')).toHaveLength(1)
    expect(screen.queryByTestId('asset-pick-hint')).toBeInTheDocument()
    expect(screen.queryByTestId('asset-operations')).not.toBeInTheDocument()
  })

  it('each of the four row actions opens its form with the card', async () => {
    for (const id of ['commission', 'change', 'handover', 'writeoff']) {
      renderAssets(CARDS, FULL)
      await screen.findByText('FA-3')
      // c-3 for commission, c-1 for the others
      const card = id === 'commission' ? 'c-3' : 'c-1'
      fireEvent.click(screen.getByTestId(`card-actions-${card}`))
      await waitFor(() => expect(item(id)).not.toHaveAttribute('aria-disabled'))
      fireEvent.click(item(id))
      expect(await screen.findByTestId('document-form')).toBeInTheDocument()
      cleanup()
    }
  })
})

describe('U2 permissions', () => {
  it('without AssetsPost: no trigger, no operations, no Change of kind button', async () => {
    renderAssets(CARDS, NO_POST)
    fireEvent.click(await screen.findByText('FA-1'))
    await screen.findByTestId('asset-holder')
    expect(screen.queryByTestId('asset-operations')).not.toBeInTheDocument()
    expect(screen.queryByTestId('card-actions-c-1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('asset-kind-change')).not.toBeInTheDocument()
  })

  it('without AssetsRead every action is disabled with the no-read reason and no read is made', async () => {
    renderAssets(CARDS, NO_READ)
    fireEvent.click(await screen.findByText('FA-1'))
    const section = await screen.findByTestId('asset-operations')
    for (const id of ['commission', 'change', 'handover', 'writeoff']) expect(within(section).getByTestId(`card-op-${id}`)).toBeDisabled()
    expect(op('change')).toHaveAttribute('title', en['assets.cardActions.reason.noRead'])
    expect(reads('/lock')).toHaveLength(0)
  })

  it('the new sources name no role', () => {
    const dir = path.resolve(__dirname, '..')
    const files = ['cardActions.ts', 'cardPrefill.ts', 'AssetCardActionsMenu.tsx', 'AssetCardOperations.tsx', 'documents/DocumentFromCards.tsx']
    expect(readdirSync(dir)).toContain('cardActions.ts')
    for (const f of files) expect(readFileSync(path.join(dir, f), 'utf-8')).not.toMatch(new RegExp(['STORE'+'KEEPER', 'TENANT'+'_ADMIN', 'PLATFORM'+'_ADMIN', 'AUDI'+'TOR'].join('|')))
  })
})

describe('W6 change of kind page button', () => {
  it('opens the change of kind form, without a card', async () => {
    renderAssets(CARDS, FULL)
    fireEvent.click(await screen.findByTestId('asset-kind-change'))
    const form = await screen.findByTestId('document-form')
    expect(within(form).getByLabelText(/^Kind/)).toHaveDisplayValue(/change of kind/i)
  })
})

describe('W1 pre-filled form: a draft, nothing posted before Save', () => {
  it('opens with the card line and the From side of the register, sends nothing until Save, then one POST', async () => {
    fakeServer(clientMock, DATA, (_m, p, b) => (p === `${API}/documents` ? { id: 'd9', kind: 'writeoff', state: 'draft', lines: [], ...b } : {}))
    renderAssets('/admin/assets/documents/new?kind=writeoff&asset=c-1', FULL)
    const form = await screen.findByTestId('document-form')
    await waitFor(() => expect(within(form).getByLabelText(/^Org unit/)).toHaveDisplayValue('U1 - Head office'))
    const row = await lineHas('FA-1')
    expect(within(row).getByLabelText('Quantity')).toHaveValue('1')
    expect(writes()).toHaveLength(0)
    expect(screen.queryByTestId('doc-prefill-notice')).not.toBeInTheDocument()
    fireEvent.change(within(form).getByLabelText(/^Reason$/), { target: { value: 'lost' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(writes()).toHaveLength(1))
    const [path, body] = writes()[0] as [string, Record<string, unknown>]
    expect(path).toBe(`${API}/documents`)
    expect(body).toMatchObject({ kind: 'writeoff', org_unit_id: 'u-1', location_id: 'l-1', material_responsible_id: 'e-1', actual_user_id: 'e-2' })
    expect(body['lines']).toEqual([{ asset_id: 'c-1', quantity: '1' }])
  })

  it('a card held in several places: lines filled, header empty, the notice shows', async () => {
    clientMock.get.mockImplementation(async (p: string) =>
      p === `${API}/balances` ? { rows: [ROW, { ...ROW, org_unit: 'u-2' }], next_cursor: null } : { rows: [], next_cursor: null })
    renderAssets('/admin/assets/documents/new?kind=handover&asset=c-1', FULL)
    expect(await screen.findByTestId('doc-prefill-notice')).toHaveTextContent(en['assets.cardActions.prefill.manyHolders'])
    expect(writes()).toHaveLength(0)
  })
})

describe('W7 W8 Back to card and the deep link', () => {
  it('a saved document opened with ?card= shows Back to card as a link with the card number and it leads to the card panel', async () => {
    const doc = {
      id: 'd1', kind: 'change', state: 'draft', number: null, issued_at: null, header_id: 'h1', org_unit_id: 'u-1', location_id: 'l-1',
      material_responsible_id: 'e-1', actual_user_id: 'e-2', event_time: '2026-11-04T05:00:00Z', note: null,
      lines: [{ line_id: 'x1', line_no: 1, asset_id: 'c-1', quantity: '1.000000000' }],
    }
    clientMock.get.mockImplementation(async (p: string) => (p === `${API}/documents/d1` ? doc : { rows: [], next_cursor: null }))
    renderAssets('/admin/assets/documents/d1?card=c-1', FULL)
    const link = await screen.findByTestId('doc-back-to-card')
    expect(link.tagName).toBe('A')
    await waitFor(() => expect(link).toHaveTextContent('FA-1'))
    fireEvent.click(link)
    expect(await screen.findByTestId('asset-operations')).toBeInTheDocument()
    expect(screen.getByText('Asset FA-1', { selector: 'h1, h2, h3, [class*=title]' })).toBeInTheDocument()
  })

  it('W7b several ?card= params: Back to asset cards link', async () => {
    const doc = {
      id: 'd1', kind: 'change', state: 'draft', number: null, lines: [], event_time: '2026-11-04T05:00:00Z',
    }
    clientMock.get.mockImplementation(async (p: string) => (p === `${API}/documents/d1` ? doc : { rows: [], next_cursor: null }))
    renderAssets('/admin/assets/documents/d1?card=c-1&card=c-3', FULL)
    await screen.findByTestId('document-header')
    const link = screen.getByTestId('doc-back-to-card')
    expect(link.tagName).toBe('A')
    expect(link).toHaveTextContent(en['assets.cardActions.backToCards'])
  })

  it('Back to card is hidden without AssetsCardWrite, and without ?card=', async () => {
    const doc = { id: 'd1', kind: 'change', state: 'draft', number: null, lines: [], event_time: '2026-11-04T05:00:00Z' }
    clientMock.get.mockImplementation(async (p: string) => (p === `${API}/documents/d1` ? doc : { rows: [], next_cursor: null }))
    renderAssets('/admin/assets/documents/d1?card=c-1', access('AssetsRead', 'AssetsPost'))
    await screen.findByTestId('document-header')
    expect(screen.queryByTestId('doc-back-to-card')).not.toBeInTheDocument()
    cleanup()
    renderAssets('/admin/assets/documents/d1', FULL)
    await screen.findByTestId('document-header')
    expect(screen.queryByTestId('doc-back-to-card')).not.toBeInTheDocument()
  })

  it('?card= of a card outside the loaded list is read by id and opens its panel (a retired card too)', async () => {
    renderAssets(`${CARDS}?card=c-8`, FULL)
    expect(await screen.findByTestId('asset-operations')).toBeInTheDocument()
    await waitFor(() => expect(op('writeoff')).toHaveAttribute('title', en['assets.cardActions.reason.retired']))
  })

  it('an unknown ?card= leaves the panel closed, no error', async () => {
    renderAssets(`${CARDS}?card=nope`, FULL)
    expect(await screen.findByTestId('asset-pick-hint')).toBeInTheDocument()
  })
})

describe('W1b W1c W1d pre-fill batch card read', () => {
  it('W1d an unknown card id is left out with a notice', async () => {
    renderAssets('/admin/assets/documents/new?kind=change&asset=c-1&asset=nope', FULL)
    await screen.findByTestId('document-form')
    const rows = await screen.findAllByTestId('line-editor-row')
    expect(rows).toHaveLength(1)
    await waitFor(() => expect(screen.queryByTestId('doc-prefill-notice')).toBeInTheDocument())
    expect(screen.getByTestId('doc-prefill-notice')).toHaveTextContent('1')
  })

  it('W1b the Asset cell shows from the card read even when the picker list never answers', async () => {
    const original = clientMock.post.getMockImplementation()
    clientMock.post.mockImplementation(async (p: string, body: Record<string, unknown>) => {
      if (p === '/api/v1/entities/query') {
        const filters = (body['filters'] ?? []) as { field: string; op: string; value?: unknown }[]
        const isPickerQuery = filters.some((f) => f.field === 'active' && f.value === true)
          && !filters.some((f) => f.field === 'record_id')
        if (isPickerQuery) return new Promise<never>(() => undefined)
      }
      return original!(p, body)
    })
    renderAssets('/admin/assets/documents/new?kind=writeoff&asset=c-1', FULL)
    const row = await lineHas('FA-1')
    expect((within(row).getByLabelText('Asset') as HTMLInputElement).value).toContain('FA-1')
    expect(screen.queryByTestId('no-cards')).not.toBeInTheDocument()
  })
})

describe('M1 M2 M3 M4 M5 multi-select', () => {
  const tick = async (testId: string) => {
    const el = await screen.findByTestId(testId)
    const input = el.querySelector('input')
    if (input) fireEvent.click(input)
  }

  it('M1 checkboxes are present and clicking one does NOT open the panel', async () => {
    renderAssets(CARDS, FULL)
    await screen.findByText('FA-1')
    expect(screen.getByTestId('card-select-c-1')).toBeInTheDocument()
    await tick('card-select-c-1')
    expect(screen.queryByTestId('asset-pick-hint')).toBeInTheDocument()
    expect(screen.queryByTestId('asset-operations')).not.toBeInTheDocument()
    expect(screen.getByTestId('card-selection-bar')).toBeInTheDocument()
  })

  it('M2 bar: commission disabled when a chosen card is in the register', async () => {
    renderAssets(CARDS, FULL)
    await screen.findByText('FA-1')
    await tick('card-select-c-1')
    await tick('card-select-c-6')
    const bar = await screen.findByTestId('card-selection-bar')
    await waitFor(() => expect(within(bar).getByTestId('card-bulk-commission')).toBeDisabled())
    expect(within(bar).getByTestId('card-bulk-change')).toBeEnabled()
  })

  it('M3 bar: change/handover/writeoff disabled when a chosen card is not in the register', async () => {
    renderAssets(CARDS, FULL)
    await screen.findByText('FA-1')
    await tick('card-select-c-1')
    await tick('card-select-c-3')
    const bar = await screen.findByTestId('card-selection-bar')
    await waitFor(() => expect(within(bar).getByTestId('card-bulk-change')).toBeDisabled())
    expect(within(bar).getByTestId('card-bulk-change')).toBeDisabled()
    expect(within(bar).getByTestId('card-bulk-handover')).toBeDisabled()
    expect(within(bar).getByTestId('card-bulk-writeoff')).toBeDisabled()
  })

  it('M4 clear removes the bar', async () => {
    renderAssets(CARDS, FULL)
    await screen.findByText('FA-1')
    await tick('card-select-c-1')
    await screen.findByTestId('card-selection-bar')
    fireEvent.click(screen.getByTestId('card-bulk-clear'))
    await waitFor(() => expect(screen.queryByTestId('card-selection-bar')).not.toBeInTheDocument())
  })

  it('M5 two cards with different holders: manyHoldersCards notice shown', async () => {
    // c-1 (holder u-1) and c-5 (holder u-2) are both in the register with different holders
    fakeServer(clientMock, DATA, (_m, p, b) => (p === `${API}/documents` ? { id: 'd9', kind: 'change', state: 'draft', lines: [], ...b } : {}))
    renderAssets('/admin/assets/documents/new?kind=change&asset=c-1&asset=c-5', FULL)
    await screen.findByTestId('document-form')
    await waitFor(() => expect(screen.queryByTestId('doc-prefill-notice')).toBeInTheDocument())
    expect(screen.getByTestId('doc-prefill-notice')).toHaveTextContent(en['assets.cardActions.prefill.manyHoldersCards'])
  })

  it('without AssetsPost there are no checkboxes and no bar', async () => {
    renderAssets(CARDS, NO_POST)
    await screen.findByText('FA-1')
    expect(screen.queryByTestId('card-select-c-1')).not.toBeInTheDocument()
  })
})
