// @vitest-environment jsdom
/** T-1487 first-use guidance: no asset cards (line picker) and the empty documents registry, en/ru/kk. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor, within } from '@testing-library/react'
import { LIST, MASTERS, fakeMasters, renderAssets, withPost, withRead } from './registerTestKit'
import { documentsEn as en, documentsRu as ru, documentsKk as kk } from '../documents/documentsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`
const noCards = { ...MASTERS, assets_card: [] }
const cardsAccess = { status: 'ready' as const, info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost', 'AssetsCardWrite'] } }

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
})
afterEach(() => cleanup())

describe('T1-T4 line picker', () => {
  it('T1 no cards: notice and link', async () => {
    fakeMasters(clientMock, noCards)
    renderAssets(NEW + '?kind=commission', cardsAccess)
    const box = await screen.findByTestId('no-cards')
    expect(box).toHaveTextContent(en['assets.doc.noCards.text'])
    const link = within(box).getByRole('link', { name: 'Create an asset card first' })
    expect(link).toHaveAttribute('href', '/admin/assets/cards')
  })
  it('T2 with a card: no notice', async () => {
    fakeMasters(clientMock)
    renderAssets(NEW + '?kind=commission', cardsAccess)
    await screen.findByTestId('lines-card')
    await waitFor(() => expect(clientMock.post).toHaveBeenCalled())
    await new Promise((r) => setTimeout(r, 50))
    expect(screen.queryByTestId('no-cards')).toBeNull()
  })
  it('T3 loading and error: no notice', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => {}))
    renderAssets(NEW + '?kind=commission', cardsAccess)
    await screen.findByTestId('lines-card')
    expect(screen.queryByTestId('no-cards')).toBeNull()
    cleanup()
    clientMock.post.mockRejectedValue(new Error('boom'))
    renderAssets(NEW + '?kind=commission', cardsAccess)
    await screen.findByTestId('lines-card')
    await new Promise((r) => setTimeout(r, 50))
    expect(screen.queryByTestId('no-cards')).toBeNull()
  })
  it('T4 without AssetsCardWrite: text, no link', async () => {
    fakeMasters(clientMock, noCards)
    renderAssets(NEW + '?kind=commission', withPost)
    const box = await screen.findByTestId('no-cards')
    expect(box).toHaveTextContent(en['assets.doc.noCards.askAdmin'])
    expect(within(box).queryByRole('link')).toBeNull()
  })
})

describe('T5-T6 registry', () => {
  it('T5 empty, no filters: order text and link', async () => {
    fakeMasters(clientMock)
    renderAssets(LIST, { ...cardsAccess })
    expect(await screen.findByTestId('empty-first')).toHaveTextContent(en['assets.doc.emptyFirst'])
    expect(screen.getByRole('link', { name: 'Create an asset card first' })).toHaveAttribute('href', '/admin/assets/cards')
  })
  it('T5b no link without AssetsCardWrite', async () => {
    fakeMasters(clientMock)
    renderAssets(LIST, withRead)
    await screen.findByTestId('empty-first')
    expect(screen.queryByRole('link', { name: 'Create an asset card first' })).toBeNull()
  })
  it('T6 old text when a filter is set (covered by the existing DocumentsPage empty test)', () => {
    expect(en['assets.doc.emptyText']).toContain('No document matches')
  })
})

describe('T7 ru and kk', () => {
  it('has the five new ids, translated', () => {
    for (const id of ['assets.doc.emptyFirst', 'assets.doc.noCards.title', 'assets.doc.noCards.text', 'assets.doc.noCards.link', 'assets.doc.noCards.askAdmin']) {
      expect(ru[id]).toBeTruthy()
      expect(kk[id]).toBeTruthy()
      expect(ru[id]).not.toBe(en[id])
      expect(kk[id]).not.toBe(en[id])
    }
  })
})
