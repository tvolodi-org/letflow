/** MaintenanceIntlProvider — GH 4802 / REQ-898. A local IntlProvider for the maintenance screens, made by the
 *  shared `createModuleIntlProvider` (core extraction S6). `locale` is given by the screen harness; the app takes
 *  it from the UI-language store. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { maintenanceMessages } from './maintenanceMessages'

export const MaintenanceIntlProvider = createModuleIntlProvider(maintenanceMessages)
