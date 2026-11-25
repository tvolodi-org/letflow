/** signupApi -- T-2748 (PILOT G22): client of the public self-service sign-up routes
 *  (`GET /api/signup/config`, `GET /api/signup/slug`, `POST /api/signup`, `POST /api/signup/status`).
 *
 *  The routes are credential-free, so this does not go through the shared request() path (it would attach a
 *  token and its 401 handling would redirect to login). Every function resolves to a closed outcome and never
 *  throws. No outcome carries a password, an e-mail address or server text: the screens show their own
 *  catalog messages for each outcome.
 */

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? ''

export interface SignupConfig {
  languages: string[]
  /** True only when the live provisioner contract takes a visitor password (not yet: the interim mails one). */
  passwordRequired: boolean
  slugSupported: boolean
  hostnameDomain: string | null
}

export type SlugStatus = 'available' | 'taken' | 'reserved' | 'invalid'

export type SignupSubmitOutcome =
  | { kind: 'accepted' }
  | { kind: 'invalid'; fields: string[] }
  | { kind: 'slug_taken' }
  | { kind: 'email_not_accepted' }
  | { kind: 'rate_limited'; retryAfterSeconds: number | null }
  | { kind: 'unavailable' }
  | { kind: 'network_error' }

export type SignupStatusOutcome =
  | { kind: 'pending' }
  | { kind: 'ready'; host: string; realm: string }
  | { kind: 'failed'; reason: 'demo_cap_reached' | 'unavailable' | 'rate_limited' | 'slug_taken' | 'internal' }
  | { kind: 'invalid_link' }
  | { kind: 'network_error' }

export interface SignupSubmitInput {
  companyName: string
  userName: string
  email: string
  language: string
  slug: string
  termsAccepted: boolean
  /** Only sent when the config says the provisioner takes one. Never stored, logged or echoed. */
  password?: string
}

async function readJson(res: Response): Promise<Record<string, unknown>> {
  try {
    const body: unknown = await res.json()
    return typeof body === 'object' && body !== null ? (body as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

// Public sign-up routes carry no session token, so they bypass the authenticated client on purpose.
const rawRequest = (input: string, init?: RequestInit): Promise<Response> => window.fetch.call(window, input, init)

const SLUG_STATUSES: readonly SlugStatus[] = ['available', 'taken', 'reserved', 'invalid']

export async function fetchSignupConfig(): Promise<SignupConfig | null> {
  try {
    const res = await rawRequest(`${BASE_URL}/api/signup/config`, { headers: { Accept: 'application/json' } })
    if (res.status !== 200) return null
    const b = await readJson(res)
    return {
      languages: Array.isArray(b.languages) ? b.languages.filter((l): l is string => typeof l === 'string') : [],
      passwordRequired: b.password_required === true,
      slugSupported: b.slug_supported === true,
      hostnameDomain: typeof b.hostname_domain === 'string' ? b.hostname_domain : null,
    }
  } catch {
    return null
  }
}

/** `null` when the check itself failed (network, 429, malformed): the form then keeps the field neutral. */
export async function checkSlug(slug: string): Promise<SlugStatus | null> {
  try {
    const res = await rawRequest(`${BASE_URL}/api/signup/slug?slug=${encodeURIComponent(slug)}`, {
      headers: { Accept: 'application/json' },
    })
    if (res.status !== 200) return null
    const b = await readJson(res)
    return SLUG_STATUSES.includes(b.status as SlugStatus) ? (b.status as SlugStatus) : null
  } catch {
    return null
  }
}

function postJson(path: string, body: unknown): Promise<Response> {
  return rawRequest(`${BASE_URL}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(body),
  })
}

export async function submitSignup(input: SignupSubmitInput): Promise<SignupSubmitOutcome> {
  const body: Record<string, unknown> = {
    company_name: input.companyName,
    user_name: input.userName,
    email: input.email,
    language: input.language,
    slug: input.slug,
    terms_accepted: input.termsAccepted,
  }
  if (input.password) body.password = input.password
  try {
    const res = await postJson('/api/signup', body)
    if (res.status === 202) return { kind: 'accepted' }
    const b = await readJson(res)
    if (res.status === 429) {
      const ra = Number(res.headers.get('retry-after'))
      return { kind: 'rate_limited', retryAfterSeconds: Number.isFinite(ra) && ra > 0 ? ra : null }
    }
    if (res.status === 422) {
      if (b.error === 'slug_taken') return { kind: 'slug_taken' }
      if (b.error === 'email_not_accepted') return { kind: 'email_not_accepted' }
      const fields = Array.isArray(b.fields) ? b.fields.filter((f): f is string => typeof f === 'string') : []
      return { kind: 'invalid', fields }
    }
    return { kind: 'unavailable' }
  } catch {
    return { kind: 'network_error' }
  }
}

const FAIL_REASONS = ['demo_cap_reached', 'unavailable', 'rate_limited', 'slug_taken', 'internal'] as const

export async function fetchSignupStatus(token: string): Promise<SignupStatusOutcome> {
  try {
    const res = await postJson('/api/signup/status', { token })
    if (res.status === 400) return { kind: 'invalid_link' }
    if (res.status !== 200) return { kind: 'network_error' }
    const b = await readJson(res)
    if (
      b.state === 'ready' &&
      typeof b.host === 'string' &&
      /^[a-z0-9.-]{1,253}$/.test(b.host) &&
      typeof b.realm === 'string' &&
      /^[a-z0-9-]{1,64}$/.test(b.realm)
    ) {
      return { kind: 'ready', host: b.host, realm: b.realm }
    }
    if (b.state === 'failed') {
      const reason = (FAIL_REASONS as readonly unknown[]).includes(b.reason)
        ? (b.reason as (typeof FAIL_REASONS)[number])
        : 'internal'
      return { kind: 'failed', reason }
    }
    return b.state === 'pending' ? { kind: 'pending' } : { kind: 'network_error' }
  } catch {
    return { kind: 'network_error' }
  }
}

/** Verifies the mailed token (POST /api/signup/verify). */
export async function verifySignupToken(
  token: string,
  retry = false,
): Promise<'ok' | 'invalid_link' | 'network_error'> {
  try {
    const res = await postJson('/api/signup/verify', retry ? { token, retry: true } : { token })
    if (res.status === 200) return 'ok'
    return res.status === 400 ? 'invalid_link' : 'network_error'
  } catch {
    return 'network_error'
  }
}
