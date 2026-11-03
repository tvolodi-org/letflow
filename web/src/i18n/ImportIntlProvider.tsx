/** ImportIntlProvider -- GH 3650 / REQ-675
 *
 *  Page-local `<IntlProvider>` for the master data import screen, in the style of LoginIntlProvider.tsx.
 *  Reuses `resolveUiLocale` from entitiesMessages.ts.
 */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from './uiLocaleStore'
import { importMessages } from './importMessages'

export function ImportIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={importMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
