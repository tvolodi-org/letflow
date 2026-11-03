/** CatalogItemsIntlProvider — GH 3605 / REQ-673. A local IntlProvider for the catalog_items screen. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { catalogItemsMessages, resolveUiLocale } from './catalogItemsMessages'

export function CatalogItemsIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={catalogItemsMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
