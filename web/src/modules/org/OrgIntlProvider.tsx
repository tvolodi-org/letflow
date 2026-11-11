/** OrgIntlProvider — GH 3609 / REQ-669. A local IntlProvider for the org screens, made by the shared
 *  `createModuleIntlProvider` (core extraction S6). The language comes from the UI-language store (`?lang`, saved
 *  choice, browser); the screens follow a switch at once. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { orgMessages, type OrgUiLocale } from './orgMessages'

/** The language the org screens render in. */
export function useOrgLocale(): OrgUiLocale {
  return useUiLocale()
}

export const OrgIntlProvider = createModuleIntlProvider(orgMessages)
