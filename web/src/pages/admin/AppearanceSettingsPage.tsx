/** AppearanceSettingsPage — REQ-383
 *
 * Lets a tenant admin (platform-admin role, same guard as EditTenantPage.tsx)
 * submit a new `brand_colors.primary` value through
 * `PATCH /api/v1/tenant/settings` (REQ-382). On success: shows a
 * confirmation and applies the colour immediately, same screen, no reload
 * (calls `applyBrandingColors` directly — the exact function
 * `BrandingProvider.tsx` calls on initial load). On a contrast-refused
 * (422) submission: shows the endpoint's plain-language message and
 * leaves the previously-applied colour in effect (the failure path never
 * touches `appliedColor`/never calls `applyBrandingColors`).
 *
 * See lib/letflow/design/req383-appearance-settings-screen.md for the full
 * design and the AC4 "no out-of-scope-key path" closure argument this
 * component's shape (exactly one input, one mutation call site, one
 * literal request-body object) satisfies by construction.
 */

import { useRef, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useMutation } from '@tanstack/react-query'
import { P, useAccess, AccessPending } from '@/auth/access'
import { tenantSettingsApi } from '@/api/tenantSettings'
import { applyBrandingColors } from '@/theming/applyBranding'
import { BRAND_COLOR_CSS_PROPERTY } from '@/theming/brandingDefaults'
import { Button } from '@/components/ui/Button'
import { useToast } from '@/hooks/useToast'
import type { ApiError } from '@/types/api'

// ── Styles (mirrors EditTenantPage.tsx's conventions) ───────────────────────

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

const swatchStyle: React.CSSProperties = {
  display: 'inline-block',
  width: '2.5rem',
  height: '2.5rem',
  borderRadius: 'var(--radius-sm)',
  border: '1px solid var(--border-default)',
  verticalAlign: 'middle',
  marginLeft: '.75rem',
}

// ── Component ──────────────────────────────────────────────────────────────

/** Reads the SAME custom property applyBrandingColors/BrandingProvider
 * write to (never a second hardcoded '--color-brand-600' literal) — see
 * design doc §3.1/OQ-1. Returns '' if unset (tokens.css's own default is
 * then in effect, which is a legal state). */
function readCurrentAppliedPrimary(): string {
  return getComputedStyle(document.documentElement)
    .getPropertyValue(BRAND_COLOR_CSS_PROPERTY.primary)
    .trim()
}

export default function AppearanceSettingsPage() {
  const access = useAccess()
  const toast = useToast()
  const formRef = useRef<HTMLFormElement>(null)

  const [appliedColor, setAppliedColor] = useState<string>(() => readCurrentAppliedPrimary())
  // No hardcoded colour literal here (CMP-UI-06/guard): if tokens.css's own
  // cascade default is somehow unset, the native <input type="color"> falls
  // back to its own browser default rather than this component asserting one.
  const [draftColor, setDraftColor] = useState<string>(() => readCurrentAppliedPrimary())
  const [errorMessage, setErrorMessage] = useState<string | null>(null)
  const [confirmationVisible, setConfirmationVisible] = useState(false)

  const mutation = useMutation({
    mutationFn: (primary: string) => tenantSettingsApi.patchBrandColorPrimary(primary),
    onSuccess: (_data, primary) => {
      applyBrandingColors({ primary })
      setAppliedColor(primary)
      setErrorMessage(null)
      setConfirmationVisible(true)
      toast.success('Appearance settings saved.')
    },
    onError: (err: unknown) => {
      const apiErr = err as ApiError
      const detail = apiErr.details?.['detail']
      setConfirmationVisible(false)
      setErrorMessage(typeof detail === 'string' ? detail : apiErr.message)
      // Deliberately does NOT call applyBrandingColors and does NOT touch
      // appliedColor -- the DOM custom property was never written to for
      // this failed request, so the previously-applied colour remains in
      // effect purely because nothing overwrote it (design §3.4/§4).
    },
  })

  // Role guard — after all hooks, matches EditTenantPage.tsx.
  if (!access.isReady) return <AccessPending access={access} />
  if (!access.can(P.TenantSettingsManage)) {
    return <Navigate to="/instances" replace />
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setConfirmationVisible(false)
    mutation.mutate(draftColor)
  }

  return (
    <div data-testid="appearance-settings-page" style={{ padding: '1.5rem', maxWidth: '640px' }}>
      <h2 style={{ margin: '0 0 1.25rem' }}>Appearance</h2>

      {confirmationVisible && (
        <div
          role="alert"
          data-testid="appearance-settings-confirmation"
          style={{
            marginBottom: '1rem',
            padding: '.75rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-success-border, var(--border-default))',
            background: 'var(--color-success-tint, var(--surface-page))',
            color: 'var(--color-success-dark, var(--text-primary))',
            fontSize: '.88rem',
          }}
        >
          Appearance settings saved. The new colour is applied on this screen.
        </div>
      )}

      {errorMessage && (
        <div
          role="alert"
          data-testid="appearance-settings-error"
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
          {errorMessage}
        </div>
      )}

      <form ref={formRef} data-testid="appearance-settings-form" onSubmit={handleSubmit} noValidate>
        <div style={fieldGroupStyle}>
          <label style={labelStyle} htmlFor="brand-color-primary">Primary brand colour</label>
          <input
            id="brand-color-primary"
            type="color"
            data-testid="appearance-settings-primary-color-input"
            value={draftColor}
            onChange={(e) => setDraftColor(e.target.value)}
          />
          <span
            data-testid="appearance-settings-preview-swatch"
            style={{ ...swatchStyle, background: appliedColor || 'var(--color-brand-600)' }}
            title="Currently applied colour"
          />
        </div>

        <div style={{ display: 'flex', gap: '.5rem', marginTop: '1.25rem', alignItems: 'center' }}>
          <span data-testid="appearance-settings-save">
            <Button
              variant="primary"
              size="md"
              loading={mutation.isPending}
              onClick={() => formRef.current?.requestSubmit()}
            >
              {mutation.isPending ? 'Saving…' : 'Save'}
            </Button>
          </span>
        </div>
      </form>
    </div>
  )
}
