// @vitest-environment jsdom
/** I3 — GH 3607 / REQ-671: the screens render in the browser's language (ru, kk). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { fakeServer, renderLocations } from './locationsTestKit'
import { locationsMessages } from '../locationsMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-loc' }, isAuthenticated: true }),
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

const SCREENS: [string, string][] = [
  ['/admin/locations', 'locations.tree.title'],
  ['/admin/locations/links', 'locations.links.title'],
]

describe('I3 locale', () => {
  for (const locale of ['ru', 'kk'] as const) {
    for (const [path, id] of SCREENS) {
      it(`${path} title is in ${locale}`, async () => {
        vi.stubGlobal('navigator', { ...navigator, languages: [locale], language: locale })
        renderLocations(path)
        const h1 = await screen.findByRole('heading', { level: 1 })
        expect(h1).toHaveTextContent(locationsMessages[locale][id])
        expect(locationsMessages[locale][id]).not.toBe(locationsMessages.en[id])
      })
    }
  }
})
