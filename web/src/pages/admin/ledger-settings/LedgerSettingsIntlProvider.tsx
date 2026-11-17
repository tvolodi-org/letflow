/** LedgerSettingsIntlProvider — REQ-839. Provides the negative balances catalog in the active UI language. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { ledgerSettingsMessages } from './ledgerSettingsMessages'

export const LedgerSettingsIntlProvider = createModuleIntlProvider(ledgerSettingsMessages)
