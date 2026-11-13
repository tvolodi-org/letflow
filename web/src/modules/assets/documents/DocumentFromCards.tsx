/** DocumentFromCards — T-1880 / D-135. The form of a new document started from asset cards (`?kind=&asset=<card id>`):
 *  it reads all requested cards in one query and each card's holder rows in the register, builds the draft
 *  (`prefillForm`: the cards are the lines, the header comes from the holder) and hands it to DocumentForm.
 *  Cards not found in the read (deleted, foreign id) are dropped with a notice. Nothing is saved until the user
 *  presses Save. Without AssetsRead the balances are not read and the form opens with the lines only. */
import { useIntl } from 'react-intl'
import { useQueries, useQuery } from '@tanstack/react-query'
import { useAccess } from '@/auth/access/useAccess'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import type { EntityRecord } from '@/types/api'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { cardsByIdsQuery } from '../AssetsShell'
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
  const cardsQ = useQuery({ ...cardsByIdsQuery(tenantId, assets), enabled: assets.length > 0 })
  const foundCards = cardsQ.data ?? []
  const foundIds = new Set(foundCards.map((c) => c.record_id))
  const missingCount = assets.filter((id) => !foundIds.has(id)).length
  const rowQs = useQueries({
    queries: foundCards.map((c) => {
      const params = { asset: c.record_id }
      return {
        queryKey: assetsQueryKeys.balances(tenantId, JSON.stringify(params)),
        queryFn: () => assetRegisterApi.balances(params),
        enabled: canRead,
        retry: false as const,
      }
    }),
  })
  const all = assets.length === 0 ? [] : [cardsQ, ...rowQs]
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
    foundCards.forEach((c, i) => { rowsById[c.record_id] = rowQs[i]?.data?.rows })
    const prefill = prefillForm(
      kind,
      foundCards.map((c) => ({ id: c.record_id, kind: textOf(c, 'kind'), orgUnitId: textOf(c, 'org_unit_id') })),
      rowsById,
    )
    const notices: string[] = []
    if (missingCount > 0) notices.push(intl.formatMessage({ id: 'assets.cardActions.prefill.missing' }, { count: missingCount }))
    if (prefill.manyHolders === 'cards') notices.push(intl.formatMessage({ id: 'assets.cardActions.prefill.manyHoldersCards' }))
    else if (prefill.manyHolders === 'card') notices.push(intl.formatMessage({ id: 'assets.cardActions.prefill.manyHolders' }))
    const notice = notices.length > 0 ? notices.join(' ') : undefined
    body = (
      <DocumentForm
        key={`${kind}|${assets.join(',')}`}
        kind={kind}
        initial={prefill.form}
        prefillCards={foundCards}
        notice={notice}
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
