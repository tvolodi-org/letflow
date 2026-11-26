/** SignupResultPage -- T-2748 (PILOT G22): the page the mailed link opens, /signup/verify?token=...
 *
 *  Posts the token once (POST /api/signup/verify; a POST so a mail scanner cannot consume it), then polls
 *  POST /api/signup/status (bounded: STATUS_MAX_POLLS every STATUS_INTERVAL_MS) until the tenant exists. Ready
 *  shows the tenant URL and a sign-in link (`https://<host>/?realm=<realm>`); the failure reasons (demo cap,
 *  provisioner unavailable, rate limited, address taken) each show their own text and a way to start again.
 *  The token is read from the address once and kept in memory only; it is never logged.
 */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { useSearchParams } from 'react-router-dom'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { SignupIntlProvider } from '@/i18n/SignupIntlProvider'
import { fetchSignupStatus, verifySignupToken, type SignupStatusOutcome } from '@/api/signupApi'

export const STATUS_INTERVAL_MS = 2000
export const STATUS_MAX_POLLS = 60

type View = { kind: 'checking' } | { kind: 'timeout' } | Exclude<SignupStatusOutcome, { kind: 'pending' }>

function ResultContent({ tokenOverride }: { tokenOverride?: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id: `signup.result.${id}` })
  const [params] = useSearchParams()
  const token = tokenOverride ?? params.get('token') ?? ''
  const [view, setView] = useState<View>({ kind: 'checking' })
  const [attempt, setAttempt] = useState(0)
  // A Retry after a named failure asks the server to resume provisioning; load and other retries do not.
  const [retryFailed, setRetryFailed] = useState(false)

  useEffect(() => {
    let cancelled = false
    let timer: number | undefined
    setView({ kind: 'checking' })

    const poll = async (n: number) => {
      const status = await fetchSignupStatus(token)
      if (cancelled) return
      if (status.kind !== 'pending') {
        setView(status)
      } else if (n >= STATUS_MAX_POLLS) {
        setView({ kind: 'timeout' })
      } else {
        timer = window.setTimeout(() => void poll(n + 1), STATUS_INTERVAL_MS)
      }
    }

    const run = async () => {
      if (token === '') {
        setView({ kind: 'invalid_link' })
        return
      }
      const verified = await verifySignupToken(token, retryFailed)
      if (cancelled) return
      if (verified !== 'ok') {
        setView({ kind: verified })
        return
      }
      await poll(1)
    }
    void run()
    return () => {
      cancelled = true
      if (timer !== undefined) window.clearTimeout(timer)
    }
  }, [token, attempt, retryFailed])

  const retry = (
    <Button variant="secondary" size="sm" onClick={() => {
        setRetryFailed(view.kind === 'failed')
        setAttempt(a => a + 1)
      }} data-testid="signup-result-retry">
      {intl.formatMessage({ id: 'signup.retry' })}
    </Button>
  )

  let body
  switch (view.kind) {
    case 'checking':
      body = <Banner tone="info">{t('checking')}</Banner>
      break
    case 'ready': {
      const url = `https://${view.host}/`
      const signIn = `https://${view.host}/?realm=${encodeURIComponent(view.realm)}`
      body = (
        <>
          <Banner tone="success">{t('ready')}</Banner>
          <p>
            {t('url')}: <a className="lf-signup__url mono" href={url} data-testid="signup-tenant-url">{url}</a>
          </p>
          <p>{t('signinHint')}</p>
          <div className="lf-signup__actions">
            <a className="lf-btn lf-btn--primary" href={signIn} data-testid="signup-signin-link">
              {t('signin')}
            </a>
          </div>
        </>
      )
      break
    }
    case 'failed':
      body = (
        <Banner tone="danger" action={retry}>
          <span data-testid="signup-result-error" data-reason={view.reason}>{t(`fail.${view.reason}`)}</span>
        </Banner>
      )
      break
    case 'invalid_link':
      body = (
        <Banner
          tone="danger"
          action={
            <a className="lf-btn lf-btn--secondary" href="/signup" data-testid="signup-again">
              {t('again')}
            </a>
          }
        >
          <span data-testid="signup-result-error" data-reason="invalid_link">{t('invalidLink')}</span>
        </Banner>
      )
      break
    case 'timeout':
    case 'network_error':
      body = (
        <Banner tone="warning" action={retry}>
          <span data-testid="signup-result-error" data-reason={view.kind}>{t('network')}</span>
        </Banner>
      )
      break
  }

  return (
    <main className="lf-signup" data-testid="signup-result-page">
      <PageHeader title={t('title')} />
      {body}
    </main>
  )
}

/** `tokenOverride` is for the screen harness only (the harness cannot put a query string on the real address). */
export default function SignupResultPage({ tokenOverride }: { tokenOverride?: string } = {}) {
  return (
    <SignupIntlProvider>
      <ResultContent tokenOverride={tokenOverride} />
    </SignupIntlProvider>
  )
}
