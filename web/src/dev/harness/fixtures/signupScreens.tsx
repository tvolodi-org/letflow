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

const slug: FixtureRoute = {
  match: (path, method) => path === '/api/signup/slug' && method === 'GET',
  reply: () => ({ status: 200, body: { status: 'available' } }),
}

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
]
