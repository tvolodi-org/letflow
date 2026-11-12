// @vitest-environment jsdom
/** T-1804 P6/P7 — the assets document form says so when a picker list was cut at the cap, and stays quiet otherwise. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { LIST, fakeMasters, renderAssets, withPost } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets-trunc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  fakeMasters(clientMock)
})
afterEach(() => cleanup())

describe('picker truncated notice', () => {
  it('shows the notice when a picker list reaches the cap', async () => {
    const masters = clientMock.post.getMockImplementation()!
    let n = 0
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      const res = (await masters(p, b)) as { items: unknown[]; next_cursor: string | null }
      return b['entity_type'] === 'org_unit' ? { ...res, next_cursor: `more${(n += 1)}` } : res
    })
    renderAssets(NEW, withPost)
    expect((await screen.findAllByTestId('list-truncated'))[0]).toHaveTextContent(/only the first 10000 records/)
  })

  it('shows no notice when every list is complete', async () => {
    renderAssets(NEW, withPost)
    await screen.findByTestId('document-form')
    await screen.findAllByRole('option', { name: /./ })
    expect(screen.queryByTestId('list-truncated')).not.toBeInTheDocument()
  })
})
