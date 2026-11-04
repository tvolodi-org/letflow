// @vitest-environment jsdom
/** I1 — GH 3767 / REQ-724: same keys in en, ru, kk; screens follow the language store. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { stockMessages } from '../stockMessages'
import { BAL, MOV, fakeMasters, renderStock } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ next_cursor: null, rows: [] })
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('I1 catalogs', () => {
  it('have the same non-empty keys in en, ru and kk', () => {
    const keys = Object.keys(stockMessages.en).sort()
    expect(keys.length).toBeGreaterThan(50)
    for (const l of ['ru', 'kk'] as const) {
      expect(Object.keys(stockMessages[l]).sort()).toEqual(keys)
      for (const k of keys) expect(stockMessages[l][k].trim()).not.toBe('')
    }
    for (const l of ['ru', 'kk'] as const) {
      for (const k of ['stock.balances.title', 'stock.movements.title', 'stock.common.loadMore']) {
        expect(stockMessages[l][k]).not.toBe(stockMessages.en[k])
      }
    }
  })
})

describe('I1 language switch', () => {
  for (const [path, id] of [[BAL, 'stock.balances.title'], [MOV, 'stock.movements.title']] as const) {
    it(`${path} re-renders in ru and kk without reload`, async () => {
      renderStock(path)
      expect(await screen.findByRole('heading', { level: 1 })).toHaveTextContent(stockMessages.en[id])
      for (const l of ['ru', 'kk'] as const) {
        act(() => useUiLocaleStore.getState().setLocaleTransient(l))
        expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(stockMessages[l][id])
      }
    })
  }
})
