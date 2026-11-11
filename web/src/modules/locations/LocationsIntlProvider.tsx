/** LocationsIntlProvider — GH 3607 / REQ-671. A local IntlProvider for the locations screens, made by the shared `createModuleIntlProvider` (core extraction S6).
 *  `locale` is given by the screen harness; the app takes it from the UI-language store. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { locationsMessages } from './locationsMessages'

export const LocationsIntlProvider = createModuleIntlProvider(locationsMessages)
