/** CurrenciesIntlProvider — REQ-827. Provides the currencies message catalog in the active UI language. */
import { createModuleIntlProvider } from './createModuleIntlProvider'
import { currenciesMessages } from './currenciesMessages'

export const CurrenciesIntlProvider = createModuleIntlProvider(currenciesMessages)
