/** createModuleIntlProvider — the one IntlProvider body the module providers share (core extraction S6).
 *
 *  Given a module's message catalog, returns a provider component: `locale` (the screen harness gives one) wins,
 *  else the UI-language store's (`useUiLocale`); `en` is the default locale. The module keeps its own provider
 *  name and message file and imports only from `@/i18n`. */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useUiLocale, type UiLocale } from '@/i18n/uiLocaleStore'

export function createModuleIntlProvider(messages: Record<UiLocale, Record<string, string>>) {
  return function ModuleIntlProvider({ children, locale }: { children: ReactNode; locale?: UiLocale }) {
    const stored = useUiLocale()
    const active = locale ?? stored
    return (
      <IntlProvider locale={active} defaultLocale="en" messages={messages[active]}>
        {children}
      </IntlProvider>
    )
  }
}
