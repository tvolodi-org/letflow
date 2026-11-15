/** ProblemReportsIntlProvider -- T-2007. Page-local `<IntlProvider>` of the problem reports inbox screen (as UsersImportIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { problemReportsMessages } from './problemReportsMessages'

export function ProblemReportsIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={problemReportsMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
