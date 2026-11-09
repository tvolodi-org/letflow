/** AssetsHelpPage — T-1560. Static help of one assets screen, `admin/assets/help/:topic`. The topic is matched against
 *  the closed list before any message id is built from it. */
import { useIntl } from 'react-intl'
import { useParams } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import { HelpTopicView } from '@/components/help/HelpTopicView'
import { readTopic } from '@/components/help/helpTopicText'
import { NotFoundPage } from '@/pages/NotFoundPage'
import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { ASSETS_HELP_PERMISSION, isAssetsHelpTopic, type AssetsHelpTopic } from './assetsHelpTopics'

const SCREEN_PATH: Record<AssetsHelpTopic, string> = {
  cards: '/admin/assets/cards',
  documents: '/admin/assets/documents',
  balances: '/admin/assets/balances',
  movements: '/admin/assets/movements',
}

function Topic({ topic }: { topic: AssetsHelpTopic }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  return (
    <RequirePermission permission={ASSETS_HELP_PERMISSION[topic]}>
      <HelpTopicView
        text={readTopic('assets', topic, t)}
        headings={{ purpose: t('assets.help.h.purpose'), tasks: t('assets.help.h.tasks'), refusals: t('assets.help.h.refusals') }}
        back={{ to: SCREEN_PATH[topic], label: t('assets.help.back') }}
      />
    </RequirePermission>
  )
}

export default function AssetsHelpPage() {
  const { topic } = useParams()
  return <AssetsIntlProvider>{isAssetsHelpTopic(topic) ? <Topic topic={topic} /> : <NotFoundPage />}</AssetsIntlProvider>
}
