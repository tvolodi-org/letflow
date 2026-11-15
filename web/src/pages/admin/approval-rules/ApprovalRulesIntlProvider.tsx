/** ApprovalRulesIntlProvider — T-1989. Provides the approval rules catalog in the active UI language. */
import { createModuleIntlProvider } from '@/i18n/createModuleIntlProvider'
import { approvalRulesMessages } from './approvalRulesMessages'

export const ApprovalRulesIntlProvider = createModuleIntlProvider(approvalRulesMessages)
