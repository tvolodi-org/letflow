// @vitest-environment jsdom
/** E1 — GH 3767 / REQ-724: refusals and the empty, loading and error states of both screens. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { BAL, MOV, fakeMasters, problem, renderStock } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  fakeMasters(clientMock)
})
afterEach(() => cleanup())

const CASES: [number, string][] = [
  [422, 'The filters are not valid. Change them and try again.'],
  [404, 'This view is not available to you.'],
  [403, 'You are not permitted to read the stock register.'],
  [500, 'Something went wrong. Try again.'],
]

describe('E1 refusals', () => {
  for (const path of [BAL, MOV]) {
    for (const [status, text] of CASES) {
      it(`${path} ${status} shows its message`, async () => {
        clientMock.get.mockRejectedValue(problem(status))
        renderStock(path)
        expect(await screen.findByText(text)).toBeInTheDocument()
      })
    }

    it(`${path} error state offers a retry that reads again`, async () => {
      clientMock.get.mockRejectedValueOnce(problem(500)).mockResolvedValue({ next_cursor: null, rows: [] })
      renderStock(path)
      fireEvent.click(await screen.findByRole('button', { name: 'Retry' }))
      expect(await screen.findByTestId('datatable-empty-state')).toBeInTheDocument()
      expect(clientMock.get).toHaveBeenCalledTimes(2)
    })

    it(`${path} shows the empty state for no rows`, async () => {
      clientMock.get.mockResolvedValue({ next_cursor: null, rows: [] })
      renderStock(path)
      expect(await screen.findByTestId('datatable-empty-state')).toBeInTheDocument()
    })

    it(`${path} shows the loading state before the answer`, async () => {
      clientMock.get.mockReturnValue(new Promise(() => undefined))
      renderStock(path)
      await waitFor(() => expect(document.querySelector('.lf-skeleton, [aria-busy="true"]')).not.toBeNull())
    })
  }
})
