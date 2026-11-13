// @vitest-environment jsdom
/** REQ-828 — the price and value headers of the stock receipt and opening lines carry the tenant currency code, and
 *  the lines catalog has no fixed currency sign. */
import { readFileSync } from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import { LIST, addFirstLine, fakeMasters, renderStock, withPost } from './stockTestKit'
import { formatLines, linesMessages } from '@/components/ui/lines/linesMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const DIRECTORY = {
  tenant_currency: 'USD',
  currencies: [{ code: 'USD', numeric_code: '840', minor_units: 2, names: { en: 'US dollar', ru: 'Доллар США', kk: 'АҚШ доллары' }, active: true }],
}
const headers = () => screen.getAllByRole('columnheader').map((h) => h.textContent ?? '')

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockImplementation(async (p: string) => (p === '/api/v1/currencies' ? DIRECTORY : { rows: [], next_cursor: null }))
  localStorage.clear()
})
afterEach(() => cleanup())

describe('currency in the line headers', () => {
  it.each(['receipt', 'opening'])('%s: price and value headers show USD and no tenge sign', async (kind) => {
    renderStock(`${LIST}/new?kind=${kind}`, withPost)
    await addFirstLine()
    await waitFor(() => expect(headers()).toContain('Unit price, USD'))
    expect(headers()).toContain('Line value, USD')
    expect(headers().join('')).not.toContain('₸')
  })

  it('without a known currency the headers have no tail', async () => {
    clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
    renderStock(`${LIST}/new?kind=receipt`, withPost)
    await addFirstLine()
    expect(headers()).toContain('Unit price')
  })

  it('the lines catalog has no fixed sign and fills {cur}', () => {
    expect(readFileSync('src/components/ui/lines/linesMessages.ts', 'utf8')).not.toContain('₸')
    for (const l of ['en', 'ru', 'kk'] as const) {
      for (const id of ['c.price', 'c.value', 'f.price', 'f.value'] as const) {
        expect(linesMessages[l][id]).toContain('{cur}')
        expect(formatLines(l, id, { cur: 'USD' })).toMatch(/, USD$/)
        expect(formatLines(l, id)).not.toContain(',')
      }
    }
  })
})
