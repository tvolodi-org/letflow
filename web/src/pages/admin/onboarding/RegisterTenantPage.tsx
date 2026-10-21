/** RegisterTenantPage — ONB-UI-02
 *
 * Collects onboarding inputs for a new tenant and submits to POST /api/v1/onboarding.
 * Role guard: redirects to /instances if session does not include platform-admin role.
 * On success navigates to OnboardingResultPage with the created record in router state.
 */

import { useState, useEffect, useRef } from 'react'
import { Navigate, useNavigate, useLocation } from 'react-router-dom'
import { useAccess, AccessPending } from '@/auth/access'
import { Button } from '@/components/ui/Button'
import {
  submitOnboarding,
  OnboardingApiError,
  fieldErrorConstraint,
  type OnboardingFormValues,
} from '@/api/onboarding'

// ── Types ──────────────────────────────────────────────────────────────────────

interface FormState {
  slug: string
  display_name: string
  admin_email: string
  hostname: string
  idp_realm_id: string
}

interface FormErrors {
  slug?: string
  display_name?: string
  admin_email?: string
  hostname?: string
  idp_realm_id?: string
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
  hostname: '',
  idp_realm_id: '',
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

  // ISS-1030: the admin e-mail is optional; a filled one must look like an address.
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

  return errors
}

// ── Error taxonomy banner message ──────────────────────────────────────────────

interface ApiErrorView {
  banner: string
  realmError?: string
  adminEmailError?: string
}

function resolveApiErrorMessage(
  err: OnboardingApiError,
): ApiErrorView {
  const { httpStatus, body } = err

  if (httpStatus === 409) {
    // The 409s from the onboarding endpoint (slug, hostname and realm conflicts, and a tenant that
    // is not active). Error.conflict/1 sets title to the fixed "Conflict" and carries the specific
    // reason in detail, so detail is read first (GH 2438). Title is only a fallback.
    const detail = body['detail'] as string | undefined
    const title = body['title'] as string | undefined
    return { banner: detail ?? title ?? 'A conflict was detected. Please check your inputs.' }
  }

  if (httpStatus === 422) {
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

// ── Component ──────────────────────────────────────────────────────────────────

export default function RegisterTenantPage() {
  const access = useAccess()
  const navigate = useNavigate()
  const location = useLocation()

  const prefill = (location.state as { prefill?: Partial<FormState> } | null)?.prefill

  // All hooks must be called before any early return
  const [form, setForm] = useState<FormState>(() =>
    prefill ? { ...EMPTY_FORM, ...prefill } : { ...EMPTY_FORM },
  )
  const [errors, setErrors] = useState<FormErrors>({})
  const [submitting, setSubmitting] = useState(false)
  const [apiError, setApiError] = useState<ApiErrorView | null>(null)
  const formRef = useRef<HTMLFormElement>(null)

  // Clear API error when form changes
  useEffect(() => {
    setApiError(null)
  }, [form])

  // Role guard — after all hooks
  if (!access.isReady) return <AccessPending access={access} />
  if (!access.canManageTenants) {
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
      hostname: form.hostname.trim(),
      idp_realm_id: form.idp_realm_id.trim(),
    }

    try {
      const created = await submitOnboarding(formValues)
      // The backend is synchronous: the 201 already carries the final record,
      // so go straight to the result page (no progress polling).
      navigate(
        `/admin/onboarding/${created.id}/result?hostname=${encodeURIComponent(formValues.hostname)}`,
        { state: { record: created, formValues } },
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
          The administrator e-mail is optional. The tenant cannot be logged into until a realm is
          bound.
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
            aria-describedby="admin_email_hint"
          />
          <div
            id="admin_email_hint"
            style={{ fontSize: '.8rem', color: 'var(--text-secondary)', marginTop: '.2rem' }}
          >
            Stored as a pending tenant administrator. The person becomes the active administrator at
            their first sign-in with this e-mail VERIFIED through the tenant&apos;s realm.
          </div>
          {errors.admin_email && <div style={errorStyle}>{errors.admin_email}</div>}
          {apiError?.adminEmailError && <div style={errorStyle}>{apiError.adminEmailError}</div>}
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

        {/* ISS-1093 / GH 2463: realm and client are not collected here (ADR 0044 Phase 1). */}
        <p
          data-testid="realm-client-infra-note"
          style={{ margin: '0 0 1.5rem', fontSize: '.87rem', color: 'var(--text-secondary)' }}
        >
          The realm and the client for this tenant are created by infra (ADR 0044 Phase 1).
        </p>

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
