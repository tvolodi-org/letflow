/** LocationsIntlProvider — GH 3607 / REQ-671. A local IntlProvider for the locations screens (same pattern as OrgIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { locationsMessages, resolveUiLocale } from './locationsMessages'

export function LocationsIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={locationsMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
