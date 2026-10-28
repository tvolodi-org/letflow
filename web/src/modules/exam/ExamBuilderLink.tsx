/** ExamBuilderLink — GH 3355 / REQ-602
 *
 *  The one link BilimBagaAdminPage carries to the exam builder. BilimBagaAdminPage renders in the
 *  entities catalog, so the link brings the exam catalog along; it is hidden unless the caller holds
 *  ExamAuthoringWrite (the route is guarded as well).
 */

import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { useAccess } from '@/auth/access'
import { EXAM_AUTHORING_WRITE } from './bilimbagaWrites'
import { ExamIntlProvider } from './ExamIntlProvider'

function ExamBuilderLinkInner() {
  const intl = useIntl()
  const access = useAccess()
  if (!access.can(EXAM_AUTHORING_WRITE)) return null
  return (
    <p>
      <Link to="/admin/bilimbaga/exam-builder" data-testid="bilimbaga-nav-exam-builder">
        {intl.formatMessage({ id: 'exam.builder.link' })}
      </Link>
    </p>
  )
}

export function ExamBuilderLink() {
  return (
    <ExamIntlProvider>
      <ExamBuilderLinkInner />
    </ExamIntlProvider>
  )
}
