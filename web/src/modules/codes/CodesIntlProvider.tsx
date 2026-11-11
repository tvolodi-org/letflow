/** CodesIntlProvider — GH 3606 / REQ-672. A local IntlProvider for the codes screens, made by the shared `createModuleIntlProvider` (core extraction S6).
 *  `locale` is given by the screen harness; the app takes it from the UI-language store. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { codesMessages } from './codesMessages'

export const CodesIntlProvider = createModuleIntlProvider(codesMessages)
