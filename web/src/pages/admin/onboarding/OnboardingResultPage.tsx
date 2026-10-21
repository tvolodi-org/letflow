/** OnboardingResultPage — ONB-UI-04
 *
 * Shows the outcome of POST /onboarding, which is synchronous: the backend
 * answers with the onboarding record (+ login / administrator / ignored_fields)
 * and has no failed or pending state.
 *
 * State restore priority:
 * 1. Router location.state.record (forward navigation from the register page)
 * 2. GET /api/v1/onboarding?hostname=<h> (page-reload restore via URL search param)
 * 3. "Could not restore" fallback (no state, no hostname, or 404)
 *
 * Role guard: redirects to /instances if session does not include platform-admin role.
 * All hooks are called before the early return per React rules.
 */

import { useEffect, useState } from 'react'
import { Navigate, useNavigate, useParams, useLocation, Link } from 'react-router-dom'
import { useAccess, AccessPending } from '@/auth/access'
import { Button } from '@/components/ui/Button'
import {
  bindRealm,
  fieldErrorConstraint,
  getOnboardingByHostname,
  OnboardingApiError,
  type OnboardingAdministratorState,
  type OnboardingRecord,
} from '@/api/onboarding'

// ── Types ──────────────────────────────────────────────────────────────────────

type ViewState =
  | { phase: 'loading' }
  | { phase: 'completed'; record: OnboardingRecord }
  | { phase: 'restore-failed' }

// ── Styles ─────────────────────────────────────────────────────────────────────

const tdLabelStyle: React.CSSProperties = {
  padding: '.45rem .75rem .45rem 0',
  fontWeight: 600,
  fontSize: '.87rem',
  color: 'var(--text-primary)',
  verticalAlign: 'top',
  whiteSpace: 'nowrap',
  width: '160px',
}

