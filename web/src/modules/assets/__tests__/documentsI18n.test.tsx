// @vitest-environment jsdom
/** I1 — T-1334 / C14: the new ids exist in en, ru and kk, every enum word has a text, and the screens follow the
 *  language store. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { assetsMessages } from '../assetsMessages'
import { DOC_KINDS, DOC_STATES, REVERSE_REASONS, WRITEOFF_REASONS } from '../documents/documentsModel'
import { CAUSES, DOCUMENT_TYPES } from '../register/registerModel'
import { BAL, LIST, MOV, fakeMasters, renderAssets } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const keys = (l: 'en' | 'ru' | 'kk') => Object.keys(assetsMessages[l]).filter((k) => /^assets\.(doc|reg|balances|history|movements|journal|cause|docType)\./.test(k)).sort()

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

describe('I1 catalog', () => {
  it('has the same non-empty keys in en, ru and kk, and ru and kk differ from en', () => {
    expect(keys('en').length).toBeGreaterThan(150)
    expect(keys('ru')).toEqual(keys('en'))
    expect(keys('kk')).toEqual(keys('en'))
    for (const l of ['en', 'ru', 'kk'] as const) for (const k of keys(l)) expect(assetsMessages[l][k].trim(), `${l} ${k}`).not.toBe('')
    for (const k of keys('en')) {
      expect(assetsMessages.ru[k], `ru ${k}`).not.toBe(assetsMessages.en[k])
      expect(assetsMessages.kk[k], `kk ${k}`).not.toBe(assetsMessages.en[k])
    }
  })
  it('has a key for every kind, state, reason, cause and document type', () => {
    const need = [
      ...DOC_KINDS.map((k) => `assets.doc.kind.${k}`), ...DOC_STATES.map((s) => `assets.doc.state.${s}`),
      ...REVERSE_REASONS.map((r) => `assets.doc.reverseReason.${r}`), ...WRITEOFF_REASONS.map((r) => `assets.doc.writeoffReason.${r}`),
      ...CAUSES.map((c) => `assets.cause.${c}`), ...DOCUMENT_TYPES.map((d) => `assets.docType.${d}`),
      'assets.journal.status.posted', 'assets.journal.status.reversed', 'assets.journal.status.reversal',
      'assets.reg.error.invalid', 'assets.reg.error.notFound', 'assets.reg.error.forbidden', 'assets.reg.error.generic',
    ]
    for (const l of ['en', 'ru', 'kk'] as const) for (const k of need) expect(assetsMessages[l][k], `${l} ${k}`).toBeTruthy()
  })
})

describe('I1 screens follow the language', () => {
  it('the list, the balances and the movements switch to Russian and Kazakh', async () => {
    renderAssets(LIST)
    expect(await screen.findByText('No asset documents yet')).toBeInTheDocument()
    act(() => useUiLocaleStore.getState().setLocaleTransient('ru'))
    expect(await screen.findByText('Документов по активам пока нет')).toBeInTheDocument()
    cleanup()
    renderAssets(BAL)
    expect((await screen.findAllByText('Остатки активов')).length).toBeGreaterThan(0)
    cleanup()
    act(() => useUiLocaleStore.getState().setLocaleTransient('kk'))
    renderAssets(MOV)
    expect((await screen.findAllByText('Активтер қозғалысы')).length).toBeGreaterThan(0)
  })
})
