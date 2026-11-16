// @vitest-environment jsdom
/** W7-1..W7-6 — T-1925: the Z-7 balances sheet entry on the balances screen, its period dialog and the tenant-day rule.
 *  Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { stockMessages } from '../stockMessages'
import { sheetPeriodDefault, sheetPeriodError, tenantTodayIso, todayIso } from '../register/stockRegisterModel'
import { BAL, fakeMasters, refusal, renderStock } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const SHEET = '/api/v1/modules/stock/stock-sheet/print'
let downloads: string[] = []
const file = (cd: string | null) => ({ blob: new Blob(['x']), contentType: 'application/pdf', contentDisposition: cd })
const balances = (extra: object = {}) => ({ ledger_seq: 1, next_cursor: null, rows: [], timezone: 'Asia/Almaty', ...extra })

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue(balances())
  useUiLocaleStore.getState().setLocaleTransient('en')
  downloads = []
  URL.createObjectURL = vi.fn(() => 'blob:x')
  URL.revokeObjectURL = vi.fn()
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
    downloads.push(this.download)
  })
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

async function pick(label: string, optionText: string) {
  const select = await screen.findByLabelText(label)
  await waitFor(() => expect(within(select).getByRole('option', { name: optionText })).toBeInTheDocument())
  fireEvent.change(select, { target: { value: (within(select).getByRole('option', { name: optionText }) as HTMLOptionElement).value } })
}

async function openDialog(format: 'pdf' | 'docx' = 'docx') {
  renderStock(BAL)
  await screen.findByTestId('official-form-menu')
  await pick('Location', 'Shelf A')
  await waitFor(() => expect(screen.queryByTestId('ledger-seq') ?? screen.queryByTestId('as-of-read')).not.toBeNull())
  await userEvent.click(screen.getByTestId('official-form-menu'))
  await waitFor(() => expect(screen.getByTestId(`form-z7-${format}`)).not.toHaveAttribute('aria-disabled'))
  await userEvent.click(screen.getByTestId(`form-z7-${format}`))
  return await screen.findByTestId('sheet-period-dialog')
}

describe('W7-1 the entry needs a location', () => {
  it('disabled with its reason, no dialog and no request', async () => {
    renderStock(BAL)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z7-pdf')).toHaveAttribute('aria-disabled', 'true')
    expect(screen.getByTestId('form-z7-docx')).toHaveAttribute('aria-disabled', 'true')
    expect(screen.getAllByText(stockMessages.en['stock.balances.sheetHint']).length).toBeGreaterThan(0)
    await userEvent.click(screen.getByTestId('form-z7-pdf'))
    expect(screen.queryByTestId('sheet-period-dialog')).toBeNull()
    expect(clientMock.getBlob).not.toHaveBeenCalled()
  })
})

describe('W7-2 the period dialog and the download', () => {
  it('prefills the month start and the tenant today, Print asks the route, the file is saved', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T10:00:00Z'))
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="stock-sheet_L1_Z-7.docx"'))
    const dialog = await openDialog('docx')
    expect(within(dialog).getByLabelText('Period from')).toHaveValue('2026-11-01')
    expect(within(dialog).getByLabelText('Period to')).toHaveValue('2026-11-14')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Print' }))
    await waitFor(() =>
      expect(clientMock.getBlob).toHaveBeenCalledWith(SHEET, { location: 'l1', from: '2026-11-01', to: '2026-11-14', format: 'docx', lang: 'ru' }),
    )
    await waitFor(() => expect(downloads).toEqual(['stock-sheet_L1_Z-7.docx']))
  })

  it('a Kazakh screen asks for kk', async () => {
    useUiLocaleStore.getState().setLocaleTransient('kk')
    clientMock.getBlob.mockResolvedValue(file(null))
    renderStock(BAL)
    await screen.findByTestId('official-form-menu')
    await pick('Сақтау орны', 'Shelf A')
    await waitFor(() => expect(screen.getByTestId('ledger-seq')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await waitFor(() => expect(screen.getByTestId('form-z7-pdf')).not.toHaveAttribute('aria-disabled'))
    await userEvent.click(screen.getByTestId('form-z7-pdf'))
    const dialog = await screen.findByTestId('sheet-period-dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Басып шығару' }))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(SHEET, expect.objectContaining({ location: 'l1', format: 'pdf', lang: 'kk' })))
  })
})

describe('W7-3 the day rule', () => {
  it('W7-3 an as-of date becomes the default end', async () => {
    clientMock.get.mockResolvedValue(balances({ as_of_date: '2026-10-20' }))
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T10:00:00Z'))
    const dialog = await openDialog('pdf')
    expect(within(dialog).getByLabelText('Period to')).toHaveValue('2026-10-20')
    expect(within(dialog).getByLabelText('Period from')).toHaveValue('2026-10-01')
  })

  it('W7-3b the dialog uses the tenant day, not the browser day', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T20:30:00Z'))
    // Almaty (UTC+5) is already on the 15th
    const dialog = await openDialog('pdf')
    expect(within(dialog).getByLabelText('Period to')).toHaveValue('2026-11-15')
    expect(within(dialog).queryByText(stockMessages.en['stock.balances.sheet.future'])).toBeNull()
    expect(within(dialog).getByRole('button', { name: 'Print' })).toBeEnabled()
  })

  it('W7-3b a UTC-11 tenant is still on the 14th at the same instant', async () => {
    clientMock.get.mockResolvedValue(balances({ timezone: 'Pacific/Pago_Pago' }))
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T20:30:00Z'))
    const dialog = await openDialog('pdf')
    expect(within(dialog).getByLabelText('Period to')).toHaveValue('2026-11-14')
  })

  it('tenantTodayIso: zones, a missing zone and an unknown zone', () => {
    const at = new Date('2026-11-14T20:30:00Z')
    expect(tenantTodayIso('Asia/Almaty', at)).toBe('2026-11-15')
    expect(tenantTodayIso('Pacific/Pago_Pago', at)).toBe('2026-11-14')
    expect(tenantTodayIso(null, at)).toBe(todayIso())
    expect(tenantTodayIso(undefined, at)).toBe(todayIso())
    expect(tenantTodayIso('Not/AZone', at)).toBe(todayIso())
  })
})

describe('W7-4 validation', () => {
  it('from after to names the from field and disables Print; Escape closes without a request', async () => {
    const dialog = await openDialog('pdf')
    const from = within(dialog).getByLabelText('Period from')
    fireEvent.change(from, { target: { value: '2999-01-01' } })
    expect(await within(dialog).findByText(stockMessages.en['stock.balances.sheet.fromAfterTo'])).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: 'Print' })).toBeDisabled()
    await userEvent.keyboard('{Escape}')
    await waitFor(() => expect(screen.queryByTestId('sheet-period-dialog')).toBeNull())
    expect(clientMock.getBlob).not.toHaveBeenCalled()
  })

  it('a pure check of the three rules', () => {
    expect(sheetPeriodError('2026-11-02', '2026-11-01', '2026-11-14')).toEqual({ from: 'stock.balances.sheet.fromAfterTo' })
    expect(sheetPeriodError('2026-11-01', '2026-11-15', '2026-11-14')).toEqual({ to: 'stock.balances.sheet.future' })
    expect(sheetPeriodError('', '2026-11-14', '2026-11-14')).toEqual({ from: 'stock.balances.sheet.required' })
    expect(sheetPeriodError('2026-11-01', '2026-11-14', '2026-11-14')).toEqual({})
  })
})

describe('W7-5 refusals', () => {
  it('404 says which period was empty', async () => {
    clientMock.getBlob.mockRejectedValue(refusal(404))
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T10:00:00Z'))
    const dialog = await openDialog('pdf')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Print' }))
    expect(await screen.findByText('No stock that you may see at this location from 2026-11-01 to 2026-11-14.')).toBeInTheDocument()
  })

  it('422 sheet_too_long shows its reason', async () => {
    clientMock.getBlob.mockRejectedValue(refusal(422, 'sheet_too_long'))
    const dialog = await openDialog('pdf')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Print' }))
    expect(await screen.findByText(/The sheet is too long to print/)).toBeInTheDocument()
  })
})

describe('W7-6 catalogs and the model', () => {
  it('every new key has a ru and a kk text that differs from English', () => {
    const keys = Object.keys(stockMessages.en).filter((k) => k.startsWith('stock.balances.sheet') || k === 'stock.form.z7')
    expect(keys.length).toBeGreaterThanOrEqual(11)
    for (const k of keys) {
      for (const l of ['ru', 'kk'] as const) {
        expect(stockMessages[l][k]?.trim(), `${l} ${k}`).toBeTruthy()
        expect(stockMessages[l][k]).not.toBe(stockMessages.en[k])
      }
    }
  })

  it('sheetPeriodDefault: month start, future as-of, empty', () => {
    expect(sheetPeriodDefault('', '2024-02-29')).toEqual({ from: '2024-02-01', to: '2024-02-29' })
    expect(sheetPeriodDefault('2026-10-31', '2026-11-14')).toEqual({ from: '2026-10-01', to: '2026-10-31' })
    expect(sheetPeriodDefault('2026-12-01', '2026-11-14')).toEqual({ from: '2026-11-01', to: '2026-11-14' })
  })
})
