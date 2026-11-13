/** StockHelpPage — T-1560. Static help of one stock screen, `admin/stock/help/:topic`. The topic is matched against
 *  the closed list before any message id is built from it. */
import { useIntl } from 'react-intl'
import { useParams } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import { HelpTopicView } from '@/components/help/HelpTopicView'
import { readTopic } from '@/components/help/helpTopicText'
import { NotFoundPage } from '@/pages/NotFoundPage'
import { StockIntlProvider } from '../StockIntlProvider'
import { STOCK_READ } from '../stockPermissions'
import { isStockHelpTopic, type StockHelpTopic } from './stockHelpTopics'

const SCREEN_PATH: Record<StockHelpTopic, string> = {
  counts: '/admin/stock/counts',
  documents: '/admin/stock/documents',
  balances: '/admin/stock/balances',
  movements: '/admin/stock/movements',
}

function Topic({ topic, withBack }: { topic: StockHelpTopic; withBack: boolean }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  return (
    <RequirePermission permission={STOCK_READ}>
      <HelpTopicView
        text={readTopic('stock', topic, t)}
        headings={{ purpose: t('stock.help.h.purpose'), tasks: t('stock.help.h.tasks'), refusals: t('stock.help.h.refusals') }}
        back={withBack ? { to: SCREEN_PATH[topic], label: t('stock.help.back') } : undefined}
      />
    </RequirePermission>
  )
}

/** The topic text without the route chrome, for the Help side panel (T-1872). */
export function StockHelpBody({ topic }: { topic: StockHelpTopic }) {
  return (
    <StockIntlProvider>
      <Topic topic={topic} withBack={false} />
    </StockIntlProvider>
  )
}

export default function StockHelpPage() {
  const { topic } = useParams()
  return <StockIntlProvider>{isStockHelpTopic(topic) ? <Topic topic={topic} withBack /> : <NotFoundPage />}</StockIntlProvider>
}
