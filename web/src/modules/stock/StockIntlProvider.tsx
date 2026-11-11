/** StockIntlProvider — GH 3767 / REQ-724. A local IntlProvider for the stock screens, made by the shared `createModuleIntlProvider` (core extraction S6).
 *  `locale` is given by the screen harness; the app takes it from the UI-language store. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { stockMessages } from './stockMessages'

export const StockIntlProvider = createModuleIntlProvider(stockMessages)
