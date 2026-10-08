/** RegisterTenantPage — ONB-UI-02
 *
 * Collects onboarding inputs for a new tenant and submits to POST /api/v1/onboarding.
 * Role guard: redirects to /instances if session does not include PLATFORM_ADMIN.
 * On success navigates to OnboardingProgressPage with form values in router state.
 */

import { useState, useEffect, useRef } from 'react'
import { Navigate, useNavigate, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { Button } from '@/components/ui/Button'
import {
  submitOnboarding,
  OnboardingApiError,
  fieldErrorConstraint,
  type OnboardingFormValues,
} from '@/api/onboarding'

// NOTE: the Realm Config / Client Config disclosure buttons below stay
// native <button> elements, not Button (REQ-272) -- Button's model is a
// fixed-size inline-flex control (sm/md/lg padding, centred content); it
// has no full-width / text-align:left mode, which this collapsible
// section header requires. Colours are still fully tokenized.

// ── Types ──────────────────────────────────────────────────────────────────────

interface FormState {
  slug: string
  display_name: string
  admin_email: string
  admin_username: string
  admin_display_name: string
  hostname: string
  idp_realm_id: string
  redirect_uris: string[]
  realm_default_token_lifetime_seconds: string
  realm_min_password_length: string
  realm_require_uppercase: boolean
  realm_require_digit: boolean
  realm_signing_key_algorithm: string
  client_service_account_enabled: boolean
}

interface FormErrors {
  slug?: string
  display_name?: string
  admin_email?: string
  admin_username?: string
  admin_display_name?: string
  hostname?: string
  idp_realm_id?: string
  redirect_uris?: string
}

// Client-side format HINT for the optional realm id (ISS-1030). The server
// re-validates, checks the realm with the identity provider and is
// authoritative; this only saves a round trip on an obvious typo.
const REALM_ID_FORMAT = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

const REALM_SERVER_MESSAGES: Record<string, string> = {
  format: 'The server rejected this realm id: invalid format.',
  reserved: 'The server rejected this realm id: it is reserved.',
  not_found: 'The identity provider does not know this realm.',
  not_blank: 'The realm id must not be blank.',
}

const EMPTY_FORM: FormState = {
  slug: '',
  display_name: '',
  admin_email: '',
  admin_username: '',
  admin_display_name: '',
  hostname: '',
  idp_realm_id: '',
  redirect_uris: [''],
  realm_default_token_lifetime_seconds: '',
  realm_min_password_length: '',
  realm_require_uppercase: false,
  realm_require_digit: false,
  realm_signing_key_algorithm: '',
  client_service_account_enabled: false,
}

// ── Validation ─────────────────────────────────────────────────────────────────

function validateForm(form: FormState): FormErrors {
  const errors: FormErrors = {}

  if (!form.slug.trim()) {
    errors.slug = 'Slug is required'
  } else if (form.slug.length < 3 || form.slug.length > 63) {
    errors.slug = 'Slug must be 3–63 characters'
  } else if (!/^[a-z0-9-]+$/.test(form.slug)) {
    errors.slug = 'Slug may only contain lowercase letters, digits, and hyphens'
  }

  if (!form.display_name.trim()) {
    errors.display_name = 'Display name is required'
  }

  // ISS-1030: the admin fields are optional (the platform does not provision
  // an administrator yet); a filled email must still look like an address.
  const adminEmail = form.admin_email.trim()
  if (adminEmail && (!adminEmail.includes('@') || adminEmail.split('@')[1]?.length === 0)) {
    errors.admin_email = 'Enter a valid email address'
  }

  const realm = form.idp_realm_id.trim()
  if (realm && !REALM_ID_FORMAT.test(realm)) {
    errors.idp_realm_id =
      'Use 1–64 letters, digits, "_" or "-", starting with a letter or digit'
  }

  if (!form.hostname.trim()) {
    errors.hostname = 'Hostname is required'
  } else if (/^https?:\/\//i.test(form.hostname) || form.hostname.includes('/')) {
    errors.hostname = 'Enter a hostname only (no protocol or path)'
  }

  const nonEmptyUris = form.redirect_uris.filter((u) => u.trim().length > 0)
  if (nonEmptyUris.length === 0) {
    errors.redirect_uris = 'At least one redirect URI is required'
  }

  return errors
}

// ── Error taxonomy banner message ──────────────────────────────────────────────

interface ApiErrorView {
  banner: string
  progressLink?: string
  realmError?: string
  adminEmailError?: string
}

function resolveApiErrorMessage(
  err: OnboardingApiError,
): ApiErrorView {
  const { httpStatus, body } = err
  const errorCode = body['error'] as string | undefined
  const problemType = body['type'] as string | undefined

  if (httpStatus === 409) {
    if (errorCode === 'onboarding_in_progress') {
      const oid = body['onboarding_id'] as string | undefined
      return {
        banner: 'An onboarding for this tenant is already in progress.',
        progressLink: oid ? `/admin/onboarding/${oid}/progress` : undefined,
      }
    }
    if (problemType?.includes('idempotency-conflict')) {
      return { banner: 'A conflicting submission was detected. Please start over.' }
    }
    // Other 409 (DuplicateTenantSlug, DuplicateHostname, RealmAlreadyExists etc.)
    const title = (body['title'] as string) ?? (body['detail'] as string)
    return { banner: title ?? 'A conflict was detected. Please check your inputs.' }
  }

  if (httpStatus === 422) {
    if (errorCode === 'idempotency_key_required') {
      return { banner: 'Internal error: idempotency key missing. Please reload and try again.' }
    }
    const realmConstraint = fieldErrorConstraint(body, 'idp_realm_id')
    if (realmConstraint) {
      return {
        banner: 'The server rejected the submission due to a validation error. Please check all fields.',
        realmError: REALM_SERVER_MESSAGES[realmConstraint] ?? 'The server rejected this realm id.',
      }
    }
    const adminEmailConstraint = fieldErrorConstraint(body, 'admin_email')
    if (adminEmailConstraint) {
      return {
        banner: 'The server rejected the submission due to a validation error. Please check all fields.',
        adminEmailError: 'The server rejected the admin email.',
      }
    }
    return { banner: 'The server rejected the submission due to a validation error. Please check all fields.' }
  }

  if (httpStatus === 502) {
    return { banner: 'Tenant provisioning failed at the identity provider. Check Keycloak connectivity and try again.' }
  }

  if (httpStatus === 503) {
    return { banner: 'The onboarding service is temporarily unavailable. Please try again in a moment.' }
  }

  return { banner: 'An unexpected error occurred. Please try again.' }
}

// ── Shared input style ─────────────────────────────────────────────────────────

const inputStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  padding: '.45rem .65rem',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 'var(--text-base)',
  boxSizing: 'border-box',
}

