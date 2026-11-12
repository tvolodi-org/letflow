/** DocumentList — T-1379 (GATE B rework R2). The list pane of the stock document workspace (`lf-doc__list`): filters
 *  kind, state and org unit, one button per document (number, state, kind, date, org unit), Load more, and the
 *  loading, empty and error states. The selected document is marked `aria-current`; a click opens it in the panel
 *  beside the list, which stays mounted. Times in the tenant time zone. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { Plus } from 'lucide-react'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import { Select } from '@/components/ui/Select'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { LoadMore, RegisterError } from '../register/RegisterShell'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { useNames } from '../register/stockNames'
import { usePickerOptions, anyPickerTruncated } from '../register/stockPickers'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { STOCK_POST } from '../stockPermissions'
import { documentsApi, type DocumentsPageBody } from './documents.api'
import { DOC_KINDS, DOC_STATES, formatEventTime } from './documentsModel'
import { documentStateTone as stateTone } from '@/lib/documentStateTone'

interface Filters {
  kind: string
  state: string
  org_unit_id: string
}
const EMPTY: Filters = { kind: '', state: '', org_unit_id: '' }
export const DOCUMENTS_PATH = '/admin/stock/documents'

export function DocumentList({ selectedId }: { selectedId: string | undefined }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const { can } = useAccess()
  const navigate = useNavigate()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<Filters>(EMPTY)
  const patch = (p: Partial<Filters>) => setFilters((f) => ({ ...f, ...p }))
  const orgUnits = usePickerOptions('org_unit')

  const params = Object.fromEntries(Object.entries(filters).filter(([, v]) => v !== ''))
  const query = useInfiniteQuery({
    queryKey: stockQueryKeys.documents(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => documentsApi.list({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: DocumentsPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => ({ org_unit: p.rows.map((r) => r.org_unit_id).filter((x): x is string => !!x) })))
  const dash = t('stock.common.dash')
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)
  const canPost = can(STOCK_POST)
  const newDoc = () => navigate(`${DOCUMENTS_PATH}/new`)

  return (
    <section className="lf-card lf-doc__list" aria-label={t('stock.doc.title')} data-testid="document-list">
      {anyPickerTruncated(orgUnits) && <TruncatedNotice messageId="stock.pickers.truncated" count={MAX_ROWS} />}
      <div className="lf-doc__tools">
        <Select
          label={t('stock.doc.col.kind')}
          value={filters.kind}
          onChange={(kind) => patch({ kind })}
          options={DOC_KINDS.map((k) => ({ value: k, label: t(`stock.doc.kind.${k}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Select
          label={t('stock.doc.col.state')}
          value={filters.state}
          onChange={(state) => patch({ state })}
          options={DOC_STATES.map((k) => ({ value: k, label: t(`stock.doc.state.${k}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Select
          label={t('stock.col.orgUnit')}
          value={filters.org_unit_id}
          onChange={(org_unit_id) => patch({ org_unit_id })}
          options={orgUnits}
          placeholder={t('stock.common.all')}
        />
        <div className="lf-btn-row lf-btn-row--between">
          <span className="caption lf-faint">
            <span className="mono">{rows.length}</span>
          </span>
          {Object.keys(params).length > 0 && (
            <Button variant="ghost" size="sm" onClick={() => setFilters(EMPTY)}>
              {t('stock.common.clear')}
            </Button>
          )}
          {canPost && (
            <Button variant="secondary" size="sm" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={newDoc}>
              {t('stock.doc.new')}
            </Button>
          )}
        </div>
      </div>
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : query.isPending ? (
        <div className="lf-doc__items" aria-busy="true" aria-label={t('stock.common.loading')} data-testid="document-list-loading">
          {[0, 1, 2, 3, 4].map((i) => (
            <div key={i} className="lf-doc__item">
              <Skeleton width="70%" />
              <Skeleton width="45%" />
            </div>
          ))}
        </div>
      ) : rows.length === 0 ? (
        <div className="lf-doc__empty">
          <div className="lf-empty">
            <p className="lf-empty__title">{t('stock.doc.empty')}</p>
            <p className="lf-empty__text">{t('stock.doc.emptyText')}</p>
            {canPost && (
              <Button variant="primary" onClick={newDoc}>
                {t('stock.doc.new')}
              </Button>
            )}
          </div>
        </div>
      ) : (
        <>
          <ul className="lf-doc__items">
            {rows.map((r) => {
              const tone = stateTone(r.state)
              return (
                <li key={r.id}>
                  <button
                    type="button"
                    className="lf-doc__item"
                    data-testid="document-row"
                    aria-current={r.id === selectedId ? 'true' : undefined}
                    onClick={() => navigate(`${DOCUMENTS_PATH}/${encodeURIComponent(r.id)}`)}
                  >
                    <span className="lf-doc__item-top">
                      <span className={r.number ? 'lf-doc__num' : 'lf-doc__num is-draft'}>{r.number ?? t('stock.doc.draftMark')}</span>
                      <StatusPill tone={tone.tone} glyph={tone.glyph}>
                        {known(DOC_STATES, 'stock.doc.state', r.state)}
                      </StatusPill>
                    </span>
                    <span className="lf-doc__item-sub">
                      <span>{known(DOC_KINDS, 'stock.doc.kind', r.kind)}</span>
                      <span className="lf-faint" aria-hidden="true">·</span>
                      <span className="mono-s">{formatEventTime(r.event_time, intl.locale, dash)}</span>
                    </span>
                    <span className="lf-doc__item-sub">{name('org_unit', r.org_unit_id) || dash}</span>
                  </button>
                </li>
              )
            })}
          </ul>
          <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
        </>
      )}
    </section>
  )
}
