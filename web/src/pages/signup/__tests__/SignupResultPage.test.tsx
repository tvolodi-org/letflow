// @vitest-environment jsdom
/** T-2748 -- the result page: verify once, poll, then the tenant URL and a sign-in link, or a named failure. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, fireEvent, act } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const api = vi.hoisted(() => ({ verify: vi.fn(), status: vi.fn() }))
vi.mock('@/api/signupApi', () => ({ verifySignupToken: api.verify, fetchSignupStatus: api.status }))

import SignupResultPage, { STATUS_INTERVAL_MS } from '../SignupResultPage'

function renderAt(url: string) {
  render(
    <MemoryRouter initialEntries={[url]}>
      <SignupResultPage />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  api.verify.mockResolvedValue('ok')
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.clearAllMocks()
})

describe('SignupResultPage', () => {
  it('shows the tenant URL and a sign-in link when the tenant is ready, after one pending poll', async () => {
    api.status
      .mockResolvedValueOnce({ kind: 'pending' })
      .mockResolvedValue({ kind: 'ready', host: 'my-co.demo.example.test', realm: 't-abc123' })
    renderAt('/signup/verify?token=tok-tok-tok-tok-tok-tok')
    expect(await screen.findByText(/creating your workspace/i)).toBeInTheDocument()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(STATUS_INTERVAL_MS + 50)
    })
    const url = await screen.findByTestId('signup-tenant-url')
    expect(url).toHaveAttribute('href', 'https://my-co.demo.example.test/')
    expect(screen.getByTestId('signup-signin-link')).toHaveAttribute(
      'href',
      'https://my-co.demo.example.test/?realm=t-abc123',
    )
    expect(api.verify).toHaveBeenCalledTimes(1)
    expect(api.verify).toHaveBeenCalledWith('tok-tok-tok-tok-tok-tok')
  })

  const reasons = [
    ['demo_cap_reached', /demo places are taken/i],
    ['unavailable', /temporarily unavailable/i],
    ['rate_limited', /service is busy/i],
    ['slug_taken', /taken by someone else/i],
  ] as const
  for (const [reason, text] of reasons) {
    it(`names the failure ${reason} and offers a retry`, async () => {
      api.status.mockResolvedValue({ kind: 'failed', reason })
      renderAt('/signup/verify?token=tok-tok-tok-tok-tok-tok')
      expect(await screen.findByText(text)).toBeInTheDocument()
      expect(screen.getByTestId('signup-result-error')).toHaveAttribute('data-reason', reason)
      api.status.mockResolvedValue({ kind: 'ready', host: 'x-co.demo.example.test', realm: 't-1' })
      fireEvent.click(screen.getByTestId('signup-result-retry'))
      expect(await screen.findByTestId('signup-tenant-url')).toBeInTheDocument()
    })
  }

  it('an invalid or missing token is one generic message with a way to start again', async () => {
    api.verify.mockResolvedValue('invalid_link')
    renderAt('/signup/verify?token=bad')
    expect(await screen.findByText(/not valid or has expired/i)).toBeInTheDocument()
    expect(screen.getByTestId('signup-again')).toHaveAttribute('href', '/signup')
    cleanup()
    renderAt('/signup/verify')
    expect(await screen.findByText(/not valid or has expired/i)).toBeInTheDocument()
    expect(api.status).not.toHaveBeenCalled()
  })

  it('a network failure is retryable', async () => {
    api.verify.mockResolvedValue('network_error')
    renderAt('/signup/verify?token=tok-tok-tok-tok-tok-tok')
    expect(await screen.findByText(/could not reach/i)).toBeInTheDocument()
  })
})
