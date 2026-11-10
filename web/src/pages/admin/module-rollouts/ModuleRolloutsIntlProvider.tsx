/** ModuleRolloutsIntlProvider -- T-1660. Page-local `<IntlProvider>` of the module rollout screen (as UsersImportIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { moduleRolloutsMessages } from './moduleRolloutsMessages'

export function ModuleRolloutsIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={moduleRolloutsMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
