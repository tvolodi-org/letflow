/** CoreHelpLink — T-1691, reworked in T-1872. The Help link of one core screen, a side panel (no navigation, the form
 *  keeps its data). Reads its texts straight from the help catalogue, so the host screens (some have no
 *  IntlProvider) need no new message ids. */
import { HelpLink } from '@/components/help/HelpLink'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { CoreHelpBody } from './CoreHelpPage'
import { coreHelpMessages } from './coreHelpMessages'
import type { CoreHelpTopic } from './coreHelpTopics'

export function CoreHelpLink({ topic, defaultOpen }: { topic: CoreHelpTopic; defaultOpen?: boolean }) {
  const locale = useUiLocale()
  const m = coreHelpMessages[locale]
  return (
    <HelpLink label={m['core.help.link']} closeLabel={m['core.help.close']} title={m[`core.help.${topic}.title`]} defaultOpen={defaultOpen}>
      <CoreHelpBody topic={topic} />
    </HelpLink>
  )
}
