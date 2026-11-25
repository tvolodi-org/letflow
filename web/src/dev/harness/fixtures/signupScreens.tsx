/** Harness fixtures of T-2748 (PILOT G22): the public sign-up form and the result page in each state.
 *  The fetch fixture answers the public routes (`/api/signup/*`); `state=error` makes the config route fail, so the
 *  form shows "sign-up is not open". */
import SignupPage from '@/pages/signup/SignupPage'
import SignupResultPage from '@/pages/signup/SignupResultPage'
import type { FixtureRoute, HarnessScreen } from '../types'

const config = (passwordRequired: boolean): FixtureRoute => ({
  match: (path, method) => path === '/api/signup/config' && method === 'GET',
  reply: state =>
    state === 'error'
      ? { status: 404, body: { error: 'not_found' } }
      : {
          status: 200,
          body: { enabled: true, languages: ['en', 'ru', 'kk'], password_required: passwordRequired, slug_supported: true, hostname_domain: 'demo.example.test' },
        },
})

const slugAnswer = (status: string): FixtureRoute => ({
  match: (path, method) => path === '/api/signup/slug' && method === 'GET',
  reply: () => ({ status: 200, body: { status } }),
})
const slug = slugAnswer('available')

const FILLED = { company: 'My Company', userName: 'Aigul Bek', email: 'aigul@known-co.test', slug: 'my-company' }

const verify = (status: number): FixtureRoute => ({
  match: (path, method) => path === '/api/signup/verify' && method === 'POST',
  reply: () => (status === 200 ? { status, body: { status: 'verified' } } : { status, body: { error: 'invalid_or_expired_link' } }),
})

const statusRoute = (body: unknown): FixtureRoute => ({
  match: (path, method) => path === '/api/signup/status' && method === 'POST',
  reply: () => ({ status: 200, body }),
})

const TOKEN = 'harness-token-harness-token'

export const signupScreens: HarnessScreen[] = [
  { name: 'signup-form', routes: [config(false), slug], render: () => <SignupPage /> },
  { name: 'signup-form-password', routes: [config(true), slug], render: () => <SignupPage /> },
  {
    name: 'signup-result-ready',
    routes: [verify(200), statusRoute({ state: 'ready', host: 'my-company.demo.example.test', realm: 't-0123456789abcdef0123', reason: null })],
    render: () => <SignupResultPage tokenOverride={TOKEN} />,
  },
  {
    name: 'signup-result-capped',
    routes: [verify(200), statusRoute({ state: 'failed', host: null, realm: null, reason: 'demo_cap_reached' })],
    render: () => <SignupResultPage tokenOverride={TOKEN} />,
  },
  { name: 'signup-result-invalid', routes: [verify(400)], render: () => <SignupResultPage tokenOverride={TOKEN} /> },
  // Presets: states that otherwise need typing (live check answers, the five submit errors, the mail notice).
  { name: 'signup-slug-available', routes: [config(false), slug], render: () => <SignupPage preset={{ ...FILLED, slugState: 'available' }} /> },
  { name: 'signup-slug-taken', routes: [config(false), slugAnswer('taken')], render: () => <SignupPage preset={{ ...FILLED, slugState: 'taken' }} /> },
  { name: 'signup-slug-reserved', routes: [config(false), slugAnswer('reserved')], render: () => <SignupPage preset={{ ...FILLED, slug: 'admin', slugState: 'reserved' }} /> },
  { name: 'signup-slug-invalid', routes: [config(false), slug], render: () => <SignupPage preset={{ ...FILLED, slug: 'Bad_Slug!' }} /> },
  {
    name: 'signup-error-rate-limited',
    routes: [config(false), slug],
    render: () => <SignupPage preset={{ ...FILLED, slugState: 'available', outcome: { kind: 'rate_limited', retryAfterSeconds: 60 } }} />,
  },
  {
    name: 'signup-error-unavailable',
    routes: [config(false), slug],
    render: () => <SignupPage preset={{ ...FILLED, slugState: 'available', outcome: { kind: 'unavailable' } }} />,
  },
  {
    name: 'signup-error-email',
    routes: [config(false), slug],
    render: () => <SignupPage preset={{ ...FILLED, slugState: 'available', outcome: { kind: 'email_not_accepted' } }} />,
  },
  {
    name: 'signup-error-slug-taken',
    routes: [config(false), slugAnswer('taken')],
    render: () => <SignupPage preset={{ ...FILLED, slugState: 'taken', outcome: { kind: 'slug_taken' } }} />,
  },
  { name: 'signup-sent', routes: [config(false), slug], render: () => <SignupPage preset={{ ...FILLED, phase: 'sent' }} /> },
]
