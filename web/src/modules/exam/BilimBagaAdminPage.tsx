/** BilimBagaAdminPage — REQ-343
 *
 *  Landing page for the question-bank/exam-configuration admin section: one
 *  link per remaining BilimBaga entity type (each routed to
 *  `EntityCrudPage` via `/admin/bilimbaga/:entityType`, see
 *  BilimBagaEntityRoute.tsx and web/src/router.tsx), plus the required,
 *  visible exam_assignment gap note (REQ-343 gap note 3).
 *
 *  THE exam_assignment GAP — STATED HERE, NOT SOLVED. REQ-327 deliberately
 *  authored no exam_assignment entity type (assignee_id is polymorphic
 *  across user/department/none, and no fk_def can express that or reach the
 *  identity subsystem — see
 *  priv/packs/bilimbaga/entity_definitions/README-constraints.md).
 *  Since REQ-582, `Session.check_assigned/3` enforces assignment: an exam
 *  with no active exam_assignment cannot be started by anyone. There is still
 *  no admin screen for "assign this exam to these candidates" (assignments
 *  are written only by the operator seed/release path); this note is the
 *  deliberate way of saying so rather
 *  than building a client-side polyfill (no fake assignment list backed by
 *  a made-up entity type exists anywhere in this requirement's diff).
 */

import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { PageLayout } from '@/components/ui/PageLayout'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { BILIMBAGA_ENTITY_TYPES } from '@/config/bilimbagaEntities'

function BilimBagaAdminPageInner() {
  const intl = useIntl()

  return (
    <div data-testid="bilimbaga-admin-page">
      <PageLayout title={intl.formatMessage({ id: 'entities.admin.landing.title' })}>
        <p style={{ color: 'var(--text-secondary)' }}>
          {intl.formatMessage({ id: 'entities.admin.landing.intro' })}
        </p>

        <ul style={{ listStyle: 'none', padding: 0, display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: '.75rem' }}>
          {BILIMBAGA_ENTITY_TYPES.map(({ entityType }) => (
            <li key={entityType}>
              <Link
                to={`/admin/bilimbaga/${entityType}`}
                data-testid={`bilimbaga-nav-${entityType}`}
                style={{
                  display: 'block',
                  padding: '1rem',
                  borderRadius: 'var(--radius-md)',
                  border: '1px solid var(--border-default)',
                  background: 'var(--surface-card)',
                  color: 'var(--text-primary)',
                  textDecoration: 'none',
                }}
              >
                {intl.formatMessage({ id: `entities.entityType.${entityType}` })}
              </Link>
            </li>
          ))}
        </ul>

        <div
          role="note"
          data-testid="bilimbaga-exam-assignment-gap-note"
          style={{
            marginTop: '1.5rem',
            padding: '.85rem 1rem',
            borderRadius: 'var(--radius-md)',
            background: 'var(--color-warning-tint)',
            border: '1px solid var(--color-warning-border)',
            color: 'var(--color-warning-text)',
            fontSize: '.875rem',
          }}
        >
          {intl.formatMessage({ id: 'entities.admin.landing.examAssignmentGap' })}
        </div>
      </PageLayout>
    </div>
  )
}

export default function BilimBagaAdminPage() {
  return (
    <EntitiesIntlProvider>
      <BilimBagaAdminPageInner />
    </EntitiesIntlProvider>
  )
}
