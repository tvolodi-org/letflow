// @vitest-environment jsdom
/** E1 — GH 3606 / REQ-672: every refusal of the write routes shows its own translated message. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen } from '@testing-library/react'
import { fakeServer, problem, rec, renderCodes } from './codesTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-codes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

afterEach(() => cleanup())
beforeEach(() => {
  clientMock.post.mockReset()
})

const CASES: [number, Record<string, unknown>, string][] = [
  [422, { reason: 'code_assigned' }, 'The code is already assigned. Release it first.'],
  [422, { reason: 'code_retired' }, 'The code is retired and cannot be changed.'],
  [422, { reason: 'code_not_assigned' }, 'The code is not assigned.'],
  [422, { reason: 'target_type_not_allowed' }, 'This kind of target is not allowed.'],
  [422, { reason: 'target_inactive' }, 'The target is retired and cannot receive a code.'],
  [422, { reason: 'value_taken' }, 'This value is already taken by another code.'],
  [422, { reason: 'value_invalid' }, 'The value is not valid.'],
  [422, { reason: 'batch_size' }, 'A batch holds at most 1000 codes.'],
  [404, {}, 'The code or the target no longer exists. The list was reloaded.'],
  [403, {}, 'You are not permitted to do this.'],
]

describe('E1 error messages', () => {
  for (const [status, body, text] of CASES) {
    it(`${status} ${String(body['reason'] ?? '')} shows its message`, async () => {
      fakeServer(
        clientMock,
        { code_tag: [rec('c1', 'code_tag', { value: 'FREE-1', kind: 'qr', status: 'not_assigned' })] },
        () => {
          throw problem(status, body)
        },
      )
      renderCodes('/admin/codes')
      fireEvent.click((await screen.findByText('FREE-1')).closest('tr')!)
      fireEvent.change(await screen.findByLabelText('New value'), { target: { value: 'X' } })
      fireEvent.click(screen.getByTestId('value-confirm'))
      expect(await screen.findByText(text)).toBeInTheDocument()
    })
  }
})
