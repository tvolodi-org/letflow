// @vitest-environment jsdom
/** H1–H7 (stock) — T-1560: the static help pages: catalogue completeness, text quality, links, route, permission,
 *  and the counts correction (stock is not frozen during a count). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { helpIds } from '@/components/help/helpTopicText'
import { STOCK_UI_LOCALES, stockMessages } from '../stockMessages'
import { STOCK_HELP_TOPICS, stockHelpPath } from '../help/stockHelpTopics'
import { countsEn } from '../counts/countsMessages'
import { renderStock, withAtom, withoutAtom } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null, ledger_seq: 1 })
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

const helpKeys = (locale: 'en' | 'ru' | 'kk') => Object.keys(stockMessages[locale]).filter((k) => k.startsWith('stock.help.'))

describe('H1 H2 catalogue', () => {
  it('has every id of the fixed shape, non-empty, for every topic and locale, ru/kk differ from en', () => {
    for (const l of STOCK_UI_LOCALES) {
      for (const topic of STOCK_HELP_TOPICS) {
        for (const id of helpIds('stock', topic)) {
          expect(stockMessages[l][id], `${l} ${id}`).toBeTruthy()
          if (l !== 'en') expect(stockMessages[l][id], `${l} ${id}`).not.toBe(stockMessages.en[id])
        }
      }
      for (const id of ['link', 'back', 'h.purpose', 'h.tasks', 'h.refusals']) expect(stockMessages[l][`stock.help.${id}`], `${l} ${id}`).toBeTruthy()
    }
  })
  it('H2 the topic list equals the topics present in the catalogue', () => {
    const present = new Set(helpKeys('en').map((k) => k.split('.')[2]).filter((p) => p !== 'link' && p !== 'back' && p !== 'h'))
    expect([...present].sort()).toEqual([...STOCK_HELP_TOPICS].sort())
  })
})

describe('H3 text quality', () => {
  it('has no code-like words, no markup, short tasks and refusals', () => {
    for (const l of STOCK_UI_LOCALES) {
      for (const id of helpKeys(l)) {
        const text = stockMessages[l][id]
        expect(text, id).not.toMatch(/\b[a-z]+_[a-z_]+\b/)
        expect(text, id).not.toMatch(/undefined|!\[|<img/)
        if (/\.task\d$/.test(id)) expect(text.length, id).toBeLessThanOrEqual(160)
        if (/\.ref\d\./.test(id)) expect(text.length, id).toBeLessThanOrEqual(300)
      }
    }
  })
})

describe('H4 links', () => {
  it.each([
    ['/admin/stock/documents', 'documents'],
    ['/admin/stock/balances', 'balances'],
    ['/admin/stock/movements', 'movements'],
    ['/admin/stock/counts', 'counts'],
  ] as const)('%s shows a Help link to its topic', async (path, topic) => {
    renderStock(path, withAtom)
    const link = await screen.findByTestId('help-link')
    expect(link).toHaveAttribute('href', stockHelpPath(topic))
    expect(link).toHaveTextContent('Help')
  })
})

describe('H5 H6 route', () => {
  it.each([
    ['en', 'Help: stock counts', 'Three common tasks'],
    ['ru', 'Справка: инвентаризации', 'Три частые задачи'],
    ['kk', 'Анықтама: түгендеулер', 'Үш жиі міндет'],
  ] as const)('renders the counts topic in %s', (locale, title, tasks) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    const { container } = renderStock('/admin/stock/help/counts', withAtom)
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(title)
    expect(screen.getByRole('heading', { name: tasks })).toBeInTheDocument()
    expect(screen.getByTestId('help-tasks-list').children).toHaveLength(3)
    expect(screen.getByTestId('help-refusals-list').children).toHaveLength(3)
    expect(screen.getByTestId('help-back')).toHaveAttribute('href', '/admin/stock/counts')
    expect(container.querySelector('img')).toBeNull()
  })
  it('H6 an unknown topic is the not-found page', () => {
    renderStock('/admin/stock/help/nope', withAtom)
    expect(screen.getByTestId('not-found-page')).toBeInTheDocument()
  })
  it('H6 a user without StockRead does not get the help', () => {
    renderStock('/admin/stock/help/counts', withoutAtom)
    expect(screen.queryByTestId('help-topic')).toBeNull()
  })
})

describe('H7 counts accuracy', () => {
  it('says stock is not blocked during a count, and names the buttons as the screen does', () => {
    expect(stockMessages.en['stock.help.counts.ref1.body']).toContain(countsEn['counts.posting.noFreeze'].match(/Stock movements during counting are not blocked/)![0])
    for (const l of STOCK_UI_LOCALES) {
      const tasks = [1, 2, 3].map((n) => stockMessages[l][`stock.help.counts.task${n}`]).join(' ')
      expect(tasks, l).toContain(stockMessages[l]['counts.new'])
      expect(tasks, l).toContain(stockMessages[l]['counts.action.open'])
      expect(tasks, l).toContain(stockMessages[l]['counts.action.close'])
      expect(stockMessages[l]['stock.help.counts.ref1.title'], l).not.toMatch(/froz|заморож|мұздат/i)
    }
  })
})
