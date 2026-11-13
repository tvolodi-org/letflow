// @vitest-environment jsdom
/** HL3 HL4 — T-1872: opening Help (a side panel) never remounts the count sheet or the stock document form and
 *  never loses what was typed. Network mocked, real route table. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { LIST as COUNT_LIST, fakeCounts, line, order, renderCounts } from './countsTestKit'
import { LIST, fakeMasters, renderStock, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

describe('HL3 count sheet', () => {
  it('keeps the typed count and the same sheet and input elements across Help open, Escape and Close', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'counting' })], linePages: [[line(1), line(2)]] })
    renderCounts(`${COUNT_LIST}/c1`)
    const sheet = await screen.findByTestId('count-sheet')
    const input = (await screen.findByTestId('count-input-1')) as HTMLInputElement
    fireEvent.change(input, { target: { value: '4.25' } })
    fireEvent.click(screen.getByTestId('help-link'))
    expect(screen.getByTestId('help-side-panel')).toBeInTheDocument()
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByTestId('help-side-panel')).toBeNull()
    expect(sheet.isConnected).toBe(true) // Escape in the panel does not close the count sheet
    fireEvent.click(screen.getByTestId('help-link'))
    fireEvent.click(screen.getByTestId('help-side-close'))
    expect(screen.getByTestId('count-sheet')).toBe(sheet)
    expect(screen.getByTestId('count-input-1')).toBe(input)
    expect(input.value).toBe('4.25')
  })
})

describe('HL4 stock document form', () => {
  it('keeps the typed header value and the same form element across Help open, Escape and Close', async () => {
    fakeMasters(clientMock)
    clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
    renderStock(`${LIST}/new`, withPost)
    const form = await screen.findByTestId('document-form')
    const note = within(form).getByLabelText(/^Note/) as HTMLInputElement
    fireEvent.change(note, { target: { value: 'first batch' } })
    fireEvent.click(screen.getByTestId('help-link'))
    expect(screen.getByTestId('help-side-panel')).toBeInTheDocument()
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.queryByTestId('help-side-panel')).toBeNull()
    expect(form.isConnected).toBe(true) // Escape in the panel does not leave the document
    fireEvent.click(screen.getByTestId('help-link'))
    fireEvent.click(screen.getByTestId('help-side-close'))
    expect(screen.getByTestId('document-form')).toBe(form)
    expect(within(form).getByLabelText(/^Note/)).toBe(note)
    expect(note.value).toBe('first batch')
  })
})
