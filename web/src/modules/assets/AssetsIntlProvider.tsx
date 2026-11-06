/** AssetsIntlProvider — T-1333 / C13. A local IntlProvider for the assets screens (same pattern as OrgIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { assetsMessages } from './assetsMessages'

export function AssetsIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={assetsMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
