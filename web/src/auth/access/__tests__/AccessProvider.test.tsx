// @vitest-environment jsdom
/**
 * AccessProvider / useAccess / RequirePermission — REQ-450 slice 1.
 * /me/access is mocked from the fixtures; the auth session is a mutable stub.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useState } from 'react'
import type { AccessInfo } from '../types'
import { ACCESS_FIXTURES } from '../fixtures'
import { P } from '../types'
expect.extend(jestDomMatchers)

const { mockGetAccess, auth } = vi.hoisted(() => ({
  mockGetAccess: vi.fn(),
  auth: { session: null as { token: string; tenant_slug: string | null } | null },
}))

vi.mock('@/api/me', () => ({ meApi: { getAccess: mockGetAccess } }))
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: auth.session }) }))

import { AccessProvider } from '../AccessProvider'
import { RequirePermission } from '../RequirePermission'
import { useAccess } from '../useAccess'

function jwt(sub: string): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, '')
  return `${b64({ alg: 'none' })}.${b64({ sub, roles: ['claimed'] })}.sig`
}

function deferred<T>() {
  let resolve!: (v: T) => void
  const promise = new Promise<T>(res => {
    resolve = res
  })
  return { promise, resolve }
}

function Probe() {
  const a = useAccess()
  return (
    <div>
      <span data-testid="status">{a.state.status}</span>
      <span data-testid="can-dlq">{String(a.can(P.DlqOperate))}</span>
      <span data-testid="platform">{String(a.isPlatformTenant)}</span>
    </div>
  )
}

function PageBody() {
  const [text, setText] = useState('')
  return <input data-testid="page-body" value={text} onChange={e => setText(e.target.value)} />
}

function Tree() {
  return (
    <MemoryRouter>
      <AccessProvider>
        <Probe />
        <RequirePermission permission={P.DlqOperate}>
          <PageBody />
        </RequirePermission>
      </AccessProvider>
    </MemoryRouter>
  )
}

beforeEach(() => {
  auth.session = { token: jwt('u1'), tenant_slug: 'fixture-co' }
})

afterEach(() => {
  cleanup()
  vi.resetAllMocks()
})

describe('AccessProvider', () => {
  it('goes loading -> ready and renders the guarded page only when the permission is granted', async () => {
    const d = deferred<AccessInfo>()
    mockGetAccess.mockReturnValue(d.promise)
    render(<Tree />)

    // while /me/access is loading no ungated UI renders
    expect(screen.getByTestId('status')).toHaveTextContent('loading')
    expect(screen.getByTestId('can-dlq')).toHaveTextContent('false')
    expect(screen.getByTestId('access-loading')).toBeInTheDocument()
    expect(screen.queryByTestId('page-body')).not.toBeInTheDocument()

    await act(async () => d.resolve(ACCESS_FIXTURES.operator))
    expect(screen.getByTestId('status')).toHaveTextContent('ready')
    expect(screen.getByTestId('page-body')).toBeInTheDocument()
  })

  it('a ready state without the permission shows PermissionDenied, not the page', async () => {
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.designer)
    render(<Tree />)
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('ready'))
    expect(screen.queryByTestId('page-body')).not.toBeInTheDocument()
    expect(screen.getByText(/do not have access to this area/i)).toBeInTheDocument()
  })

  it('a failed /me/access renders no gated UI and offers Retry; Retry reaches ready', async () => {
    mockGetAccess.mockRejectedValueOnce({ status: 500 }).mockResolvedValue(ACCESS_FIXTURES.operator)
    render(<Tree />)

    // while /me/access has failed no ungated UI renders
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('error'))
    expect(screen.getByTestId('can-dlq')).toHaveTextContent('false')
    expect(screen.getByTestId('access-error')).toBeInTheDocument()
    expect(screen.queryByTestId('page-body')).not.toBeInTheDocument()

    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('ready'))
    expect(screen.getByTestId('page-body')).toBeInTheDocument()
  })

  it('a silent renew (same identity, new token) keeps ready and keeps the page body mounted', async () => {
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.operator)
    const { rerender } = render(<Tree />)
    await waitFor(() => expect(screen.getByTestId('page-body')).toBeInTheDocument())
    await userEvent.type(screen.getByTestId('page-body'), 'draft')
    const node = screen.getByTestId('page-body')

    const second = deferred<AccessInfo>()
    mockGetAccess.mockReturnValue(second.promise)
    auth.session = { token: jwt('u1') + 'renewed', tenant_slug: 'fixture-co' }
    rerender(<Tree />)

    expect(screen.getByTestId('status')).toHaveTextContent('ready')
    expect(screen.getByTestId('page-body')).toBe(node)
    expect(screen.getByTestId('page-body')).toHaveValue('draft')
    expect(mockGetAccess).toHaveBeenCalledTimes(2)
    await act(async () => second.resolve(ACCESS_FIXTURES.operator))
    expect(screen.getByTestId('page-body')).toBe(node)
  })

  it('a failed background refetch after a renewal keeps the ready state', async () => {
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.operator)
    const { rerender } = render(<Tree />)
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('ready'))

    mockGetAccess.mockRejectedValue({ status: 500 })
    auth.session = { token: jwt('u1') + 'renewed', tenant_slug: 'fixture-co' }
    rerender(<Tree />)
    await waitFor(() => expect(mockGetAccess).toHaveBeenCalledTimes(2))
    await act(async () => {})

    expect(screen.getByTestId('status')).toHaveTextContent('ready')
    expect(screen.getByTestId('page-body')).toBeInTheDocument()
  })

  it("a tenant change resets to loading in the same render and ignores the old identity's late response", async () => {
    const first = deferred<AccessInfo>()
    mockGetAccess.mockReturnValueOnce(first.promise)
    const { rerender } = render(<Tree />)

    const second = deferred<AccessInfo>()
    mockGetAccess.mockReturnValueOnce(second.promise)
    auth.session = { token: jwt('u1'), tenant_slug: 'other-co' }
    rerender(<Tree />)

    // the old tenant's (platform) grants arrive late: they must not be applied
    await act(async () => first.resolve(ACCESS_FIXTURES.platformAdmin))
    expect(screen.getByTestId('status')).toHaveTextContent('loading')
    expect(screen.getByTestId('platform')).toHaveTextContent('false')

    await act(async () => second.resolve(ACCESS_FIXTURES.designer))
    expect(screen.getByTestId('status')).toHaveTextContent('ready')
    expect(screen.getByTestId('platform')).toHaveTextContent('false')
  })

  it("a ready tenant that switches shows loading, never the previous tenant's grants", async () => {
    mockGetAccess.mockResolvedValueOnce(ACCESS_FIXTURES.platformAdmin)
    const { rerender } = render(<Tree />)
    await waitFor(() => expect(screen.getByTestId('platform')).toHaveTextContent('true'))

    mockGetAccess.mockReturnValueOnce(new Promise(() => {}))
    auth.session = { token: jwt('u1'), tenant_slug: 'other-co' }
    rerender(<Tree />)

    expect(screen.getByTestId('status')).toHaveTextContent('loading')
    expect(screen.getByTestId('platform')).toHaveTextContent('false')
    expect(screen.queryByTestId('page-body')).not.toBeInTheDocument()
  })

  it('without a session the state is loading and no request is made', () => {
    auth.session = null
    render(<Tree />)
    expect(screen.getByTestId('status')).toHaveTextContent('loading')
    expect(mockGetAccess).not.toHaveBeenCalled()
  })
})
