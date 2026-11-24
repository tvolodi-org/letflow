/** SignupPage -- T-2748 (PILOT G22): the public self-service sign-up form at /signup.
 *
 *  Fields: company name, user name, e-mail (the mailed confirmation link and the first sign-in details go
 *  there), the workspace address (slug) with a LIVE availability check, and a password field ONLY when the
 *  server config says the provisioner takes a visitor password (`password_required`; it does not yet, so the
 *  interim live path mails a temporary password). The password lives in component state only: it is sent in
 *  the one request body, cleared after the send, and never rendered back, stored or logged.
 *  States: form, sending, check-your-mail, and the error cases (slug taken, e-mail refused, rate limited,
 *  unavailable, network) each with a retry the visitor can use. Public: outside ProtectedRoute.
 */
import { useEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { Field } from '@/components/ui/Field'
import { PageHeader } from '@/components/ui/PageHeader'
import { SignupIntlProvider } from '@/i18n/SignupIntlProvider'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import {
  checkSlug,
  fetchSignupConfig,
  submitSignup,
  type SignupConfig,
  type SignupSubmitOutcome,
  type SlugStatus,
} from '@/api/signupApi'
import { isEmailShape, isSlugShape, isStrongPassword, suggestSlug } from './signupModel'

type SlugState = 'idle' | 'checking' | SlugStatus | 'unchecked'
type Phase = 'form' | 'sending' | 'sent'
type FieldKey = 'company' | 'user' | 'email' | 'slug' | 'password' | 'terms'

const SLUG_DEBOUNCE_MS = 300

function SignupForm() {
  const intl = useIntl()
  const locale = useUiLocale()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id: `signup.${id}` }, values)

  const [config, setConfig] = useState<SignupConfig | null | undefined>(undefined)
  const [company, setCompany] = useState('')
  const [userName, setUserName] = useState('')
  const [email, setEmail] = useState('')
  const [slug, setSlug] = useState('')
  const [slugTouched, setSlugTouched] = useState(false)
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [terms, setTerms] = useState(false)
  const [slugState, setSlugState] = useState<SlugState>('idle')
  const [errors, setErrors] = useState<Partial<Record<FieldKey, string>>>({})
  const [outcome, setOutcome] = useState<SignupSubmitOutcome | null>(null)
  const [phase, setPhase] = useState<Phase>('form')
  const checkSeq = useRef(0)

  useEffect(() => {
    let cancelled = false
    void fetchSignupConfig().then(c => {
      if (!cancelled) setConfig(c)
    })
    return () => {
      cancelled = true
    }
  }, [])

  // Live availability: debounced, and a late answer for an older value is dropped.
  useEffect(() => {
    if (slug === '') {
      setSlugState('idle')
      return
    }
    if (!isSlugShape(slug)) {
      setSlugState('invalid')
      return
    }
    setSlugState('checking')
    const seq = ++checkSeq.current
    const timer = window.setTimeout(() => {
      void checkSlug(slug).then(status => {
        if (seq === checkSeq.current) setSlugState(status ?? 'unchecked')
      })
    }, SLUG_DEBOUNCE_MS)
    return () => window.clearTimeout(timer)
  }, [slug])

  const onCompany = (value: string) => {
    setCompany(value)
    if (!slugTouched) setSlug(suggestSlug(value))
  }

  const domain = config?.hostnameDomain ?? ''
  const needsPassword = config?.passwordRequired === true

  const slugMessage = (): { hint?: string; error?: string } => {
    switch (slugState) {
      case 'checking':
        return { hint: t('slug.checking') }
      case 'available':
        return { hint: t('slug.available') }
      case 'taken':
        return { error: t('slug.taken') }
      case 'reserved':
        return { error: t('slug.reserved') }
      case 'invalid':
        return { error: t('slug.invalid') }
      case 'unchecked':
        return { hint: t('slug.unchecked') }
      default:
        return { hint: t('slug.hint', { slug: slug || 'name', domain }) }
    }
  }

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault()
    if (phase === 'sending') return
    const next: Partial<Record<FieldKey, string>> = {}
    if (company.trim() === '') next.company = t('required')
    if (userName.trim() === '') next.user = t('required')
    if (!isEmailShape(email.trim())) next.email = t('email.invalid')
    if (!isSlugShape(slug)) next.slug = t('slug.invalid')
    else if (slugState === 'taken' || slugState === 'reserved') next.slug = t(`slug.${slugState}`)
    if (needsPassword && !isStrongPassword(password)) next.password = t('password.weak')
    if (!terms) next.terms = t('required')
    setErrors(next)
    setOutcome(null)
    if (Object.keys(next).length > 0) return

    setPhase('sending')
    const result = await submitSignup({
      companyName: company.trim(),
      userName: userName.trim(),
      email: email.trim(),
      language: locale,
      slug,
      termsAccepted: true,
      password: needsPassword ? password : undefined,
    })
    setPassword('')
    if (result.kind === 'accepted') {
      setPhase('sent')
      return
    }
    if (result.kind === 'slug_taken') setSlugState('taken')
    setOutcome(result)
    setPhase('form')
  }

  const failureText = (o: SignupSubmitOutcome): string | null => {
    switch (o.kind) {
      case 'slug_taken':
        return t('error.slugTaken')
      case 'email_not_accepted':
        return t('error.email')
      case 'rate_limited':
        return t('error.rateLimited')
      case 'unavailable':
        return t('error.unavailable')
      case 'network_error':
        return t('error.network')
      case 'invalid':
        return t('error.invalid')
      default:
        return null
    }
  }

  if (config === undefined) {
    return <main className="lf-signup" data-testid="signup-loading" aria-busy="true" />
  }
  if (config === null) {
    return (
      <main className="lf-signup">
        <Banner tone="danger">{t('error.disabled')}</Banner>
      </main>
    )
  }
  if (phase === 'sent') {
    return (
      <main className="lf-signup" data-testid="signup-sent">
        <PageHeader title={t('check.title')} />
        <Banner tone="success">{t('check.body')}</Banner>
      </main>
    )
  }

  const failure = outcome ? failureText(outcome) : null
  const slugMsg = slugMessage()

  return (
    <main className="lf-signup" data-testid="signup-page">
      <PageHeader title={t('title')} lede={t('lede')} />
      {failure && (
        <Banner
          tone="danger"
          action={
            <Button variant="secondary" size="sm" onClick={() => setOutcome(null)} data-testid="signup-retry">
              {t('retry')}
            </Button>
          }
        >
          <span data-testid="signup-error" data-kind={outcome?.kind}>
            {failure}
          </span>
        </Banner>
      )}
      <form onSubmit={onSubmit} noValidate data-testid="signup-form">
        <Field label={t('company.label')} error={errors.company} width="l">
          <input type="text" value={company} maxLength={200} autoComplete="organization" onChange={e => onCompany(e.target.value)} />
        </Field>
        <Field label={t('user.label')} error={errors.user} width="l">
          <input type="text" value={userName} maxLength={100} autoComplete="name" onChange={e => setUserName(e.target.value)} />
        </Field>
        <Field label={t('email.label')} hint={t('email.hint')} error={errors.email} width="l">
          <input type="email" value={email} maxLength={254} autoComplete="email" onChange={e => setEmail(e.target.value)} />
        </Field>
        <Field label={t('slug.label')} hint={slugMsg.hint} error={errors.slug ?? slugMsg.error} width="m" mono data-testid="signup-slug-field">
          <input
            type="text"
            value={slug}
            maxLength={30}
            autoCapitalize="none"
            spellCheck={false}
            onChange={e => {
              setSlugTouched(true)
              setSlug(e.target.value.toLowerCase())
            }}
          />
        </Field>
        {needsPassword && (
          <>
            <Field label={t('password.label')} hint={t('password.hint')} error={errors.password} width="m">
              <input
                type={showPassword ? 'text' : 'password'}
                value={password}
                maxLength={128}
                autoComplete="new-password"
                onChange={e => setPassword(e.target.value)}
              />
            </Field>
            <Checkbox
              label={showPassword ? t('password.hide') : t('password.show')}
              checked={showPassword}
              onChange={setShowPassword}
              data-testid="signup-show-password"
            />
          </>
        )}
        <Checkbox label={t('terms.label')} checked={terms} onChange={setTerms} data-testid="signup-terms" />
        {errors.terms && <p role="alert">{errors.terms}</p>}
        <div className="lf-signup__actions">
          <Button variant="primary" type="submit" loading={phase === 'sending'} data-testid="signup-submit">
            {phase === 'sending' ? t('submitting') : t('submit')}
          </Button>
        </div>
      </form>
    </main>
  )
}

export default function SignupPage() {
  return (
    <SignupIntlProvider>
      <SignupForm />
    </SignupIntlProvider>
  )
}
