/** CoreHelpLink — T-1691. The Help link of one core screen. Reads its label straight from the help catalogue, so the
 *  host screens (some have no IntlProvider) need no new message ids. */
import { HelpLink } from '@/components/help/HelpLink'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { coreHelpMessages } from './coreHelpMessages'
import { coreHelpPath, type CoreHelpTopic } from './coreHelpTopics'

export function CoreHelpLink({ topic }: { topic: CoreHelpTopic }) {
  const locale = useUiLocale()
  return <HelpLink to={coreHelpPath(topic)} label={coreHelpMessages[locale]['core.help.link']} />
}
