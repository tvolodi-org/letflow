/** AuditIntlProvider -- T-1557. Page-local `<IntlProvider>` for the Audit log, in the style of ImportIntlProvider. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from './uiLocaleStore'
import { auditMessages } from './auditMessages'

export function AuditIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={auditMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
