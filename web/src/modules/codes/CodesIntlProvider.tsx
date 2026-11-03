/** CodesIntlProvider — GH 3606 / REQ-672. A local IntlProvider for the codes screen (same pattern as LocationsIntlProvider).
 *  `locale` is given by the screen harness; the app takes it from the UI-language store. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { codesMessages, type CodesUiLocale } from './codesMessages'

export function CodesIntlProvider({ children, locale }: { children: ReactNode; locale?: CodesUiLocale }) {
  const stored = useUiLocale()
  const active = locale ?? stored
  return (
    <IntlProvider locale={active} defaultLocale="en" messages={codesMessages[active]}>
      {children}
    </IntlProvider>
  )
}
