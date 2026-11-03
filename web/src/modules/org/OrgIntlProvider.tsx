/** OrgIntlProvider — GH 3609 / REQ-669. A local IntlProvider for the org screens (same pattern as ExamIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { orgMessages, resolveUiLocale } from './orgMessages'

export function OrgIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={orgMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
