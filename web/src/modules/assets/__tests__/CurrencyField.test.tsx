// @vitest-environment jsdom
/** REQ-828 — the asset card Currency field is a dropdown of the currency directory: two options (empty = tenant
 *  currency, and the tenant currency with its name), a legacy stored value as a third disabled option, the facts show
 *  code and name, and the two refusals have texts in en, ru and kk. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { importMessages } from '@/i18n/importMessages'
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

const DIRECTORY = {
  tenant_currency: 'KZT',
  currencies: [
    { code: 'KZT', numeric_code: '398', minor_units: 2, names: { en: 'Tenge', ru: 'Тенге', kk: 'Теңге' }, active: true },
    { code: 'USD', numeric_code: '840', minor_units: 2, names: { en: 'US dollar', ru: 'Доллар США', kk: 'АҚШ доллары' }, active: false },
  ],
}
const card = (extra: Record<string, unknown> = {}) =>
  rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed', ...extra })
const PATH = '/admin/assets/cards'
const select = () => document.querySelector('select[name="currency"]') as HTMLSelectElement
const optionTexts = () => Array.from(select().options).map((o) => [o.value, o.textContent])

async function openCard(data: ReturnType<typeof card>[], onWrite?: Parameters<typeof fakeServer>[2]) {
  fakeServer(clientMock, { assets_card: data, org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Head office' })] }, onWrite)
  renderAssets(PATH)
  fireEvent.click(await screen.findByText('FA-1'))
  await screen.findByRole('form')
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  clientMock.get.mockReset()
  clientMock.get.mockImplementation(async (p: string) => (p === '/api/v1/currencies' ? DIRECTORY : { posted: false }))
  locale.current = 'en'
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('C1 the dropdown', () => {
  it('offers exactly the empty choice and the tenant currency with its name; saving sends the code', async () => {
    await openCard([card()], () => ({}))
    await waitFor(() => expect(select().options).toHaveLength(2))
    expect(optionTexts()).toEqual([
      ['', 'Tenant currency'],
      ['KZT', 'KZT — Tenge'],
    ])
    fireEvent.change(select(), { target: { value: 'KZT' } })
    fireEvent.click(screen.getByTestId('asset-save'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body).toMatchObject({ currency: 'KZT' })
  })

  it('shows the option name in the UI language', async () => {
    locale.current = 'ru'
    await openCard([card()])
    await waitFor(() => expect(select().options).toHaveLength(2))
    expect(optionTexts()[1]).toEqual(['KZT', 'KZT — Тенге'])
    expect(optionTexts()[0]).toEqual(['', assetsMessages.ru['assets.field.currencyTenant']])
  })

  it('a stored value that is not the tenant currency is a third, disabled option with the hint', async () => {
    await openCard([card({ currency: 'TNG' })])
    await waitFor(() => expect(select().options).toHaveLength(3))
    expect(optionTexts()[2]).toEqual(['TNG', 'TNG'])
    expect(select().options[2]).toBeDisabled()
    expect(select().value).toBe('TNG')
    expect(screen.getByText(assetsMessages.en['assets.field.currencyLegacyHint'])).toBeInTheDocument()
  })
})

describe('C2 refusals', () => {
  it('currency_unknown from the card route marks the field currency, in en, ru and kk', async () => {
    for (const l of ['en', 'ru', 'kk'] as const) {
      locale.current = l
      clientMock.post.mockReset()
      await openCard([card()], () => {
        throw problem(422, { reason: 'currency_unknown' })
      })
      fireEvent.change(document.querySelector('[name="name"]') as HTMLInputElement, { target: { value: 'Changed' } })
      fireEvent.click(screen.getByTestId('asset-save'))
      expect(await screen.findByRole('alert')).toHaveTextContent(assetsMessages[l]['assets.error.currency_unknown'])
      expect(select()).toHaveAttribute('aria-invalid', 'true')
      cleanup()
    }
  })

  it('the import reason asset_currency_unknown has a text in en, ru and kk', () => {
    for (const l of ['en', 'ru', 'kk'] as const) {
      expect(importMessages[l]['import.reason.asset_currency_unknown'], l).toBeTruthy()
    }
  })
})

describe('C3 the facts of a retired card', () => {
  it('show the code with its name', async () => {
    fakeServer(clientMock, { assets_card: [rec('c-0', 'assets_card', { inventory_number: 'AA-0', name: 'Other', kind: 'fixed' }), card({ currency: 'KZT', active: false })], org_unit: [] })
    renderAssets(PATH)
    fireEvent.click(await screen.findByLabelText(assetsMessages.en['assets.common.showRetired']))
    fireEvent.click(await screen.findByText('FA-1'))
    const dd = await screen.findByText('KZT — Tenge')
    expect(within(dd.closest('dl') as HTMLElement).getByText('KZT — Tenge')).toBeInTheDocument()
  })
})
