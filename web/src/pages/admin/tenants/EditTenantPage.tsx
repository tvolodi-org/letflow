/** EditTenantPage — TM-03
 *
 * Allows platform-admin role to edit mutable fields of an existing tenant:
 * display_name, hostname, redirect_uris. Slug and idp_realm_id are read-only.
 * On save: PATCH /api/v1/tenants/:slug with only changed fields.
 * On success: toast message + navigate to /admin/tenants.
 * 422 → error banner (ImmutableFieldUpdate)
 * 502 → warning banner (Keycloak sync failure)
 */

import { useRef, useState, useEffect } from 'react'
import { Navigate, useNavigate, useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccess, AccessPending } from '@/auth/access'
import { tenantsApi } from '@/api/tenants'
import { queryKeys } from '@/api/queryKeys'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { useToast } from '@/hooks/useToast'
import { classifyError, type RendererState } from '@/utils/classifyError'

// ── Styles ─────────────────────────────────────────────────────────────────────

const inputStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  padding: '.45rem .65rem',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 'var(--text-base)',
  boxSizing: 'border-box',
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

const readOnlyValueStyle: React.CSSProperties = {
  display: 'block',
  padding: '.45rem .65rem',
  background: 'var(--surface-page)',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 'var(--text-base)',
  color: 'var(--text-secondary)',
  fontFamily: 'var(--font-mono)',
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function EditTenantPage() {
  const access = useAccess()
  const navigate = useNavigate()
  const { slug } = useParams<{ slug: string }>()
  const qc = useQueryClient()
  const toast = useToast()
  const formRef = useRef<HTMLFormElement>(null)

  const [displayName, setDisplayName] = useState('')
  const [hostname, setHostname] = useState('')
  const [redirectUris, setRedirectUris] = useState<string[]>([''])
  const [initialized, setInitialized] = useState(false)
  const [errorBanner, setErrorBanner] = useState<string | null>(null)
  const [warningBanner, setWarningBanner] = useState<string | null>(null)

  const tenantQuery = useQuery({
    queryKey: queryKeys.admin.tenantDetail(slug ?? ''),
    queryFn: () => tenantsApi.getBySlug(slug ?? ''),
    enabled: Boolean(slug),
  })

  // Initialize form from fetched data (only once)
  useEffect(() => {
    if (tenantQuery.data && !initialized) {
      setDisplayName(tenantQuery.data.display_name)
      setHostname(tenantQuery.data.hostname ?? '')
      setRedirectUris(
        (tenantQuery.data.redirect_uris && tenantQuery.data.redirect_uris.length > 0)
          ? tenantQuery.data.redirect_uris
          : [''],
      )
      setInitialized(true)
    }
  }, [tenantQuery.data, initialized])

  const patchTenant = useMutation({
    mutationFn: (body: Partial<{ display_name: string; hostname: string; redirect_uris: string[] }>) =>
      tenantsApi.patch(slug ?? '', body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.tenants() })
      qc.invalidateQueries({ queryKey: queryKeys.admin.tenantDetail(slug ?? '') })
      toast.success('Saved')
      setTimeout(() => navigate('/admin/tenants'), 800)
    },
    onError: (err: unknown) => {
      const status = (err as { status?: number })?.status
      if (status === 422) {
        setErrorBanner('Cannot update immutable fields. Only display_name, hostname, and redirect_uris may be changed.')
      } else if (status === 502) {
        setWarningBanner('Tenant saved locally, but identity provider sync failed. Check Keycloak connectivity.')
      } else {
        setErrorBanner('An unexpected error occurred. Please try again.')
      }
    },
  })

  // Role guard — after all hooks
  if (!access.isReady) return <AccessPending access={access} />
  if (!access.canManageTenants) {
    return <Navigate to="/instances" replace />
  }

  if (!slug) {
    return <p style={{ padding: '1.5rem', color: 'var(--color-error)' }}>Invalid tenant slug.</p>
  }

  const rendererState: RendererState = tenantQuery.isLoading ? 'loading' : tenantQuery.isError ? classifyError(tenantQuery.error) : 'success'
  const original = tenantQuery.data

  function setRedirectUri(index: number, value: string) {
    const updated = [...redirectUris]
    updated[index] = value
    setRedirectUris(updated)
  }

  function addRedirectUri() {
    setRedirectUris((prev) => [...prev, ''])
  }

  function removeRedirectUri(index: number) {
    const updated = redirectUris.filter((_, i) => i !== index)
    setRedirectUris(updated.length === 0 ? [''] : updated)
  }

  function handleSave(e: React.FormEvent) {
    e.preventDefault()
    if (!original) return
    setErrorBanner(null)
    setWarningBanner(null)

    // Build diff — only changed fields
    const body: Partial<{ display_name: string; hostname: string; redirect_uris: string[] }> = {}
    if (displayName.trim() !== original.display_name) {
      body.display_name = displayName.trim()
    }
    if (hostname.trim() !== (original.hostname ?? '')) {
      body.hostname = hostname.trim()
    }
    const cleanedUris = redirectUris.map((u) => u.trim()).filter((u) => u.length > 0)
    const originalUris = (original.redirect_uris ?? []).slice().sort().join('\n')
    if (cleanedUris.slice().sort().join('\n') !== originalUris) {
      body.redirect_uris = cleanedUris
    }

    if (Object.keys(body).length === 0) {
      toast.warning('No changes to save.')
      return
    }

    patchTenant.mutate(body)
  }

  return (
    <div data-testid="edit-tenant-page" style={{ padding: '1.5rem', maxWidth: '640px' }}>
      <span style={{ display: 'inline-block', marginBottom: '1rem' }}>
        <Button variant="secondary" size="sm" onClick={() => navigate('/admin/tenants')}>
          ← Back to tenants
        </Button>
      </span>

      <h2 style={{ margin: '0 0 1.25rem' }}>Edit Tenant</h2>

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void tenantQuery.refetch() }}
        columns={[{ widthPercent: 30 }, { widthPercent: 70 }]}
      >
      {original && (<>

      {errorBanner && (
        <div
          role="alert"
          data-testid="edit-tenant-error"
          style={{
            marginBottom: '1rem',
            padding: '.75rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-error-border)',
            background: 'var(--color-error-tint)',
            color: 'var(--color-error-dark)',
            fontSize: '.88rem',
          }}
        >
          {errorBanner}
        </div>
      )}

      {warningBanner && (
        <div
          role="alert"
          data-testid="edit-tenant-warning"
          style={{
            marginBottom: '1rem',
            padding: '.75rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-warning-border)',
            background: 'var(--color-warning-tint)',
            color: 'var(--color-warning-text)',
            fontSize: '.88rem',
          }}
        >
          {warningBanner}
        </div>
      )}

      {/* Read-only fields */}
      <div style={fieldGroupStyle}>
        <label style={labelStyle}>Slug</label>
        <span data-testid="edit-tenant-slug" style={readOnlyValueStyle}>{original.slug}</span>
      </div>

      <div style={fieldGroupStyle}>
        <label style={labelStyle}>IDP Realm ID</label>
        <span data-testid="edit-tenant-realm" style={readOnlyValueStyle}>{original.idp_realm_id}</span>
      </div>

      <form ref={formRef} onSubmit={(e) => { void handleSave(e) }} noValidate>
        {/* display_name */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="display_name">Display name</label>
          <input
            id="display_name"
            data-testid="edit-tenant-display-name"
            style={inputStyle}
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
          />
        </div>

        {/* hostname */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="hostname">Hostname</label>
          <input
            id="hostname"
            data-testid="edit-tenant-hostname"
            style={inputStyle}
            value={hostname}
            onChange={(e) => setHostname(e.target.value)}
            placeholder="tenant.example.com"
          />
        </div>

        {/* redirect_uris — multi-value input (same pattern as RegisterTenantPage) */}
        <div style={fieldGroupStyle}>
          <label style={labelStyle}>Redirect URIs</label>
          {redirectUris.map((uri, idx) => (
            <div key={idx} style={{ display: 'flex', gap: '.5rem', marginBottom: '.4rem' }}>
              <input
                data-testid={`edit-tenant-redirect-uri-${idx}`}
                style={{ ...inputStyle, flex: 1 }}
                value={uri}
                onChange={(e) => setRedirectUri(idx, e.target.value)}
                placeholder="https://app.example.com/callback"
              />
              {redirectUris.length > 1 && (
                <span data-testid={`edit-tenant-remove-uri-${idx}`}>
                  <Button variant="danger" size="sm" onClick={() => removeRedirectUri(idx)}>
                    Remove
                  </Button>
                </span>
              )}
            </div>
          ))}
          <Button variant="secondary" size="sm" onClick={addRedirectUri}>
            + Add URI
          </Button>
        </div>

        <div style={{ display: 'flex', gap: '.5rem', marginTop: '1.25rem', alignItems: 'center' }}>
          <span data-testid="edit-tenant-save">
            <Button
              variant="primary"
              size="md"
              loading={patchTenant.isPending}
              onClick={() => formRef.current?.requestSubmit()}
            >
              {patchTenant.isPending ? 'Saving…' : 'Save'}
            </Button>
          </span>
          <Button variant="secondary" size="md" onClick={() => navigate('/admin/tenants')}>
            Cancel
          </Button>
        </div>
      </form>
      </>)}
      </QueryStateBoundary>
    </div>
  )
}
