// @vitest-environment jsdom
/** A1–A11 — T-1954: the asset card is tabbed (Main, Accounting); the Actions menu stays in the header, no Operations row. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import type { AccessState } from '@/auth/access/types'
import { clearAllToasts } from '@/hooks/useToast'
import { fakeServer, problem, rec, renderAssets, writeCalls } from './assetsTestKit'
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
const access = (...permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })
const FULL = access('AssetsCardWrite', 'AssetsRead', 'AssetsPost')
const PATH = '/admin/assets/cards'
const DATA = {
  assets_card: [
    rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed', acquisition_cost: '10' }),
    rec('c-2', 'assets_card', { inventory_number: 'FA-2', name: 'Asset FA-2', kind: 'fixed' }),
    rec('c-8', 'assets_card', { inventory_number: 'FA-8', name: 'Asset FA-8', kind: 'fixed', active: false, acquisition_cost: '5' }),
  ],
}
const field = (name: string) => document.querySelector(`[name="${name}"]`) as HTMLInputElement
const tab = (name: string) => screen.getByRole('tab', { name })
const open = async (no: string) => {
  fireEvent.click(await screen.findByText(no))
  await screen.findByTestId('detail-tabs')
}
const hidden = (name: string) => field(name).closest('[role="tabpanel"]') as HTMLElement

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  clientMock.get.mockImplementation(async (p: string) => (p.endsWith('/lock') ? { posted: false, held: true } : { rows: [], next_cursor: null }))
  fakeServer(clientMock, DATA)
  locale.current = 'en'
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('card tabs', () => {
  it('A1 opens on Main: identity and holder visible, the cost field is in a hidden panel', async () => {
    renderAssets(PATH, FULL)
    await open('FA-1')
    expect(tab('Main')).toHaveAttribute('aria-selected', 'true')
    expect(hidden('name')).not.toHaveAttribute('hidden')
    expect(await screen.findByTestId('asset-holder')).toBeVisible()
    expect(hidden('acquisition_cost')).toHaveAttribute('hidden')
  })

  it('A2 Accounting shows acquisition and depreciation fields, the identity inputs are hidden', async () => {
    renderAssets(PATH, FULL)
    await open('FA-1')
    fireEvent.click(tab('Accounting'))
    expect(hidden('acquisition_cost')).not.toHaveAttribute('hidden')
    expect(hidden('name')).toHaveAttribute('hidden')
    expect(screen.getByTestId('asset-holder')).not.toBeVisible()
  })

  it('A3 edits on both tabs go out in one PATCH', async () => {
    renderAssets(PATH, FULL)
    await open('FA-1')
    fireEvent.change(field('name'), { target: { value: 'Renamed' } })
    fireEvent.click(tab('Accounting'))
    fireEvent.change(field('acquisition_cost'), { target: { value: '99' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.method).toBe('PATCH')
    expect(call.body).toMatchObject({ name: 'Renamed', acquisition_cost: '99' })
  })

  it('A4 the tab survives Save and a click on another row, and resets to Main when the panel closes', async () => {
    renderAssets(PATH, FULL)
    await open('FA-1')
    fireEvent.click(tab('Accounting'))
    fireEvent.change(field('acquisition_cost'), { target: { value: '11' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    await screen.findByText(en['assets.toast.updated'])
    expect(screen.getByRole('heading', { name: 'Asset FA-1' })).toBeInTheDocument()
    expect(tab('Accounting')).toHaveAttribute('aria-selected', 'true')
    fireEvent.click(screen.getByText('FA-2'))
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Asset FA-2' })).toBeInTheDocument())
    expect(tab('Accounting')).toHaveAttribute('aria-selected', 'true')
    fireEvent.click(screen.getByRole('button', { name: en['assets.common.close'] }))
    await open('FA-1')
    expect(tab('Main')).toHaveAttribute('aria-selected', 'true')
  })

  it('A5 a refused Save with the name cleared on Accounting goes back to Main and focuses the name', async () => {
    renderAssets(PATH, FULL)
    await open('FA-1')
    fireEvent.change(field('name'), { target: { value: '' } })
    fireEvent.click(tab('Accounting'))
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(tab('Main')).toHaveAttribute('aria-selected', 'true'))
    await waitFor(() => expect(document.activeElement).toBe(field('name')))
    expect(writeCalls(clientMock)).toHaveLength(0)
  })

  it('A6 a server error on a cost field while on Main switches to Accounting and focuses it', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(422, { reason: 'record_payload_invalid', fields: ['acquisition_cost'] })
    })
    renderAssets(PATH, FULL)
    await open('FA-1')
    fireEvent.change(field('acquisition_cost'), { target: { value: '12' } })
    fireEvent.change(field('name'), { target: { value: 'Renamed' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(tab('Accounting')).toHaveAttribute('aria-selected', 'true'))
    await waitFor(() => expect(document.activeElement).toBe(field('acquisition_cost')))
  })

  it('A7 a retired card has no form: facts on both tabs, no Retire button', async () => {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByRole('checkbox', { name: en['assets.common.showRetired'] }))
    fireEvent.click(await screen.findByText('FA-8'))
    const main = await screen.findByTestId('asset-facts-main')
    expect(main).toHaveTextContent('FA-8')
    expect(main).not.toHaveTextContent(en['assets.field.cost'])
    fireEvent.click(tab('Accounting'))
    expect(screen.getByTestId('asset-facts-accounting')).toHaveTextContent(en['assets.field.cost'])
    expect(screen.queryByRole('button', { name: en['assets.common.retire'] })).not.toBeInTheDocument()
  })

  it('A8 the Actions menu is in the header on both tabs, no Operations row', async () => {
    renderAssets(PATH, FULL)
    await open('FA-1')
    for (const name of ['Main', 'Accounting']) {
      fireEvent.click(tab(name))
      expect(within(screen.getByTestId('detail-header')).getByTestId('card-actions-panel-c-1')).toBeInTheDocument()
    }
    expect(screen.queryByTestId('asset-operations')).not.toBeInTheDocument()
    expect(document.querySelector('[data-testid^="card-op-"]')).toBeNull()
  })

  it('A9 without AssetsRead no Holder; without AssetsPost no Actions trigger, tabs unchanged', async () => {
    renderAssets(PATH, access('AssetsCardWrite', 'AssetsPost'))
    await open('FA-1')
    expect(screen.queryByTestId('asset-holder')).not.toBeInTheDocument()
    cleanup()
    renderAssets(PATH, access('AssetsCardWrite', 'AssetsRead'))
    await open('FA-1')
    expect(screen.queryByTestId('card-actions-panel-c-1')).not.toBeInTheDocument()
    expect(tab('Accounting')).toBeInTheDocument()
  })

  it('A10 the tab labels are Russian in ru and Kazakh in kk', async () => {
    locale.current = 'ru'
    renderAssets(PATH, FULL)
    await open('FA-1')
    expect(tab(assetsMessages.ru['assets.tabs.main'])).toBeInTheDocument()
    expect(tab('Учёт')).toBeInTheDocument()
    cleanup()
    locale.current = 'kk'
    renderAssets(PATH, FULL)
    await open('FA-1')
    expect(tab('Есеп')).toBeInTheDocument()
  })

  it('A11 the create form has no tabs', async () => {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByTestId('asset-create'))
    await screen.findByRole('form')
    expect(screen.queryByTestId('detail-tabs')).not.toBeInTheDocument()
  })
})
