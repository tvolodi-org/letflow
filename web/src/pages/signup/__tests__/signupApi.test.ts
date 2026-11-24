// @vitest-environment jsdom
/** T-2748 -- signupApi: closed outcomes, never throws, never leaks server text or the password. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { checkSlug, fetchSignupStatus, submitSignup } from '@/api/signupApi'
import { isSlugShape, isStrongPassword, suggestSlug } from '../signupModel'

function stub(status: number, body: unknown, headers: Record<string, string> = {}) {
  const fn = vi.fn(async () => new Response(JSON.stringify(body), { status, headers }))
  vi.stubGlobal('fetch', fn)
  window.fetch = fn as unknown as typeof window.fetch
  return fn
}
afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

const input = {
  companyName: 'Co',
  userName: 'U',
  email: 'a@example.org',
  language: 'en',
  slug: 'my-co',
  termsAccepted: true,
}

describe('signupApi', () => {
  it('maps every submit answer to a closed outcome', async () => {
    stub(202, { status: 'check_your_mail' })
    expect(await submitSignup(input)).toEqual({ kind: 'accepted' })
    stub(422, { error: 'slug_taken', message: 'server text' })
    expect(await submitSignup(input)).toEqual({ kind: 'slug_taken' })
    stub(422, { error: 'email_not_accepted' })
    expect(await submitSignup(input)).toEqual({ kind: 'email_not_accepted' })
    stub(422, { error: 'invalid_request', fields: ['slug', 5] })
    expect(await submitSignup(input)).toEqual({ kind: 'invalid', fields: ['slug'] })
    stub(429, { error: 'rate_limited' }, { 'retry-after': '3600' })
    expect(await submitSignup(input)).toEqual({ kind: 'rate_limited', retryAfterSeconds: 3600 })
    stub(503, { error: 'signup_unavailable' })
    expect(await submitSignup(input)).toEqual({ kind: 'unavailable' })
    window.fetch = vi.fn().mockRejectedValue(new Error('down')) as unknown as typeof window.fetch
    expect(await submitSignup(input)).toEqual({ kind: 'network_error' })
  })

  it('sends the password only when given and never as part of a returned outcome', async () => {
    const fn = stub(202, {})
    await submitSignup(input)
    expect(JSON.parse((fn.mock.calls[0] as unknown as [string, RequestInit])[1].body as string)).not.toHaveProperty('password')
    await submitSignup({ ...input, password: 'correct-horse-9' })
    const body = JSON.parse((fn.mock.calls[1] as unknown as [string, RequestInit])[1].body as string)
    expect(body.password).toBe('correct-horse-9')
    expect(JSON.stringify(await submitSignup({ ...input, password: 'correct-horse-9' }))).not.toContain('correct-horse')
  })

  it('checkSlug returns the status or null, never throws', async () => {
    stub(200, { status: 'taken' })
    expect(await checkSlug('x-y')).toBe('taken')
    stub(200, { status: 'weird' })
    expect(await checkSlug('x-y')).toBeNull()
    stub(429, {})
    expect(await checkSlug('x-y')).toBeNull()
  })

  it('fetchSignupStatus refuses a ready answer with an unsafe host or realm', async () => {
    stub(200, { state: 'ready', host: 'evil.com/path?x', realm: 't-1' })
    expect(await fetchSignupStatus('t')).toEqual({ kind: 'network_error' })
    stub(200, { state: 'failed', reason: 'made-up' })
    expect(await fetchSignupStatus('t')).toEqual({ kind: 'failed', reason: 'internal' })
    stub(400, { error: 'invalid_or_expired_link' })
    expect(await fetchSignupStatus('t')).toEqual({ kind: 'invalid_link' })
  })

  it('model rules', () => {
    expect(isSlugShape('my-co')).toBe(true)
    for (const bad of ['ab', '-ab', 'ab-', 'a--b', 'Abc', 't-abc', 'a'.repeat(31)]) expect(isSlugShape(bad)).toBe(false)
    expect(isStrongPassword('correct-horse-9')).toBe(true)
    expect(isStrongPassword('short1')).toBe(false)
    expect(isStrongPassword('onlyletterslong')).toBe(false)
    expect(suggestSlug('Acme  Trading, Ltd.')).toBe('acme-trading-ltd')
  })
})
