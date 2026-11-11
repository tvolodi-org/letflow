/** AssetsIntlProvider — T-1333 / C13. A local IntlProvider for the assets screens, made by the shared `createModuleIntlProvider` (core extraction S6).
 *  `locale` is given by the screen harness; the app takes it from the UI-language store. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { assetsMessages } from './assetsMessages'

export const AssetsIntlProvider = createModuleIntlProvider(assetsMessages)
