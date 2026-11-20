/** CompanyNotFound -- T-2350: one page for an unknown company code and for a refused
 *  redirect. The text is the same in both cases and names no company, so it cannot be
 *  used to find out whether a company exists. The typed code is only ever put into the
 *  query of this same origin's root (`/?realm=<encoded>`), never into a redirect target
 *  to another host. */
import { useState } from 'react'
import type { FormEvent } from 'react'
import { useIntl } from 'react-intl'
import { LoginIntlProvider } from '@/i18n/LoginIntlProvider'

const ORG_CODE_MAX_LENGTH = 255

function CompanyNotFoundContent() {
  const intl = useIntl()
  const [code, setCode] = useState('')
  const [invalid, setInvalid] = useState(false)

  const onSubmit = (event: FormEvent) => {
    event.preventDefault()
    const value = code.trim()
    if (value.length === 0 || value.length > ORG_CODE_MAX_LENGTH) {
      setInvalid(true)
      return
    }
    window.location.assign('/?realm=' + encodeURIComponent(value))
  }

  return (
    <main
      data-testid="company-not-found"
      style={{ maxWidth: '26rem', margin: '4rem auto', padding: '0 1rem', color: 'var(--text-primary)' }}
    >
      <h1>{intl.formatMessage({ id: 'login.companyNotFound.title' })}</h1>
      <p role="alert">{intl.formatMessage({ id: 'login.companyNotFound.body' })}</p>
      <form onSubmit={onSubmit} noValidate data-testid="company-not-found-form">
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.25rem', marginBottom: '0.75rem' }}>
          <label htmlFor="company-not-found-code">{intl.formatMessage({ id: 'login.org.label' })}</label>
          <input
            id="company-not-found-code"
            type="text"
            autoComplete="organization"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            aria-invalid={invalid}
          />
          {invalid && (
            <p role="alert" data-testid="company-not-found-invalid">
              {intl.formatMessage({ id: 'login.org.invalid' })}
            </p>
          )}
        </div>
        <button type="submit" data-testid="company-not-found-submit">
          {intl.formatMessage({ id: 'login.org.submit' })}
        </button>
      </form>
    </main>
  )
}

export function CompanyNotFound() {
  return (
    <LoginIntlProvider>
      <CompanyNotFoundContent />
    </LoginIntlProvider>
  )
}
