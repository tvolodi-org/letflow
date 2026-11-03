// @vitest-environment jsdom
/** I3 (AC5) — GH 3605 / REQ-673: the screen renders in the browser's language (ru, kk). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { fakeServer, renderLots } from './catalogItemsTestKit'
import { catalogItemsMessages } from '../catalogItemsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-ci-i18n' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  clientMock.post.mockReset()
  fakeServer(clientMock, {})
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

const SCREENS: [string, string][] = [['/admin/catalog/lots', 'catalog_items.title']]

describe('I3 locale', () => {
  for (const locale of ['ru', 'kk'] as const) {
    for (const [path, id] of SCREENS) {
      it(`${path} title is in ${locale}`, async () => {
        vi.stubGlobal('navigator', { ...navigator, languages: [locale], language: locale })
        renderLots(path)
        const h1 = await screen.findByRole('heading', { level: 1 })
        expect(h1).toHaveTextContent(catalogItemsMessages[locale][id])
        expect(catalogItemsMessages[locale][id]).not.toBe(catalogItemsMessages.en[id])
      })
    }
  }
})