const tdValueStyle: React.CSSProperties = {
  padding: '.45rem 0',
  fontSize: '.87rem',
  color: 'var(--text-primary)',
  wordBreak: 'break-all',
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function OnboardingResultPage() {
  const access = useAccess()
  const { onboardingId } = useParams<{ onboardingId: string }>()
  const navigate = useNavigate()
  const location = useLocation()

  const locationState = location.state as { record?: OnboardingRecord } | null

  const [view, setView] = useState<ViewState>(() => {
    if (locationState?.record) {
      return { phase: 'completed', record: locationState.record }
    }
    return { phase: 'loading' }
  })

  useEffect(() => {
    // If we already have a result from router state, skip the fetch
    if (locationState?.record) return

    const params = new URLSearchParams(location.search)
    const hostname = params.get('hostname')

    if (!hostname) {
      setView({ phase: 'restore-failed' })
      return
    }

    let cancelled = false

    getOnboardingByHostname(hostname)
      .then((record) => {
        if (!cancelled) {
          setView({ phase: 'completed', record })
        }
      })
      .catch(() => {
        if (!cancelled) {
          setView({ phase: 'restore-failed' })
        }
      })

    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Role guard — after all hooks
  if (!access.isReady) return <AccessPending access={access} />
  if (!access.canManageTenants) {
    return <Navigate to="/instances" replace />
  }

  // ── Render ───────────────────────────────────────────────────────────────────

  if (view.phase === 'loading') {
    return (
      <div style={{ padding: '2rem', color: 'var(--text-secondary)' }}>
        Restoring onboarding state…
      </div>
    )
  }

  if (view.phase === 'restore-failed') {
    return (
      <div style={{ padding: '2rem', maxWidth: '520px' }}>
        <h2 style={{ margin: '0 0 1rem 0' }}>Could not restore onboarding state</h2>
        <p style={{ color: 'var(--text-secondary)', marginBottom: '1.5rem' }}>
          The onboarding record for this page could not be retrieved. The URL may be invalid.
        </p>
        {/* Navigational CTA styled as a button -- kept as Link (not Button, which
            has no href/anchor semantics) so browser features (open-in-new-tab,
            middle-click) keep working. */}
        <Link
          to="/admin/onboarding/new"
          style={{
            display: 'inline-block',
            padding: '.5rem 1.2rem',
            background: 'var(--interactive-primary)',
            color: 'var(--text-inverse)',
            textDecoration: 'none',
            borderRadius: 'var(--radius-sm)',
            fontWeight: 600,
            fontSize: '.9rem',
          }}
        >
          Start over
        </Link>
      </div>
    )
  }

  // phase === 'completed'
  return (
    <CompletedView
      record={view.record}
      fallbackId={onboardingId}
      onBack={() => navigate('/admin/users')}
      onRecordChange={(next) => setView({ phase: 'completed', record: next })}
    />
  )
}

// ── Completed view (ISS-1030) ──────────────────────────────────────────────────
// Every string that came from the server (administrator values, ignored field
// names, messages, next steps) is rendered as a React text node, never as HTML.

const REALM_ID_FORMAT = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

const sectionTitleStyle: React.CSSProperties = {
  margin: '0 0 .5rem 0',
  fontSize: '.95rem',
  color: 'var(--text-primary)',
}

const noteStyle: React.CSSProperties = {
  margin: '0 0 .5rem 0',
  fontSize: '.87rem',
  color: 'var(--text-secondary)',
}

// Fixed client-side headline per administrator state; the server's own message
// and steps are rendered below it as plain text.
const ADMIN_STATE_HEADLINE: Record<OnboardingAdministratorState, string> = {
  none: 'No administrator set up',
  pending: 'Administrator pending: becomes active at first sign-in',
  not_stored: 'Administrator NOT stored',
  not_provisioned: 'Administrator details not used',
}

function bindErrorMessage(err: unknown): string {
  if (!(err instanceof OnboardingApiError)) {
    return 'An unexpected error occurred. Please try again.'
  }
  switch (err.httpStatus) {
    case 404:
      return 'This onboarding record was not found.'
    case 409: {
      const title = err.body['title']
      return typeof title === 'string' && title ? title : 'The realm could not be bound (conflict).'
    }
    case 422: {
      const c = fieldErrorConstraint(err.body, 'idp_realm_id')
      if (c === 'not_found') return 'The identity provider does not know this realm.'
      if (c === 'reserved') return 'This realm id is reserved.'
      if (c === 'format') return 'The realm id has an invalid format.'
      return 'The realm id was rejected.'
    }
    case 503:
      return 'The identity provider could not be reached. Try again in a moment.'
    default:
      return 'An unexpected error occurred. Please try again.'
  }
}

interface CompletedViewProps {
  record: OnboardingRecord
  fallbackId?: string
  onBack: () => void
  onRecordChange: (next: OnboardingRecord) => void
}

function CompletedView({ record, fallbackId, onBack, onRecordChange }: CompletedViewProps) {
  const [realmInput, setRealmInput] = useState('')
  const [bindError, setBindError] = useState<string | null>(null)
  const [binding, setBinding] = useState(false)

  const loginable = record.login?.loginable === true
  const admin = record.administrator
  const ignored = record.ignored_fields ?? []
  const onboardingId = record.id || fallbackId || ''

  async function handleBind() {
    const realm = realmInput.trim()
    if (!REALM_ID_FORMAT.test(realm)) {
      setBindError('Use 1–64 letters, digits, "_" or "-", starting with a letter or digit')
      return
    }
    setBinding(true)
    setBindError(null)
    try {
      const next = await bindRealm(onboardingId, realm)
      setRealmInput('')
      // The bind response carries no administrator / ignored_fields; keep the
      // ones from the create response so the notices stay visible.
      onRecordChange({
        ...next,
        ...(record.administrator ? { administrator: record.administrator } : {}),
        ...(record.ignored_fields ? { ignored_fields: record.ignored_fields } : {}),
      })
    } catch (err) {
      setBindError(bindErrorMessage(err))
    } finally {
      setBinding(false)
    }
  }

  return (
    <div style={{ padding: '2rem', maxWidth: '620px' }}>
      <div
        role="status"
        style={{
          marginBottom: '1.5rem',
          padding: '.75rem 1rem',
          borderRadius: 'var(--radius-sm)',
          border: `1px solid ${loginable ? 'var(--color-success-border)' : 'var(--color-error-border)'}`,
          background: loginable ? 'var(--color-success-tint)' : 'var(--color-error-tint)',
          color: loginable ? 'var(--color-success-dark)' : 'var(--color-error-dark)',
          fontWeight: 600,
        }}
      >
        {loginable
          ? 'Tenant created and ready to log into.'
          : 'Tenant created, but not yet loginable: no identity realm is bound.'}
      </div>

      <table style={{ borderCollapse: 'collapse', width: '100%', marginBottom: '1.5rem' }}>
        <tbody>
          <tr>
            <td style={tdLabelStyle}>Slug</td>
            <td style={tdValueStyle}>
              <code>{record.slug ?? fallbackId}</code>
            </td>
          </tr>
          {record.hostname && (
            <tr>
              <td style={tdLabelStyle}>Hostname</td>
              <td style={tdValueStyle}>{record.hostname}</td>
            </tr>
          )}
          <tr>
            <td style={tdLabelStyle}>Login</td>
            <td style={tdValueStyle}>
              {loginable ? (
                <>
                  Realm bound: <code>{record.login?.idp_realm_id}</code>
                </>
              ) : (
                'Not yet loginable'
              )}
            </td>
          </tr>
        </tbody>
      </table>

      {!loginable && record.login && record.login.next_steps.length > 0 && (
        <section aria-label="Login next steps" style={{ marginBottom: '1.5rem' }}>
          <h3 style={sectionTitleStyle}>Next steps to make this tenant loginable</h3>
          <ul style={{ margin: 0, paddingLeft: '1.2rem', fontSize: '.87rem' }}>
            {record.login.next_steps.map((step, i) => (
              <li key={i}>{step}</li>
            ))}
          </ul>
        </section>
      )}

      {admin && (
        <section aria-label="Administrator" style={{ marginBottom: '1.5rem' }}>
          <h3 style={sectionTitleStyle}>Administrator</h3>
          <p
            data-testid="administrator-state"
            style={{
              margin: '0 0 .5rem 0',
              fontSize: '.87rem',
              fontWeight: 600,
              color:
                admin.state === 'not_stored' || admin.state === 'none'
                  ? 'var(--color-error-dark)'
                  : 'var(--text-primary)',
            }}
          >
            {ADMIN_STATE_HEADLINE[admin.state] ?? 'Administrator status unknown'}
          </p>
          {admin.state === 'pending' && admin.grant_id && (
            <p style={noteStyle}>
              Grant ID: <code>{admin.grant_id}</code>
            </p>
          )}
          <p style={noteStyle}>{admin.message}</p>
          {admin.not_provisioned.length > 0 && (
            <>
              <p style={noteStyle}>Details you entered that were not used:</p>
              <ul style={{ margin: '0 0 .5rem 0', paddingLeft: '1.2rem', fontSize: '.87rem' }}>
                {admin.not_provisioned.map((f, i) => (
                  <li key={i}>
                    <code>{f.field}</code>
                    {f.value !== undefined && <>: {f.value}</>}
                  </li>
                ))}
              </ul>
            </>
          )}
          {admin.next_steps.length > 0 && (
            <ul style={{ margin: 0, paddingLeft: '1.2rem', fontSize: '.87rem' }}>
              {admin.next_steps.map((step, i) => (
                <li key={i}>{step}</li>
              ))}
            </ul>
          )}
        </section>
      )}

      {ignored.length > 0 && (
        <section aria-label="Ignored fields" style={{ marginBottom: '1.5rem' }}>
          <h3 style={sectionTitleStyle}>Fields not used by the server</h3>
          <p style={noteStyle}>The following request fields were received but not used:</p>
          <ul style={{ margin: 0, paddingLeft: '1.2rem', fontSize: '.87rem' }}>
            {ignored.map((name, i) => (
              <li key={i}>
                <code>{name}</code>
              </li>
            ))}
          </ul>
        </section>
      )}

      {!loginable && (
        <section aria-label="Bind realm" style={{ marginBottom: '1.5rem' }}>
          <h3 style={sectionTitleStyle}>Bind an identity realm</h3>
          <p style={noteStyle}>
            Once the realm exists, bind it here. A realm can be bound once and cannot be changed
            afterwards. The server checks the realm with the identity provider.
          </p>
          <label htmlFor="bind_realm_id" style={{ display: 'block', fontWeight: 600, fontSize: '.87rem', marginBottom: '.3rem' }}>
            Realm ID
          </label>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <input
              id="bind_realm_id"
              value={realmInput}
              onChange={(e) => {
                setRealmInput(e.target.value)
                setBindError(null)
              }}
              autoComplete="off"
              style={{
                flex: 1,
                padding: '.45rem .65rem',
                border: `1px solid ${bindError ? 'var(--border-error)' : 'var(--border-default)'}`,
                borderRadius: 'var(--radius-sm)',
                fontSize: 'var(--text-base)',
              }}
            />
            <Button
              variant="primary"
              size="md"
              loading={binding}
              disabled={realmInput.trim() === ''}
              onClick={() => { void handleBind() }}
            >
              Bind realm
            </Button>
          </div>
          {bindError && (
            <div role="alert" style={{ color: 'var(--color-error)', fontSize: '.8rem', marginTop: '.3rem' }}>
              {bindError}
            </div>
          )}
        </section>
      )}

      {loginable && record.slug && (
        // Navigational CTA to a per-tenant hostname outside the SPA's own
        // router -- kept as a plain <a>, not Button, for the same reason
        // as "Start over" above.
        <a
          href={`${window.location.origin}/?realm=${encodeURIComponent(record.slug)}`}
          style={{
            display: 'inline-block',
            marginBottom: '1rem',
            padding: '.5rem 1.2rem',
            background: 'var(--interactive-primary)',
            color: 'var(--text-inverse)',
            textDecoration: 'none',
            borderRadius: 'var(--radius-sm)',
            fontWeight: 600,
            fontSize: '.9rem',
          }}
        >
          Open {record.slug} workspace
        </a>
      )}

      <div>
        <Button variant="primary" size="md" onClick={onBack}>
          Back to Admin
        </Button>
      </div>
    </div>
  )
}
