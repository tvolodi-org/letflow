import type React from 'react'
import { useTenantContext } from '@/auth/useTenantContext'
import { useUiLocale, type UiLocale } from '@/i18n/uiLocaleStore'

const TEXT: Record<UiLocale, { label: string; aria: string }> = {
  en: { label: 'TEST ENVIRONMENT', aria: 'Test environment indicator' },
  ru: { label: 'ТЕСТОВАЯ СРЕДА', aria: 'Индикатор тестовой среды' },
  kk: { label: 'СЫНАҚ ОРТАСЫ', aria: 'Сынақ ортасының белгісі' },
}

export function TestEnvironmentBanner(): React.ReactElement | null {
  const { tenantType } = useTenantContext()
  const locale = useUiLocale()

  if (tenantType !== 'test') {
    return null
  }

  return (
    <div
      role="banner"
      aria-label={TEXT[locale].aria}
      data-testid="test-environment-banner"
      style={{
        position: 'sticky',
        top: 'var(--topbar-height)',
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
      <span style={{ fontWeight: 700 }}>{TEXT[locale].label}</span>
    </div>
  )
}
