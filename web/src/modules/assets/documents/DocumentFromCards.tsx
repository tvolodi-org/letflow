/** DocumentFromCards — T-1880 / D-135. The form of a new document started from asset cards (`?kind=&asset=<card id>`):
 *  it reads each card and its holder rows in the register, builds the draft (`prefillForm`: the cards are the lines, the
 *  header comes from the holder) and hands it to DocumentForm. Nothing is saved until the user presses Save. Without
 *  AssetsRead the balances are not read and the form opens with the lines only. */
import { useIntl } from 'react-intl'
import { useQueries } from '@tanstack/react-query'
import { useAccess } from '@/auth/access/useAccess'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import type { EntityRecord } from '@/types/api'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { cardByIdQuery } from '../AssetsShell'
import { ASSETS_READ } from '../assetsPermissions'
import { textOf } from '../assetsModel'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { prefillForm } from '../cardPrefill'
import { assetRegisterApi, type AssetBalanceRow } from '../register/assetRegister.api'
import type { AssetDocument } from './assetDocuments.api'
import { DocumentForm } from './DocumentForm'
import type { DocKind } from './documentsModel'

export interface DocumentFromCardsProps {
  kind: DocKind
  assets: string[]
  title: string
  onBack: () => void
  onCancel: () => void
  onKindChange: (kind: DocKind) => void
  onDone: (saved: AssetDocument) => void
}

export function DocumentFromCards({ kind, assets, ...rest }: DocumentFromCardsProps) {
  const intl = useIntl()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const canRead = can(ASSETS_READ)
  const cardQs = useQueries({ queries: assets.map((id) => cardByIdQuery(tenantId, id)) })
  const rowQs = useQueries({
    queries: assets.map((id) => {
      const params = { asset: id }
      return {
        queryKey: assetsQueryKeys.balances(tenantId, JSON.stringify(params)),
        queryFn: () => assetRegisterApi.balances(params),
        enabled: canRead,
        retry: false as const,
      }
    }),
  })
  const all = [...cardQs, ...rowQs]
  const failed = all.find((q) => q.isError)
  const state: RendererState = failed
    ? classifyError(failed.error)
    : all.some((q) => q.isPending && q.fetchStatus !== 'idle')
      ? 'loading'
      : 'success'
  const retry = () => all.forEach((q) => void q.refetch())
  let body = null
  if (state === 'success') {
    const rowsById: Record<string, AssetBalanceRow[] | undefined> = {}
    assets.forEach((id, i) => {
      rowsById[id] = rowQs[i].data?.rows
    })
    const prefill = prefillForm(
      kind,
      assets.map((id, i) => ({ id, kind: textOf(cardQs[i].data ?? emptyCard, 'kind'), orgUnitId: textOf(cardQs[i].data ?? emptyCard, 'org_unit_id') })),
      rowsById,
    )
    body = (
      <DocumentForm
        key={`${kind}|${assets.join(',')}`}
        kind={kind}
        initial={prefill.form}
        notice={prefill.manyHolders ? intl.formatMessage({ id: 'assets.cardActions.prefill.manyHolders' }) : undefined}
        {...rest}
      />
    )
  }
  return (
    <QueryStateBoundary state={state} onRetry={retry}>
      {body}
    </QueryStateBoundary>
  )
}

const emptyCard = { record_id: '', field_values: {} } as unknown as EntityRecord
