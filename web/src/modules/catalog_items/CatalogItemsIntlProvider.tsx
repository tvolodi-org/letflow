/** CatalogItemsIntlProvider — GH 3605 / REQ-673. A local IntlProvider for the catalog_items screens, made by the shared `createModuleIntlProvider` (core extraction S6).
 *  `locale` is given by the screen harness; the app takes it from the UI-language store. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { catalogItemsMessages } from './catalogItemsMessages'

export const CatalogItemsIntlProvider = createModuleIntlProvider(catalogItemsMessages)
