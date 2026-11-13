/** AssetsHelpLink — T-1872. The Help link of one assets screen: a side panel with the topic text, no navigation, so the
 *  form on the screen keeps its data. Label, title and Close text come from the assets catalogue. */
import { useIntl } from 'react-intl'
import { HelpLink } from '@/components/help/HelpLink'
import { AssetsHelpBody } from './AssetsHelpPage'
import type { AssetsHelpTopic } from './assetsHelpTopics'

export function AssetsHelpLink({ topic, defaultOpen }: { topic: AssetsHelpTopic; defaultOpen?: boolean }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  return (
    <HelpLink label={t('assets.help.link')} closeLabel={t('assets.help.close')} title={t(`assets.help.${topic}.title`)} defaultOpen={defaultOpen}>
      <AssetsHelpBody topic={topic} />
    </HelpLink>
  )
}
