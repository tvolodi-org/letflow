/** SignupIntlProvider -- T-2748
 *
 *  Page-local `<IntlProvider>` for the public sign-up pages, in the style of
 *  EntitiesIntlProvider.tsx (no app-wide provider exists). Reuses
 *  `resolveUiLocale` from entitiesMessages.ts.
 */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from './uiLocaleStore'
import { signupMessages } from './signupMessages'

export function SignupIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={signupMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
