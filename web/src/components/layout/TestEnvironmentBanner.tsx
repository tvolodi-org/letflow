import type React from 'react'
import { useTenantContext } from '@/auth/useTenantContext'

export function TestEnvironmentBanner(): React.ReactElement | null {
  const { tenantType } = useTenantContext()

  if (tenantType !== 'test') {
    return null
  }

  return (
    <div
      role="banner"
      aria-label="Test environment indicator"
      data-testid="test-environment-banner"
      style={{
        position: 'sticky',
        top: 0,
        zIndex: 200,
        background: 'var(--color-warning-banner)',
        color: 'var(--color-warning-text)',
        borderBottom: '1px solid var(--color-warning)',
        padding: '.5rem 1.25rem',
        display: 'flex',
        alignItems: 'center',
        gap: '.75rem',
        fontSize: '.875rem',
      }}
    >
      <span style={{ fontWeight: 700 }}>TEST ENVIRONMENT</span>
    </div>
  )
}