const errorStyle: React.CSSProperties = {
  color: 'var(--color-error)',
  fontSize: '.8rem',
  marginTop: '.2rem',
}

const labelStyle: React.CSSProperties = {
  display: 'block',
  marginBottom: '.3rem',
  fontWeight: 600,
  fontSize: '.87rem',
  color: 'var(--text-primary)',
}

const fieldGroupStyle: React.CSSProperties = {
  marginBottom: '1rem',
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function buildRealmConfig(form: FormState) {
  const cfg: Record<string, unknown> = {}
  if (form.realm_default_token_lifetime_seconds.trim()) {
    const v = parseInt(form.realm_default_token_lifetime_seconds, 10)
    if (!isNaN(v)) cfg['default_token_lifetime_seconds'] = v
  }
  if (form.realm_min_password_length.trim()) {
    const v = parseInt(form.realm_min_password_length, 10)
    if (!isNaN(v)) cfg['min_password_length'] = v
  }
  if (form.realm_require_uppercase) cfg['require_uppercase'] = true
  if (form.realm_require_digit) cfg['require_digit'] = true
  if (form.realm_signing_key_algorithm.trim()) {
    cfg['signing_key_algorithm'] = form.realm_signing_key_algorithm.trim()
  }
  return Object.keys(cfg).length > 0 ? cfg : undefined
}

function buildClientConfig(form: FormState) {
  if (form.client_service_account_enabled) {
    return { service_account_enabled: true }
  }
  return undefined
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function RegisterTenantPage() {
  const { session } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()

  const prefill = (location.state as { prefill?: Partial<FormState> } | null)?.prefill

  // All hooks must be called before any early return
  const [form, setForm] = useState<FormState>(() =>
    prefill
      ? { ...EMPTY_FORM, ...prefill, redirect_uris: (prefill.redirect_uris as string[] | undefined) ?? [''] }
      : { ...EMPTY_FORM },
  )
  const [errors, setErrors] = useState<FormErrors>({})
  const [idempotencyKey] = useState<string>(() => crypto.randomUUID())
  const [submitting, setSubmitting] = useState(false)
  const [apiError, setApiError] = useState<ApiErrorView | null>(null)
  const formRef = useRef<HTMLFormElement>(null)
  const [realmOpen, setRealmOpen] = useState(false)
  const [clientOpen, setClientOpen] = useState(false)

  // Clear API error when form changes
  useEffect(() => {
    setApiError(null)
  }, [form])

  // Role guard — after all hooks
  if (!session?.roles.includes('PLATFORM_ADMIN')) {
    return <Navigate to="/instances" replace />
  }

  function setField<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => ({ ...prev, [key]: value }))
    const draft = { ...form, [key]: value }
    const fieldErrors = validateForm(draft)
    setErrors((prev) => ({
      ...prev,
      [key]: fieldErrors[key as keyof FormErrors],
    }))
  }

  function setRedirectUri(index: number, value: string) {
    const updated = [...form.redirect_uris]
    updated[index] = value
    setForm((prev) => ({ ...prev, redirect_uris: updated }))
    const draft = { ...form, redirect_uris: updated }
    const fieldErrors = validateForm(draft)
    setErrors((prev) => ({ ...prev, redirect_uris: fieldErrors.redirect_uris }))
  }

  function addRedirectUri() {
    setForm((prev) => ({ ...prev, redirect_uris: [...prev.redirect_uris, ''] }))
  }

  function removeRedirectUri(index: number) {
    const updated = form.redirect_uris.filter((_, i) => i !== index)
    const final = updated.length === 0 ? [''] : updated
    setForm((prev) => ({ ...prev, redirect_uris: final }))
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const allErrors = validateForm(form)
    if (Object.keys(allErrors).length > 0) {
      setErrors(allErrors)
      return
    }

    setSubmitting(true)
    setApiError(null)

    const formValues: OnboardingFormValues = {
      slug: form.slug.trim(),
      display_name: form.display_name.trim(),
      admin_email: form.admin_email.trim(),
      admin_username: form.admin_username.trim(),
      admin_display_name: form.admin_display_name.trim(),
      hostname: form.hostname.trim(),
      idp_realm_id: form.idp_realm_id.trim(),
      redirect_uris: form.redirect_uris.map((u) => u.trim()).filter((u) => u.length > 0),
      realm_config: buildRealmConfig(form),
      client_config: buildClientConfig(form),
    }

    try {
      const created = await submitOnboarding(formValues, idempotencyKey)
      // The backend is synchronous: the 201 already carries the final record,
      // so go straight to the result page (no progress polling).
      navigate(
        `/admin/onboarding/${created.onboarding_id}/result?hostname=${encodeURIComponent(formValues.hostname)}`,
        { state: { sagaResult: created.result, formValues } },
      )
    } catch (err) {
      if (err instanceof OnboardingApiError) {
        const resolved = resolveApiErrorMessage(err)
        setApiError(resolved)
      } else {
        setApiError({ banner: 'An unexpected error occurred. Please try again.' })
      }
      setSubmitting(false)
    }
  }

  return (
    <div style={{ padding: '1.5rem', maxWidth: '680px' }}>
      <h2 style={{ margin: '0 0 1.5rem 0' }}>Register Tenant</h2>

      {apiError && (
        <div
          role="alert"
          style={{
            marginBottom: '1.25rem',
            padding: '.75rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-error-border)',
            background: 'var(--color-error-tint)',
            color: 'var(--color-error-dark)',
            fontSize: '.88rem',
          }}
        >
          {apiError.banner}
          {apiError.progressLink && (
            <>
              {' '}
              <a href={apiError.progressLink} style={{ color: 'var(--interactive-primary)' }}>
                View progress
              </a>
            </>
          )}
        </div>
      )}

      <form ref={formRef} onSubmit={(e) => { void handleSubmit(e) }} noValidate>
        {/* Slug */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="slug">Slug</label>
          <input
            id="slug"
            style={{ ...inputStyle, borderColor: errors.slug ? 'var(--border-error)' : 'var(--border-default)' }}
            value={form.slug}
            onChange={(e) => setField('slug', e.target.value)}
            autoComplete="off"
          />
          {errors.slug && <div style={errorStyle}>{errors.slug}</div>}
        </div>

        {/* Display name */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="display_name">Display Name</label>
          <input
            id="display_name"
            style={{ ...inputStyle, borderColor: errors.display_name ? 'var(--border-error)' : 'var(--border-default)' }}
            value={form.display_name}
            onChange={(e) => setField('display_name', e.target.value)}
          />
          {errors.display_name && <div style={errorStyle}>{errors.display_name}</div>}
        </div>

        <p
          style={{
            margin: '0 0 1rem 0',
            fontSize: '.85rem',
            color: 'var(--text-secondary)',
          }}
        >
          Administrator details are optional and not provisioned by the platform yet: they are
          not used to create a user. The tenant cannot be logged into until a realm is bound.
        </p>

        {/* Admin email */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="admin_email">Admin Email (optional)</label>
          <input
            id="admin_email"
            type="email"
            style={{ ...inputStyle, borderColor: errors.admin_email ? 'var(--border-error)' : 'var(--border-default)' }}
            value={form.admin_email}
            onChange={(e) => setField('admin_email', e.target.value)}
            autoComplete="off"
          />
          {errors.admin_email && <div style={errorStyle}>{errors.admin_email}</div>}
          {apiError?.adminEmailError && <div style={errorStyle}>{apiError.adminEmailError}</div>}
        </div>

        {/* Admin username */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="admin_username">Admin Username (optional)</label>
          <input
            id="admin_username"
            style={{ ...inputStyle, borderColor: errors.admin_username ? 'var(--border-error)' : 'var(--border-default)' }}
            value={form.admin_username}
            onChange={(e) => setField('admin_username', e.target.value)}
            autoComplete="off"
          />
          {errors.admin_username && <div style={errorStyle}>{errors.admin_username}</div>}
        </div>

        {/* Admin display name */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="admin_display_name">Admin Display Name (optional)</label>
          <input
            id="admin_display_name"
            style={{ ...inputStyle, borderColor: errors.admin_display_name ? 'var(--border-error)' : 'var(--border-default)' }}
            value={form.admin_display_name}
            onChange={(e) => setField('admin_display_name', e.target.value)}
          />
          {errors.admin_display_name && <div style={errorStyle}>{errors.admin_display_name}</div>}
        </div>

        {/* Hostname */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="hostname">Hostname</label>
          <input
            id="hostname"
            style={{ ...inputStyle, borderColor: errors.hostname ? 'var(--border-error)' : 'var(--border-default)' }}
            value={form.hostname}
            onChange={(e) => setField('hostname', e.target.value)}
            placeholder="tenant.example.com"
          />
          {errors.hostname && <div style={errorStyle}>{errors.hostname}</div>}
        </div>

        {/* Identity-provider realm id (optional, ISS-1030) */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="idp_realm_id">Identity Realm ID (optional)</label>
          <input
            id="idp_realm_id"
            style={{
              ...inputStyle,
              borderColor:
                errors.idp_realm_id || apiError?.realmError
                  ? 'var(--border-error)'
                  : 'var(--border-default)',
            }}
            value={form.idp_realm_id}
            onChange={(e) => setField('idp_realm_id', e.target.value)}
            autoComplete="off"
            aria-describedby="idp_realm_id_hint"
          />
          <div
            id="idp_realm_id_hint"
            style={{ fontSize: '.8rem', color: 'var(--text-secondary)', marginTop: '.2rem' }}
          >
            Leave empty if the realm does not exist yet; the tenant is then &quot;not yet
            loginable&quot; and the realm can be bound from the result page. The server checks the
            realm with the identity provider.
          </div>
          {errors.idp_realm_id && <div style={errorStyle}>{errors.idp_realm_id}</div>}
          {apiError?.realmError && <div style={errorStyle}>{apiError.realmError}</div>}
        </div>

        {/* Redirect URIs */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle}>Redirect URIs</label>
          {form.redirect_uris.map((uri, idx) => (
            <div key={idx} style={{ display: 'flex', gap: '.5rem', marginBottom: '.4rem' }}>
              <input
                style={{
                  ...inputStyle,
                  flex: 1,
                  borderColor: errors.redirect_uris && idx === 0 ? 'var(--border-error)' : 'var(--border-default)',
                }}
                value={uri}
                onChange={(e) => setRedirectUri(idx, e.target.value)}
                placeholder="https://app.example.com/callback"
              />
              {form.redirect_uris.length > 1 && (
                <Button variant="danger" size="sm" onClick={() => removeRedirectUri(idx)}>
                  Remove
                </Button>
              )}
            </div>
          ))}
          {errors.redirect_uris && <div style={errorStyle}>{errors.redirect_uris}</div>}
          <Button variant="secondary" size="sm" onClick={addRedirectUri}>
            + Add URI
          </Button>
        </div>

        {/* Realm config (collapsible) */}
        <div style={{ marginBottom: '1rem', border: '1px solid var(--border-default)', borderRadius: '6px' }}>
          <button
            type="button"
            onClick={() => setRealmOpen((v) => !v)}
            style={{
              width: '100%',
              textAlign: 'left',
              padding: '.65rem 1rem',
              background: 'var(--surface-page)',
              border: 'none',
              borderRadius: realmOpen ? '6px 6px 0 0' : '6px',
              cursor: 'pointer',
              fontWeight: 600,
              fontSize: '.87rem',
              color: 'var(--text-primary)',
            }}
          >
            {realmOpen ? '▾' : '▸'} Realm Config (optional)
          </button>
          {realmOpen && (
            <div style={{ padding: '1rem', borderTop: '1px solid var(--border-default)' }}>
              <div style={fieldGroupStyle}>
                <label style={labelStyle} htmlFor="realm_token_lifetime">
                  Default Token Lifetime (seconds)
                </label>
                <input
                  id="realm_token_lifetime"
                  type="number"
                  style={inputStyle}
                  value={form.realm_default_token_lifetime_seconds}
                  onChange={(e) => setField('realm_default_token_lifetime_seconds', e.target.value)}
                />
              </div>
              <div style={fieldGroupStyle}>
                <label style={labelStyle} htmlFor="realm_min_pw">
                  Minimum Password Length
                </label>
                <input
                  id="realm_min_pw"
                  type="number"
                  style={inputStyle}
                  value={form.realm_min_password_length}
                  onChange={(e) => setField('realm_min_password_length', e.target.value)}
                />
              </div>
              <div style={{ ...fieldGroupStyle, display: 'flex', gap: '1.5rem', alignItems: 'center' }}>
                <label style={{ display: 'flex', alignItems: 'center', gap: '.4rem', cursor: 'pointer', fontSize: '.87rem' }}>
                  <input
                    type="checkbox"
                    checked={form.realm_require_uppercase}
                    onChange={(e) => setField('realm_require_uppercase', e.target.checked)}
                  />
                  Require Uppercase
                </label>
                <label style={{ display: 'flex', alignItems: 'center', gap: '.4rem', cursor: 'pointer', fontSize: '.87rem' }}>
                  <input
                    type="checkbox"
                    checked={form.realm_require_digit}
                    onChange={(e) => setField('realm_require_digit', e.target.checked)}
                  />
                  Require Digit
                </label>
              </div>
              <div style={fieldGroupStyle}>
                <label style={labelStyle} htmlFor="realm_signing_alg">
                  Signing Key Algorithm
                </label>
                <input
                  id="realm_signing_alg"
                  style={inputStyle}
                  value={form.realm_signing_key_algorithm}
                  onChange={(e) => setField('realm_signing_key_algorithm', e.target.value)}
                  placeholder="RS256"
                />
              </div>
            </div>
          )}
        </div>

        {/* Client config (collapsible) */}
        <div style={{ marginBottom: '1.5rem', border: '1px solid var(--border-default)', borderRadius: '6px' }}>
          <button
            type="button"
            onClick={() => setClientOpen((v) => !v)}
            style={{
              width: '100%',
              textAlign: 'left',
              padding: '.65rem 1rem',
              background: 'var(--surface-page)',
              border: 'none',
              borderRadius: clientOpen ? '6px 6px 0 0' : '6px',
              cursor: 'pointer',
              fontWeight: 600,
              fontSize: '.87rem',
              color: 'var(--text-primary)',
            }}
          >
            {clientOpen ? '▾' : '▸'} Client Config (optional)
          </button>
          {clientOpen && (
            <div style={{ padding: '1rem', borderTop: '1px solid var(--border-default)' }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: '.4rem', cursor: 'pointer', fontSize: '.87rem' }}>
                <input
                  type="checkbox"
                  checked={form.client_service_account_enabled}
                  onChange={(e) => setField('client_service_account_enabled', e.target.checked)}
                />
                Service Account Enabled
              </label>
            </div>
          )}
        </div>

        <Button
          variant="primary"
          size="md"
          loading={submitting}
          onClick={() => formRef.current?.requestSubmit()}
        >
          {submitting ? 'Submitting…' : 'Register Tenant'}
        </Button>
      </form>
    </div>
  )
}
