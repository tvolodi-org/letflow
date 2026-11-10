/** UsersImportIntlProvider -- T-1633. Page-local `<IntlProvider>` of the users import screen (as ImportIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { usersImportMessages } from './usersImportMessages'

export function UsersImportIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={usersImportMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
