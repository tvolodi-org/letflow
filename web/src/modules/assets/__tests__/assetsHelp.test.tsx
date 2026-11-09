// @vitest-environment jsdom
/** H1–H7 (assets) — T-1560: the static help pages: catalogue completeness, text quality, links, route, permission. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { helpIds } from '@/components/help/helpTopicText'
import { ASSETS_UI_LOCALES, assetsMessages } from '../assetsMessages'
import { ASSETS_HELP_TOPICS, assetsHelpPath } from '../help/assetsHelpTopics'
import type { AccessState } from '@/auth/access/types'
import { renderAssets, withoutAtom } from './assetsTestKit'

const ALL: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsCardWrite', 'AssetsPost'] } }
const READ: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['AssetsRead'] } }

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

const helpKeys = (locale: 'en' | 'ru' | 'kk') => Object.keys(assetsMessages[locale]).filter((k) => k.startsWith('assets.help.'))

describe('H1 H2 catalogue', () => {
  it('has every id of the fixed shape, non-empty, for every topic and locale, ru/kk differ from en', () => {
    for (const l of ASSETS_UI_LOCALES) {
      for (const topic of ASSETS_HELP_TOPICS) {
        for (const id of helpIds('assets', topic)) {
          expect(assetsMessages[l][id], `${l} ${id}`).toBeTruthy()
          if (l !== 'en') expect(assetsMessages[l][id], `${l} ${id}`).not.toBe(assetsMessages.en[id])
        }
      }
      for (const id of ['link', 'back', 'h.purpose', 'h.tasks', 'h.refusals']) expect(assetsMessages[l][`assets.help.${id}`], `${l} ${id}`).toBeTruthy()
    }
  })
  it('H2 the topic list equals the topics present in the catalogue', () => {
    const present = new Set(helpKeys('en').map((k) => k.split('.')[2]).filter((p) => p !== 'link' && p !== 'back' && p !== 'h'))
    expect([...present].sort()).toEqual([...ASSETS_HELP_TOPICS].sort())
  })
})

describe('H3 text quality', () => {
  it('has no code-like words, no markup, short tasks and refusals', () => {
    for (const l of ASSETS_UI_LOCALES) {
      for (const id of helpKeys(l)) {
        const text = assetsMessages[l][id]
        expect(text, id).not.toMatch(/\b[a-z]+_[a-z_]+\b/)
        expect(text, id).not.toMatch(/undefined|!\[|<img/)
        if (/\.task\d$/.test(id)) expect(text.length, id).toBeLessThanOrEqual(160)
        if (/\.ref\d\./.test(id)) expect(text.length, id).toBeLessThanOrEqual(300)
      }
    }
  })
})

describe('H4 links', () => {
  const SCREENS: [string, string][] = [
    ['/admin/assets/cards', 'cards'],
    ['/admin/assets/documents', 'documents'],
    ['/admin/assets/balances', 'balances'],
    ['/admin/assets/movements', 'movements'],
  ]
  it.each(SCREENS)('%s shows a Help link to its topic', async (path, topic) => {
    renderAssets(path, ALL)
    const link = await screen.findByTestId('help-link')
    expect(link).toHaveAttribute('href', assetsHelpPath(topic as never))
    expect(link).toHaveTextContent('Help')
  })
})

describe('H5 H6 route', () => {
  it.each([
    ['en', 'Help: asset documents', 'Three common tasks'],
    ['ru', 'Справка: документы по активам', 'Три частые задачи'],
    ['kk', 'Анықтама: актив құжаттары', 'Үш жиі міндет'],
  ] as const)('renders the documents topic in %s', (locale, title, tasks) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    const { container } = renderAssets('/admin/assets/help/documents', READ)
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(title)
    expect(screen.getByRole('heading', { name: tasks })).toBeInTheDocument()
    expect(screen.getByTestId('help-purpose-text').textContent).toBeTruthy()
    expect(screen.getByTestId('help-tasks-list').children).toHaveLength(3)
    expect(screen.getByTestId('help-refusals-list').children).toHaveLength(3)
    expect(screen.getByTestId('help-back')).toHaveAttribute('href', '/admin/assets/documents')
    expect(container.querySelector('img')).toBeNull()
  })
  it('H6 an unknown topic is the not-found page', () => {
    renderAssets('/admin/assets/help/nope', ALL)
    expect(screen.getByTestId('not-found-page')).toBeInTheDocument()
  })
  it('H6 a user without the screen permission does not get the help', () => {
    renderAssets('/admin/assets/help/documents', withoutAtom)
    expect(screen.queryByTestId('help-topic')).toBeNull()
  })
  it('H6 the cards help needs the card-write permission like the cards screen', () => {
    renderAssets('/admin/assets/help/cards', READ)
    expect(screen.queryByTestId('help-topic')).toBeNull()
  })
})
