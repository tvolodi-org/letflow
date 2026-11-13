// @vitest-environment jsdom
/** HL1 HL2 HL6 — T-1872: opening Help (a side panel) never remounts the working form and never loses typed data;
 *  a language switch keeps it too. Network mocked, real route table. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, screen, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { fakeServer, renderAssets } from './assetsTestKit'
import { LIST, fakeDocument, fakeMasters, renderAssets as renderRegister, withAll, assetDoc } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

const field = (name: string) => document.querySelector(`[name="${name}"]`) as HTMLInputElement

async function openCardForm() {
  fakeServer(clientMock, { assets_card: [], org_unit: [] })
  renderAssets('/admin/assets/cards')
  fireEvent.click(await screen.findByTestId('asset-create'))
  const form = await screen.findByRole('form')
  fireEvent.change(field('inventory_number'), { target: { value: 'FA-77' } })
  return form
}

describe('HL1 asset card form', () => {
  it('keeps the typed value and the same form element across Help open, Escape and Close', async () => {
    const form = await openCardForm()
    const input = field('inventory_number')
    fireEvent.click(screen.getByTestId('help-link'))
    expect(screen.getByTestId('help-side-panel')).toBeInTheDocument()
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByTestId('help-side-panel')).toBeNull()
    expect(form.isConnected).toBe(true) // Escape in the panel closes only the panel
    fireEvent.click(screen.getByTestId('help-link'))
    fireEvent.click(screen.getByTestId('help-side-close'))
    expect(screen.queryByTestId('help-side-panel')).toBeNull()
    expect(screen.getByRole('form')).toBe(form)
    expect(field('inventory_number')).toBe(input)
    expect(input.isConnected).toBe(true)
    expect(input.value).toBe('FA-77')
  })
})

describe('HL6 language switch', () => {
  it('keeps the typed value and the same input element when the UI language changes', async () => {
    await openCardForm()
    const input = field('inventory_number')
    for (const l of ['ru', 'kk', 'en'] as const) {
      act(() => useUiLocaleStore.getState().setLocaleTransient(l))
      expect(field('inventory_number')).toBe(input)
      expect(input.isConnected).toBe(true)
      expect(input.value).toBe('FA-77')
    }
  })
})

describe('HL2 asset document form', () => {
  it('keeps the typed header value and the same form element across Help open and Close', async () => {
    fakeMasters(clientMock)
    fakeDocument(clientMock, assetDoc({ id: 'dn' }))
    renderRegister(`${LIST}/new`, withAll)
    const form = await screen.findByTestId('document-form')
    const date = within(form).getByLabelText('Time, date') as HTMLInputElement
    fireEvent.change(date, { target: { value: '2026-11-04' } })
    fireEvent.click(screen.getByTestId('help-link'))
    expect(screen.getByTestId('help-side-panel')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('help-side-close'))
    expect(screen.queryByTestId('help-side-panel')).toBeNull()
    expect(screen.getByTestId('document-form')).toBe(form)
    expect((within(form).getByLabelText('Time, date') as HTMLInputElement)).toBe(date)
    expect(date.value).toBe('2026-11-04')
  })
})
