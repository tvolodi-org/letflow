// @vitest-environment jsdom
/** D1–D6 — T-1530: the read-only depreciation block of the asset card ("information only, not calculated"),
 *  and the method and rate fields of the form. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { fakeServer, rec, renderAssets, writeCalls } from './assetsTestKit'
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
    card('c-1', 'FA-1', {
      depreciation_method: 'straight line', depreciation_rate: '12.5', accumulated_depreciation: '100',
      book_value: '999', depreciation_as_of: '2026-09-30',
    }),
    card('c-2', 'FA-2', { book_value: '55.00' }),
    card('c-3', 'FA-3', { acquisition_cost: '10' }),
    card('c-4', 'FA-4', { active: false, depreciation_method: 'declining', accumulated_depreciation: '7' }),
  ],
  org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Head office' })],
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

describe('depreciation block', () => {
  it('D1 shows method, rate, accumulated, book value, as-of and the info-only label', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-1')
    const block = await screen.findByTestId('asset-depreciation')
    expect(within(block).getByText(en['assets.depreciation.infoOnly'])).toBeInTheDocument()
    for (const v of ['straight line', '12.5', '100', '999']) expect(within(block).getByText(v)).toBeInTheDocument()
    for (const k of ['depMethod', 'depRate', 'accumulated', 'bookValue', 'asOf'] as const) {
      expect(within(block).getByText(en[`assets.field.${k}`])).toBeInTheDocument()
    }
    expect(block.querySelectorAll('dt')).toHaveLength(5)
  })

  it('D2 hides empty rows, and the whole block when nothing is set', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-2')
    const block = await screen.findByTestId('asset-depreciation')
    expect(block.querySelectorAll('dt')).toHaveLength(1)
    expect(within(block).getByText('55.00')).toBeInTheDocument()
    fireEvent.click(screen.getByText('FA-3'))
    await waitFor(() => expect(field('inventory_number').value).toBe('FA-3'))
    expect(screen.queryByTestId('asset-depreciation')).not.toBeInTheDocument()
  })

  it('D3 shows the stored text, no derived row', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await open('FA-1')
    const block = await screen.findByTestId('asset-depreciation')
    expect(within(block).getByText('100')).toBeInTheDocument()
    expect(within(block).getByText('999')).toBeInTheDocument()
    expect(block.textContent).not.toMatch(/899|1099/)
  })

  it('D4 label and row names come from the en, ru and kk catalogs', async () => {
    for (const l of ['en', 'ru', 'kk'] as const) {
      locale.current = l
      fakeServer(clientMock, DATA)
      renderAssets(PATH)
      await open('FA-1')
      const block = await screen.findByTestId('asset-depreciation')
      const m = assetsMessages[l]
      expect(within(block).getByText(m['assets.depreciation.infoOnly'])).toBeInTheDocument()
      expect(within(block).getByText(m['assets.field.depMethod'])).toBeInTheDocument()
      expect(within(block).getByText(m['assets.field.depRate'])).toBeInTheDocument()
      cleanup()
    }
  })

  it('D5 a retired card shows the block once; the facts no longer repeat its rows', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    await screen.findByText('FA-1')
    fireEvent.click(screen.getByLabelText(en['assets.common.showRetired']))
    fireEvent.click(await screen.findByText('FA-4'))
    const block = await screen.findByTestId('asset-depreciation')
    expect(within(block).getByText('declining')).toBeInTheDocument()
    expect(screen.queryByTestId('asset-save')).not.toBeInTheDocument()
    expect(screen.getAllByText(en['assets.field.accumulated'])).toHaveLength(1)
  })

  it('D6 the form sends method and rate on create; a bad rate blocks Save', async () => {
    fakeServer(clientMock, DATA)
    renderAssets(PATH)
    fireEvent.click(await screen.findByTestId('asset-create'))
    await screen.findByRole('form', { name: en['assets.page.createTitle'] })
    fireEvent.change(field('inventory_number'), { target: { value: 'FA-9' } })
    fireEvent.change(field('name'), { target: { value: 'New' } })
    fireEvent.change(field('depreciation_method'), { target: { value: 'linear' } })
    fireEvent.change(field('depreciation_rate'), { target: { value: '1,5' } })
    expect(field('depreciation_rate')).toHaveAttribute('aria-invalid', 'true')
    fireEvent.click(screen.getByTestId('asset-save'))
    expect(writeCalls(clientMock)).toHaveLength(0)
    fireEvent.change(field('depreciation_rate'), { target: { value: '20' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body).toMatchObject({ depreciation_method: 'linear', depreciation_rate: '20' })
  })
})
