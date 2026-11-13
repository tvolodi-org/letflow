/** StockHelpLink — T-1872. The Help link of one stock screen: a side panel with the topic text, no navigation, so the
 *  form on the screen keeps its data. Label, title and Close text come from the stock catalogue. */
import { useIntl } from 'react-intl'
import { HelpLink } from '@/components/help/HelpLink'
import { StockHelpBody } from './StockHelpPage'
import type { StockHelpTopic } from './stockHelpTopics'

export function StockHelpLink({ topic, defaultOpen }: { topic: StockHelpTopic; defaultOpen?: boolean }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  return (
    <HelpLink label={t('stock.help.link')} closeLabel={t('stock.help.close')} title={t(`stock.help.${topic}.title`)} defaultOpen={defaultOpen}>
      <StockHelpBody topic={topic} />
    </HelpLink>
  )
}
