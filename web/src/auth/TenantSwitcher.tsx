/** REQ-384 §6.1 — in-app tenant switcher, rendered inside AppShell's sidebar.
 *
 *  Render-gated on `memberships.length > 1`: a single-membership user sees
 *  no control at all (AC1). Selecting a membership calls `switchTenant`
 *  (§5.3) and shows a transition state for its duration; on
 *  `'interaction_required'`, renders an explicit, user-initiated sign-in
 *  affordance (§5.2's fallback); on `'error'`, a plain-language retry
 *  message — the current tenant's session is left untouched either way,
 *  since `switchTenant`'s cache-clear only runs after a successful silent
 *  switch.
 */
import { useState } from 'react'
import { useAuth } from './AuthContext'
import { useMemberships } from '@/hooks/useMemberships'
import { getOrCreateManagerForTenant } from './tenantOidcRegistry'
import { buildRedirectArgs } from './oidcRedirectArgs'

export function TenantSwitcher(): JSX.Element | null {
  const { session, switchTenant } = useAuth()
  const { data: memberships } = useMemberships()
  const [open, setOpen] = useState(false)
  const [interactionRequiredSlug, setInteractionRequiredSlug] = useState<string | null>(null)
  const [errorSlug, setErrorSlug] = useState<string | null>(null)
  const [pending, setPending] = useState(false)

  if (!memberships || memberships.length <= 1) return null

  const otherMemberships = memberships.filter((m) => m.tenant_id !== session?.tenant_id)

  const onSelect = async (targetSlug: string) => {
    if (pending) return
    setPending(true)
    setInteractionRequiredSlug(null)
    setErrorSlug(null)
    setOpen(false)
    try {
      const outcome = await switchTenant(targetSlug)
      if (outcome === 'interaction_required') setInteractionRequiredSlug(targetSlug)
      else if (outcome === 'error') setErrorSlug(targetSlug)
    } finally {
      setPending(false)
    }
  }

  const onSignInToTenant = async (targetSlug: string) => {
    const manager = await getOrCreateManagerForTenant(targetSlug)
    void manager.signinRedirect(buildRedirectArgs())
  }

  return (
    <div data-testid="tenant-switcher" style={{ padding: '0 1.25rem', marginBottom: '.5rem', position: 'relative' }}>
      <button
        data-testid="tenant-switcher-trigger"
        onClick={() => setOpen((o) => !o)}
        disabled={pending}
        style={{
          width: '100%',
          textAlign: 'left',
          background: 'none',
          border: '1px solid var(--color-sidebar-active)',
          borderRadius: 'var(--radius-sm)',
          color: 'var(--on-night)',
          padding: '.35rem .6rem',
          fontSize: '.75rem',
          cursor: pending ? 'default' : 'pointer',
          opacity: pending ? 0.6 : 1,
        }}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        Switch tenant
      </button>

      {open && (
        <ul
          data-testid="tenant-switcher-menu"
          role="listbox"
          style={{
            listStyle: 'none',
            margin: '.25rem 0 0',
            padding: '.25rem',
            position: 'absolute',
            left: '1.25rem',
            right: '1.25rem',
            background: 'var(--surface-card)',
            border: '1px solid var(--border-default)',
            borderRadius: 'var(--radius-sm)',
            zIndex: 40,
          }}
        >
          {otherMemberships.map((m) => (
            <li key={m.tenant_id}>
              <button
                data-testid={`tenant-switcher-option-${m.tenant_slug}`}
                onClick={() => void onSelect(m.tenant_slug)}
                disabled={pending}
                style={{
                  width: '100%',
                  textAlign: 'left',
                  background: 'none',
                  border: 'none',
                  padding: '.4rem .5rem',
                  fontSize: '.85rem',
                  cursor: pending ? 'default' : 'pointer',
                  color: 'var(--text-primary)',
                  opacity: pending ? 0.6 : 1,
                }}
              >
                {m.display_label ?? m.tenant_display_name}
              </button>
            </li>
          ))}
        </ul>
      )}

      {interactionRequiredSlug && (
        <div data-testid="tenant-switcher-interaction-required" style={{ marginTop: '.4rem', fontSize: '.75rem' }}>
          <span style={{ color: 'var(--text-secondary)' }}>Sign-in needed to switch. </span>
          <button
            data-testid="tenant-switcher-sign-in"
            onClick={() => void onSignInToTenant(interactionRequiredSlug)}
            style={{ background: 'none', border: 'none', color: 'var(--interactive-primary)', cursor: 'pointer', padding: 0 }}
          >
            Sign in to {interactionRequiredSlug}
          </button>
        </div>
      )}

      {errorSlug && (
        <div data-testid="tenant-switcher-error" style={{ marginTop: '.4rem', fontSize: '.75rem', color: 'var(--color-error-dark)' }}>
          Could not switch tenant.{' '}
          <button
            data-testid="tenant-switcher-retry"
            onClick={() => void onSelect(errorSlug)}
            disabled={pending}
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--interactive-primary)',
              cursor: pending ? 'default' : 'pointer',
              padding: 0,
              textDecoration: 'underline',
              opacity: pending ? 0.6 : 1,
            }}
          >
            Retry
          </button>
        </div>
      )}
    </div>
  )
}
