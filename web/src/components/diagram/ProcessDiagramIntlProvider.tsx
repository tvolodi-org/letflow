/** ProcessDiagramIntlProvider — T-1520. Page-local `<IntlProvider>` for the process diagram and the definition
 *  page's Diagram | Editor switch, in the style of ImportIntlProvider. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'

export function ProcessDiagramIntlProvider({ children }: { children: ReactNode }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={processDiagramMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
