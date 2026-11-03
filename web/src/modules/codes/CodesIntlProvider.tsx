/** CodesIntlProvider — GH 3606 / REQ-672. A local IntlProvider for the codes screen (same pattern as LocationsIntlProvider).
 *  `locale` is given by the screen harness; the app resolves it from the browser's languages. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { codesMessages, resolveUiLocale, type CodesUiLocale } from './codesMessages'

export function CodesIntlProvider({ children, locale }: { children: ReactNode; locale?: CodesUiLocale }) {
  const active = locale ?? resolveUiLocale()
  return (
    <IntlProvider locale={active} defaultLocale="en" messages={codesMessages[active]}>
      {children}
    </IntlProvider>
  )
}
