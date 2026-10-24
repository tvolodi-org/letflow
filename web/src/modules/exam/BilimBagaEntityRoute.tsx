/** BilimBagaEntityRoute — REQ-343
 *
 *  Thin route adapter: reads `:entityType` from the URL and, when it names
 *  one of the ten admin-manageable BilimBaga entity types
 *  (web/src/config/bilimbagaEntities.ts), renders the generic
 *  `EntityCrudPage` against it. This is the ONLY per-request wiring point —
 *  there is no per-entity-type page component, matching this requirement's
 *  "generic component, not ten hand-copied pages" approach.
 */

import { useParams } from 'react-router-dom'
import { useIntl } from 'react-intl'
import { EntityCrudPage } from '@/pages/entities/EntityCrudPage'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { isBilimBagaEntityType } from '@/config/bilimbagaEntities'
import { BILIMBAGA_WRITES } from './bilimbagaWrites'

function NotFoundInner() {
  const intl = useIntl()
  return <div data-testid="bilimbaga-entity-not-found">{intl.formatMessage({ id: 'entities.crud.notFound' })}</div>
}

export default function BilimBagaEntityRoute() {
  const { entityType } = useParams<{ entityType: string }>()

  if (!isBilimBagaEntityType(entityType)) {
    return (
      <EntitiesIntlProvider>
        <NotFoundInner />
      </EntitiesIntlProvider>
    )
  }

  return <EntityCrudPage entityType={entityType as string} writes={BILIMBAGA_WRITES} />
}
