/** LoginPage -- REQ-438: the public, credential-free email-first login screen.
 *
 *  Design: lib/letflow/design/req434-email-first-login-directory.md sections 8, 10, 11.
 *
 *  This page collects an email ADDRESS only (never a password or token) and
 *  hands off to the identity provider's hosted login. Its states are driven
 *  solely by the closed discovery outcome union in api/loginDiscovery.ts:
 *  idle, loading, neutral (accepted), network error, rate limited, malformed.
 *  A discovered tenant is not a rendered state: it stores the realm slug and
 *  redirects.
 *
 *  The organisation-code control is a static part of the page, present in every
 *  state, so it adds no state-dependent DOM (the neutral DOM is therefore the
 *  same whatever the server's reason for the neutral reply) and a 429 is never a
 *  dead end. Its submit performs a FULL page navigation to
 *  `/?realm=<url-encoded code>` with no discovery call: a full load is needed
 *  because the OIDC manager singleton and tenant-config cache may already be
 *  bound to the default realm in this page load.
 */
import { useCallback, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { isEmailFirstLoginEnabled } from '@/auth/emailFirstFlag'
import { buildRedirectArgs } from '@/auth/oidcRedirectArgs'
import { storeRealmSlug } from '@/auth/tenantConfig'
import { getOrCreateManagerForTenant } from '@/auth/tenantOidcRegistry'
import { loginDiscoveryApi } from '@/api/loginDiscovery'
import { LoginIntlProvider } from '@/i18n/LoginIntlProvider'
import { SkipLink } from '@/components/layout/SkipLink'

type PageState = 'idle' | 'loading' | 'neutral' | 'network_error' | 'rate_limited' | 'malformed'

const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const EMAIL_MAX_LENGTH = 254
const ORG_CODE_MAX_LENGTH = 255

/** Client-side SHAPE validation only; the server decides everything else. */
export function isPlausibleEmail(value: string): boolean {
  return value.length <= EMAIL_MAX_LENGTH && EMAIL_SHAPE.test(value)
}

/** Non-empty and at most 255 characters; slugs have no charset constraint. */
export function isValidOrgCode(value: string): boolean {
  return value.length > 0 && value.length <= ORG_CODE_MAX_LENGTH
}

function readFromPath(state: unknown): string | undefined {
  if (typeof state === 'object' && state !== null && 'from' in state) {
    const from = (state as { from: unknown }).from
    if (typeof from === 'string') return from
  }
  return undefined
}

const fieldStyle = { display: 'flex', flexDirection: 'column', gap: '0.25rem', marginBottom: '0.75rem' } as const
const inputStyle = {
  padding: '0.5rem',
  border: '1px solid var(--border-default)',
  borderRadius: '4px',
  background: 'var(--surface-card)',
  color: 'var(--text-primary)',
} as const
const buttonStyle = {
  padding: '0.5rem 1rem',
  border: 'none',
  borderRadius: '4px',
  background: 'var(--interactive-primary)',
  color: 'var(--text-inverse)',
  cursor: 'pointer',
} as const
const errorTextStyle = { color: 'var(--color-error-dark)', margin: '0.25rem 0 0' } as const

function LoginPageContent() {
  const intl = useIntl()
  const { isAuthenticated } = useAuth()
  const location = useLocation()
  const fromPath = readFromPath(location.state)

  const [email, setEmail] = useState('')
  const [emailInvalid, setEmailInvalid] = useState(false)
  const [orgCode, setOrgCode] = useState('')
  const [orgCodeInvalid, setOrgCodeInvalid] = useState(false)
  const [state, setState] = useState<PageState>('idle')
  const inFlight = useRef(false)

  const runDiscovery = useCallback(
    async (address: string) => {
      if (inFlight.current) return
      inFlight.current = true
      setState('loading')
      try {
        const outcome = await loginDiscoveryApi.lookup(address)

        if (outcome.kind !== 'tenant') {
          setState(outcome.kind === 'accepted' ? 'neutral' : outcome.kind)
          return
        }

        // Single named tenant: store the slug exactly as a `?realm=` load
        // would, then hand off ONCE via the per-slug OIDC manager (never the
        // singleton, which may already be bound to the default realm).
        if (new URLSearchParams(window.location.search).has('realm')) {
          // A stray ?realm= on this URL would outrank the stored slug.
          const url = new URL(window.location.href)
          url.searchParams.delete('realm')
          window.history.replaceState(window.history.state, '', url.toString())
        }
        storeRealmSlug(outcome.tenant.slug)
        const manager = await getOrCreateManagerForTenant(outcome.tenant.slug)
        await manager.signinRedirect(buildRedirectArgs(fromPath, { loginHint: address }))
        // Stay in `loading`: the browser is navigating away.
      } catch {
        setState('network_error')
      } finally {
        inFlight.current = false
      }
    },
    [fromPath],
  )

  const onEmailSubmit = (event: FormEvent) => {
    event.preventDefault()
    const address = email.trim()
    if (!isPlausibleEmail(address)) {
      setEmailInvalid(true)
      return
    }
    setEmailInvalid(false)
    void runDiscovery(address)
  }

  const onRetry = () => {
    const address = email.trim()
    if (!isPlausibleEmail(address)) {
      setState('idle')
      setEmailInvalid(true)
      return
    }
    void runDiscovery(address)
  }

  const onOrgCodeSubmit = (event: FormEvent) => {
    event.preventDefault()
    const code = orgCode.trim()
    if (!isValidOrgCode(code)) {
      setOrgCodeInvalid(true)
      return
    }
    setOrgCodeInvalid(false)
    window.location.assign('/?realm=' + encodeURIComponent(code))
  }

  if (isAuthenticated) {
    return <Navigate to="/" replace />
  }

  const loading = state === 'loading'
  const retryButton = (
    <button type="button" style={buttonStyle} onClick={onRetry} data-testid="login-retry">
      {intl.formatMessage({ id: 'login.retry' })}
    </button>
  )

  return (
    <>
      <SkipLink label={intl.formatMessage({ id: 'login.skipToContent' })} />
    <main
      id="main-content"
      tabIndex={-1}
      data-testid="login-page"
      style={{ maxWidth: '26rem', margin: '4rem auto', padding: '0 1rem', color: 'var(--text-primary)' }}
    >
      <h1>{intl.formatMessage({ id: 'login.title' })}</h1>
      <p>{intl.formatMessage({ id: 'login.intro' })}</p>

      <form onSubmit={onEmailSubmit} noValidate data-testid="login-email-form">
        <div style={fieldStyle}>
          <label htmlFor="login-email">{intl.formatMessage({ id: 'login.email.label' })}</label>
          <input
            id="login-email"
            name="email"
            type="email"
            autoComplete="email"
            style={inputStyle}
            placeholder={intl.formatMessage({ id: 'login.email.placeholder' })}
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            aria-invalid={emailInvalid}
            aria-describedby={emailInvalid ? 'login-email-error' : undefined}
          />
          {emailInvalid && (
            <p id="login-email-error" role="alert" style={errorTextStyle} data-testid="login-email-invalid">
              {intl.formatMessage({ id: 'login.email.invalid' })}
            </p>
          )}
        </div>
        <button type="submit" style={buttonStyle} disabled={loading} data-testid="login-submit">
          {intl.formatMessage({ id: loading ? 'login.submitting' : 'login.submit' })}
        </button>
      </form>

      {state === 'neutral' && (
        <p role="status" data-testid="login-neutral">
          {intl.formatMessage({ id: 'login.neutral' })}
        </p>
      )}
      {state === 'network_error' && (
        <div role="alert" data-testid="login-error-network">
          <p>{intl.formatMessage({ id: 'login.error.network' })}</p>
          {retryButton}
        </div>
      )}
      {state === 'rate_limited' && (
        <div role="alert" data-testid="login-error-rate-limited">
          <p>{intl.formatMessage({ id: 'login.error.rateLimited' })}</p>
          {retryButton}
        </div>
      )}
      {state === 'malformed' && (
        <div role="alert" data-testid="login-error-malformed">
          <p>{intl.formatMessage({ id: 'login.error.malformed' })}</p>
          {retryButton}
        </div>
      )}

      <section aria-labelledby="login-org-heading" style={{ marginTop: '2rem' }}>
        <h2 id="login-org-heading">{intl.formatMessage({ id: 'login.org.heading' })}</h2>
        <form onSubmit={onOrgCodeSubmit} noValidate data-testid="login-org-form">
          <div style={fieldStyle}>
            <label htmlFor="login-org-code">{intl.formatMessage({ id: 'login.org.label' })}</label>
            <input
              id="login-org-code"
              name="organisation_code"
              type="text"
              autoComplete="organization"
              style={inputStyle}
              value={orgCode}
              onChange={(e) => setOrgCode(e.target.value)}
              aria-invalid={orgCodeInvalid}
              aria-describedby={orgCodeInvalid ? 'login-org-error' : undefined}
            />
            {orgCodeInvalid && (
              <p id="login-org-error" role="alert" style={errorTextStyle} data-testid="login-org-invalid">
                {intl.formatMessage({ id: 'login.org.invalid' })}
              </p>
            )}
          </div>
          <button type="submit" style={buttonStyle} data-testid="login-org-submit">
            {intl.formatMessage({ id: 'login.org.submit' })}
          </button>
        </form>
      </section>
    </main>
    </>
  )
}

export default function LoginPage() {
  return (
    <LoginIntlProvider>
      <LoginPageContent />
    </LoginIntlProvider>
  )
}

/** Route element for `/login`. With the build flag off the screen does not
 *  exist: redirect to `/` (replace) before LoginPage mounts, so no discovery
 *  call or OIDC redirect can originate here (REQ-438: flag off == today). */
export function LoginRoute() {
  const enabled = isEmailFirstLoginEnabled()
  return enabled ? <LoginPage /> : <Navigate to="/" replace />
}
