/** CatalogItemsIntlProvider — GH 3605 / REQ-673. A local IntlProvider for the catalog_items screen. The locale is
 *  the browser's unless the caller gives one (the screen harness does). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { catalogItemsMessages, resolveUiLocale, type CatalogItemsUiLocale } from './catalogItemsMessages'

export function CatalogItemsIntlProvider({ children, locale: given }: { children: ReactNode; locale?: CatalogItemsUiLocale }) {
  const locale = given ?? resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={catalogItemsMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
