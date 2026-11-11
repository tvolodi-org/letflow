/** CoreHelpPage — T-1691. Static help of four core admin screens, `help/:topic`. The topic is matched against the
 *  closed list before any message id is built from it. */
import { IntlProvider, useIntl } from 'react-intl'
import { useParams } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import { HelpTopicView } from '@/components/help/HelpTopicView'
import { readTopic } from '@/components/help/helpTopicText'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { NotFoundPage } from '@/pages/NotFoundPage'
import { coreHelpMessages } from './coreHelpMessages'
import { CORE_HELP_ACCESS, CORE_HELP_BACK, isCoreHelpTopic, type CoreHelpTopic } from './coreHelpTopics'

function Topic({ topic }: { topic: CoreHelpTopic }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { permission, platformOnly } = CORE_HELP_ACCESS[topic]
  const view = (
    <HelpTopicView
      text={readTopic('core', topic, t)}
      headings={{ purpose: t('core.help.h.purpose'), tasks: t('core.help.h.tasks'), refusals: t('core.help.h.refusals') }}
      back={{ to: CORE_HELP_BACK[topic], label: t('core.help.back') }}
    />
  )
  return permission ? (
    <RequirePermission permission={permission} platformOnly={platformOnly}>
      {view}
    </RequirePermission>
  ) : (
    view
  )
}

export default function CoreHelpPage() {
  const { topic } = useParams()
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={coreHelpMessages[locale]}>
      {isCoreHelpTopic(topic) ? <Topic topic={topic} /> : <NotFoundPage />}
    </IntlProvider>
  )
}
