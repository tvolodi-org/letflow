/** OfficialFormsIntlProvider — T-1983. Provides the Official forms catalog in the active UI language. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { officialFormsMessages } from './officialFormsMessages'

export const OfficialFormsIntlProvider = createModuleIntlProvider(officialFormsMessages)
