/** OrgIntlProvider — GH 3609 / REQ-669. A local IntlProvider for the org screens (same pattern as ExamIntlProvider).
 *  The language comes from the browser; `OrgLocaleContext` overrides it (the screen harness, S1). */
import { createContext, useContext, type ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { orgMessages, resolveUiLocale, type OrgUiLocale } from './orgMessages'

export const OrgLocaleContext = createContext<OrgUiLocale | null>(null)

/** The language the org screens render in. */
export function useOrgLocale(): OrgUiLocale {
  const forced = useContext(OrgLocaleContext)
  return forced ?? resolveUiLocale()
}

export function OrgIntlProvider({ children }: { children: ReactNode }) {
  const locale = useOrgLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={orgMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
