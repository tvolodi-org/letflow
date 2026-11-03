/** CodesIntlProvider — GH 3606 / REQ-672. A local IntlProvider for the codes screen (same pattern as LocationsIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { codesMessages, resolveUiLocale } from './codesMessages'

export function CodesIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={codesMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
