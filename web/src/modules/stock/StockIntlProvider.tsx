/** StockIntlProvider — GH 3767 / REQ-724. A local IntlProvider for the stock screens (same pattern as CodesIntlProvider). */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { stockMessages, type StockUiLocale } from './stockMessages'

export function StockIntlProvider({ children, locale }: { children: ReactNode; locale?: StockUiLocale }) {
  const stored = useUiLocale()
  const active = locale ?? stored
  return (
    <IntlProvider locale={active} defaultLocale="en" messages={stockMessages[active]}>
      {children}
    </IntlProvider>
  )
}
