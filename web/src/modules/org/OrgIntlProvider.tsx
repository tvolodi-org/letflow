/** OrgIntlProvider — GH 3609 / REQ-669. A local IntlProvider for the org screens (same pattern as ExamIntlProvider).
 *  The language comes from the UI-language store (`?lang`, saved choice, browser); the screens follow a switch at once. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { orgMessages, type OrgUiLocale } from './orgMessages'

/** The language the org screens render in. */
export function useOrgLocale(): OrgUiLocale {
  return useUiLocale()
}

export function OrgIntlProvider({ children }: { children: ReactNode }) {
  const locale = useOrgLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={orgMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
