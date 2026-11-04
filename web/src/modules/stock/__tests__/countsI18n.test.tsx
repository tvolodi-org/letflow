// @vitest-environment jsdom
/** I1–I3 — GH 3735 / REQ-702 criterion 5: same keys in en, ru, kk; no text outside the message file; the screens follow
 *  the language store. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { countsEn, countsKk, countsRu } from '../counts/countsMessages'
import { stockMessages } from '../stockMessages'
import { LIST, fakeCounts, order, renderCounts } from './countsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('I1 catalogs', () => {
  it('have the same non-empty count keys in en, ru and kk, and stockMessages carries them', () => {
    const keys = Object.keys(countsEn).sort()
    expect(keys.length).toBeGreaterThan(100)
    for (const cat of [countsRu, countsKk]) {
      expect(Object.keys(cat).sort()).toEqual(keys)
      for (const k of keys) expect(cat[k].trim()).not.toBe('')
    }
    for (const k of ['counts.title', 'counts.new', 'counts.action.close']) {
      expect(countsRu[k]).not.toBe(countsEn[k])
      expect(countsKk[k]).not.toBe(countsEn[k])
    }
    for (const l of ['en', 'ru', 'kk'] as const) for (const k of keys) expect(stockMessages[l][k]).toBeTruthy()
  })
})

describe('I3 language switch', () => {
  it('re-renders the list and the detail in ru and kk without reload', async () => {
    fakeCounts(clientMock, { orders: [order()] })
    renderCounts(`${LIST}/c1`)
    expect(await screen.findByRole('heading', { level: 1 })).toHaveTextContent(countsEn['counts.title'])
    expect(await screen.findByTestId('count-issue')).toHaveTextContent(countsEn['counts.action.issue'])
    for (const [l, cat] of [['ru', countsRu], ['kk', countsKk]] as const) {
      act(() => useUiLocaleStore.getState().setLocaleTransient(l))
      expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(cat['counts.title'])
      expect(screen.getByTestId('count-issue')).toHaveTextContent(cat['counts.action.issue'])
      expect(screen.getAllByText(cat['counts.status.draft']).length).toBeGreaterThan(0)
    }
  })
})
