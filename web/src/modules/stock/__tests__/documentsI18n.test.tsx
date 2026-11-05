// @vitest-environment jsdom
/** C6-a — GH 3769 / REQ-722: same document keys in en, ru, kk; the screens follow the language store. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DOC_KINDS, DOC_REASONS, DOC_EXTRA_REASONS, DOC_STATES, REVERSE_REASONS, WRITE_OFF_REASONS } from '../documents/documentsModel'
import { stockMessages } from '../stockMessages'
import { LIST, fakeDocument, fakeMasters, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const docKeys = (l: 'en' | 'ru' | 'kk') => Object.keys(stockMessages[l]).filter((k) => k.startsWith('stock.doc.')).sort()

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
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

describe('C6-a catalog', () => {
  it('has the same non-empty keys in en, ru and kk', () => {
    expect(docKeys('en').length).toBeGreaterThan(80)
    expect(docKeys('ru')).toEqual(docKeys('en'))
    expect(docKeys('kk')).toEqual(docKeys('en'))
    for (const l of ['en', 'ru', 'kk'] as const) for (const k of docKeys(l)) expect(stockMessages[l][k].trim(), `${l} ${k}`).not.toBe('')
    for (const k of ['stock.doc.title', 'stock.doc.new', 'stock.doc.error.busy']) {
      expect(stockMessages.ru[k]).not.toBe(stockMessages.en[k])
      expect(stockMessages.kk[k]).not.toBe(stockMessages.en[k])
    }
  })
  it('has a key for every kind, state, reason and enum word', () => {
    const need = [
      ...DOC_KINDS.map((k) => `kind.${k}`), ...DOC_STATES.map((s) => `state.${s}`),
      ...[...DOC_REASONS, ...DOC_EXTRA_REASONS].map((r) => `error.${r}`),
      ...REVERSE_REASONS.map((r) => `reverseReason.${r}`), ...WRITE_OFF_REASONS.map((r) => `writeOffReason.${r}`),
    ]
    for (const k of need) expect(stockMessages.en[`stock.doc.${k}`], k).toBeTruthy()
  })
})

describe('C6-a screens follow the language', () => {
  it('list, view and form headings change with the store', async () => {
    fakeDocument(clientMock, stockDoc())
    for (const [path, key] of [[LIST, 'stock.doc.title'], [`${LIST}/d1`, 'stock.doc.viewLede'], [`${LIST}/new`, 'stock.doc.newTitle']] as const) {
      renderStock(path, withPost)
      expect(await screen.findByText(stockMessages.en[key])).toBeInTheDocument()
      await act(async () => useUiLocaleStore.getState().setLocaleTransient('ru'))
      expect(await screen.findByText(stockMessages.ru[key])).toBeInTheDocument()
      await act(async () => useUiLocaleStore.getState().setLocaleTransient('kk'))
      expect(await screen.findByText(stockMessages.kk[key])).toBeInTheDocument()
      cleanup()
      useUiLocaleStore.getState().setLocaleTransient('en')
    }
  })
})
