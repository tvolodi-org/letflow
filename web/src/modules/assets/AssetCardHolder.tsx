/** AssetCardHolder — T-1488 / G1-a. The read-only "Holder" section of the card panel: where the asset is now and who
 *  holds it, read from the register (the balance rows of this card), never typed on the card. A card that was never
 *  commissioned has no rows. Needs AssetsRead; without it the section is absent and no call is made. */
import { useIntl } from 'react-intl'
import { useQuery } from '@tanstack/react-query'
import { useAccess } from '@/auth/access/useAccess'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { formatQuantity } from '@/lib/formatQuantity'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { useNames } from './assetsNames'
import { ASSETS_READ } from './assetsPermissions'
import { assetsQueryKeys } from './assetsQueryKeys'
import { RegisterError } from './register/RegisterShell'
import { assetRegisterApi } from './register/assetRegister.api'
import { balanceNameIds } from './register/registerModel'

export function AssetCardHolder({ cardId }: { cardId: string }) {
  const { can } = useAccess()
  return can(ASSETS_READ) ? <HolderRows cardId={cardId} /> : null
}

function HolderRows({ cardId }: { cardId: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const params = { asset: cardId }
  const query = useQuery({
    queryKey: assetsQueryKeys.balances(session?.tenant_id ?? '', JSON.stringify(params)),
    queryFn: () => assetRegisterApi.balances(params),
    retry: false,
  })
  const rows = query.data?.rows ?? []
  const name = useNames([balanceNameIds(rows)])
  const dash = t('assets.common.dash')
  const state: RendererState = query.isError ? classifyError(query.error) : query.isPending ? 'loading' : 'success'

  return (
    <section className="lf-form__section" data-testid="asset-holder">
      <h3 className="lf-form__title">{t('assets.holder.title')}</h3>
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : (
        <QueryStateBoundary state={state} onRetry={() => void query.refetch()}>
          {rows.length === 0 ? (
            <p className="caption lf-faint" data-testid="asset-holder-none">
              {t('assets.holder.none')}
            </p>
          ) : (
            rows.map((r) => (
              <dl className="lf-dl" key={`${r.org_unit}|${r.location ?? ''}|${r.material_responsible}|${r.actual_user ?? ''}`}>
                <dt>{t('assets.reg.col.orgUnit')}</dt>
                <dd>{name('org_unit', r.org_unit) || dash}</dd>
                <dt>{t('assets.reg.col.location')}</dt>
                <dd>{name('location_node', r.location) || dash}</dd>
                <dt>{t('assets.reg.col.responsible')}</dt>
                <dd>{name('org_employee', r.material_responsible) || dash}</dd>
                <dt>{t('assets.reg.col.user')}</dt>
                <dd>{name('org_employee', r.actual_user) || dash}</dd>
                <dt>{t('assets.reg.col.quantity')}</dt>
                <dd className="mono">{formatQuantity(r.quantity, intl.locale)}</dd>
              </dl>
            ))
          )}
        </QueryStateBoundary>
      )}
    </section>
  )
}
