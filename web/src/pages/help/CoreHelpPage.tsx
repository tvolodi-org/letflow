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

function Topic({ topic, withBack }: { topic: CoreHelpTopic; withBack: boolean }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { permission, platformOnly } = CORE_HELP_ACCESS[topic]
  const view = (
    <HelpTopicView
      text={readTopic('core', topic, t)}
      headings={{ purpose: t('core.help.h.purpose'), tasks: t('core.help.h.tasks'), refusals: t('core.help.h.refusals') }}
      back={withBack ? { to: CORE_HELP_BACK[topic], label: t('core.help.back') } : undefined}
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

/** The topic text without the route chrome, for the Help side panel (T-1872). Carries its own IntlProvider: some
 *  core host screens have none. */
export function CoreHelpBody({ topic }: { topic: CoreHelpTopic }) {
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={coreHelpMessages[locale]}>
      <Topic topic={topic} withBack={false} />
    </IntlProvider>
  )
}

export default function CoreHelpPage() {
  const { topic } = useParams()
  const locale = useUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={coreHelpMessages[locale]}>
      {isCoreHelpTopic(topic) ? <Topic topic={topic} withBack /> : <NotFoundPage />}
    </IntlProvider>
  )
}
