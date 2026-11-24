// @vitest-environment jsdom
/** T-2748 -- the public sign-up form: live slug check, error cases, no password unless the server asks. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, fireEvent, waitFor, act } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const api = vi.hoisted(() => ({ config: vi.fn(), slug: vi.fn(), submit: vi.fn() }))
vi.mock('@/api/signupApi', () => ({
  fetchSignupConfig: api.config,
  checkSlug: api.slug,
  submitSignup: api.submit,
}))

import SignupPage from '../SignupPage'

const CONFIG = { languages: ['en', 'ru', 'kk'], passwordRequired: false, slugSupported: true, hostnameDomain: 'demo.example.test' }

async function renderPage(config = CONFIG) {
  api.config.mockResolvedValue(config)
  render(
    <MemoryRouter>
      <SignupPage />
    </MemoryRouter>,
  )
  await screen.findByTestId('signup-form')
}

const input = (label: RegExp) => screen.getByLabelText(label) as HTMLInputElement

async function fillAll(slug = 'my-co') {
  fireEvent.change(input(/company name/i), { target: { value: 'My Co' } })
  fireEvent.change(input(/your name/i), { target: { value: 'Aigerim' } })
  fireEvent.change(input(/e-mail address/i), { target: { value: 'a@example.org' } })
  fireEvent.change(input(/workspace address/i), { target: { value: slug } })
  fireEvent.click(screen.getByTestId('signup-terms').querySelector('input') ?? screen.getByLabelText(/terms of use/i))
}

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  api.slug.mockResolvedValue('available')
  api.submit.mockResolvedValue({ kind: 'accepted' })
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.clearAllMocks()
})

async function settleSlug() {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(400)
  })
}

describe('SignupPage', () => {
  it('shows no password field while the server does not take one', async () => {
    await renderPage()
    expect(screen.queryByLabelText(/^password/i)).toBeNull()
  })

  it('shows a strength-checked password field when the server asks, and sends it only in the request', async () => {
    await renderPage({ ...CONFIG, passwordRequired: true })
    await fillAll()
    await settleSlug()
    fireEvent.change(input(/^password/i), { target: { value: 'short' } })
    fireEvent.submit(screen.getByTestId('signup-form'))
    expect(await screen.findByText(/password is too weak/i)).toBeInTheDocument()
    expect(api.submit).not.toHaveBeenCalled()

    fireEvent.change(input(/^password/i), { target: { value: 'correct-horse-9' } })
    fireEvent.submit(screen.getByTestId('signup-form'))
    await screen.findByTestId('signup-sent')
    expect(api.submit.mock.calls[0][0].password).toBe('correct-horse-9')
    expect(document.body.textContent).not.toContain('correct-horse-9')
  })

  it('checks the slug live: available, taken, invalid', async () => {
    await renderPage()
    fireEvent.change(input(/workspace address/i), { target: { value: 'free-one' } })
    await settleSlug()
    expect(await screen.findByText(/address is available/i)).toBeInTheDocument()
    expect(api.slug).toHaveBeenCalledWith('free-one')

    api.slug.mockResolvedValue('taken')
    fireEvent.change(input(/workspace address/i), { target: { value: 'busy-one' } })
    await settleSlug()
    expect(await screen.findByText(/already taken/i)).toBeInTheDocument()

    fireEvent.change(input(/workspace address/i), { target: { value: 'a' } })
    expect(await screen.findByText(/3 to 30 letters/i)).toBeInTheDocument()
  })

  it('suggests a slug from the company name until the visitor edits it', async () => {
    await renderPage()
    fireEvent.change(input(/company name/i), { target: { value: 'Zeta Trading' } })
    expect(input(/workspace address/i).value).toBe('zeta-trading')
    fireEvent.change(input(/workspace address/i), { target: { value: 'mine' } })
    fireEvent.change(input(/company name/i), { target: { value: 'Other Name' } })
    expect(input(/workspace address/i).value).toBe('mine')
  })

  it('requires every field and the terms before it calls the server', async () => {
    await renderPage()
    fireEvent.submit(screen.getByTestId('signup-form'))
    expect((await screen.findAllByText(/required/i)).length).toBeGreaterThanOrEqual(3)
    expect(api.submit).not.toHaveBeenCalled()
  })

  it('goes to check-your-mail on 202 and sends the language and slug', async () => {
    await renderPage()
    await fillAll()
    await settleSlug()
    fireEvent.submit(screen.getByTestId('signup-form'))
    await screen.findByTestId('signup-sent')
    expect(api.submit.mock.calls[0][0]).toMatchObject({ slug: 'my-co', language: 'en', termsAccepted: true })
  })

  const cases: Array<[string, { kind: string; retryAfterSeconds?: number | null }, RegExp]> = [
    ['slug_taken', { kind: 'slug_taken' }, /taken just now/i],
    ['email_not_accepted', { kind: 'email_not_accepted' }, /cannot be used to sign up/i],
    ['rate_limited', { kind: 'rate_limited', retryAfterSeconds: 3600 }, /too many attempts/i],
    ['unavailable', { kind: 'unavailable' }, /temporarily unavailable/i],
    ['network_error', { kind: 'network_error' }, /could not reach/i],
  ]
  for (const [name, outcome, text] of cases) {
    it(`shows a retryable error for ${name}`, async () => {
      await renderPage()
      await fillAll()
      await settleSlug()
      api.submit.mockResolvedValueOnce(outcome)
      fireEvent.submit(screen.getByTestId('signup-form'))
      expect(await screen.findByText(text)).toBeInTheDocument()
      expect(screen.getByTestId('signup-error')).toHaveAttribute('data-kind', name)
      fireEvent.click(screen.getByTestId('signup-retry'))
      expect(screen.queryByTestId('signup-error')).toBeNull()
      // the form is still filled in: the visitor can send again
      expect(input(/company name/i).value).toBe('My Co')
    })
  }

  it('says sign-up is not open when the config is unavailable', async () => {
    api.config.mockResolvedValue(null)
    render(
      <MemoryRouter>
        <SignupPage />
      </MemoryRouter>,
    )
    expect(await screen.findByText(/sign-up is not open/i)).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByTestId('signup-form')).toBeNull())
  })
})
