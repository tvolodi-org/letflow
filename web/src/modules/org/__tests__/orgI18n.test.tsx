// @vitest-environment jsdom
/** I2 — GH 3609 / REQ-669: the screens render in the browser's language (ru, kk). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { fakeServer, renderOrg } from './orgTestKit'
import { orgMessages } from '../orgMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
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
  ['/admin/org/legal-entities', 'org.legal.title'],
  ['/admin/org/sites', 'org.sites.title'],
  ['/admin/org/units', 'org.units.title'],
]

describe('I2 locale', () => {
  for (const locale of ['ru', 'kk'] as const) {
    for (const [path, id] of SCREENS) {
      it(`${path} title is in ${locale}`, async () => {
        vi.stubGlobal('navigator', { ...navigator, languages: [locale], language: locale })
        renderOrg(path)
        const h1 = await screen.findByRole('heading', { level: 1 })
        expect(h1).toHaveTextContent(orgMessages[locale][id])
        expect(orgMessages[locale][id]).not.toBe(orgMessages.en[id])
      })
    }
  }
})
