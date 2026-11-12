/** DocumentList — T-1334 / C14. The list pane of the asset document workspace (`lf-doc__list`): filters kind, state and
 *  org unit (the only keys the list route takes), one button per document (number, state, kind, date, org unit),
 *  Load more, and the loading, empty and error states. The selected document is marked `aria-current`; a click opens
 *  it in the panel beside the list, which stays mounted. Times in the tenant time zone. Users with AssetsPost get one New
 *  button per kind (the draft form, T-1469). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Link, useNavigate } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import { Select } from '@/components/ui/Select'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { ASSETS_CARD_WRITE, ASSETS_POST } from '../assetsPermissions'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { useNames } from '../assetsNames'
import { usePickerOptions, anyPickerTruncated } from '../assetsPickers'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { LoadMore, RegisterError } from '../register/RegisterShell'
import { assetDocumentsApi, type AssetDocumentsPageBody } from './assetDocuments.api'
import { DOC_KINDS, DOC_STATES, formatEventTime } from './documentsModel'
import { documentStateTone as stateTone } from '@/lib/documentStateTone'

interface Filters {
  kind: string
  state: string
  org_unit_id: string
}
const EMPTY: Filters = { kind: '', state: '', org_unit_id: '' }
export const DOCUMENTS_PATH = '/admin/assets/documents'

export function DocumentList({ selectedId }: { selectedId: string | undefined }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const navigate = useNavigate()
  const { can } = useAccess()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<Filters>(EMPTY)
  const patch = (p: Partial<Filters>) => setFilters((f) => ({ ...f, ...p }))
  const orgUnits = usePickerOptions('org_unit')

  const params = Object.fromEntries(Object.entries(filters).filter(([, v]) => v !== ''))
  const query = useInfiniteQuery({
    queryKey: assetsQueryKeys.documents(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => assetDocumentsApi.list({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: AssetDocumentsPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => ({ org_unit: p.rows.map((r) => r.org_unit_id).filter((x): x is string => !!x) })))
  const dash = t('assets.common.dash')
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)

  return (
    <section className="lf-card lf-doc__list" aria-label={t('assets.doc.title')} data-testid="document-list">
      {anyPickerTruncated(orgUnits) && <TruncatedNotice messageId="assets.pickers.truncated" count={MAX_ROWS} />}
      <div className="lf-doc__tools">
        {can(ASSETS_POST) && (
          <div className="lf-btn-row" data-testid="document-new" role="group" aria-label={t('assets.doc.action.new')}>
            {DOC_KINDS.map((k) => (
              <Button key={k} variant="secondary" size="sm" onClick={() => navigate(`${DOCUMENTS_PATH}/new?kind=${k}`)}>
                {t(`assets.doc.new.${k}`)}
              </Button>
            ))}
          </div>
        )}
        <Select
          label={t('assets.doc.col.kind')}
          value={filters.kind}
          onChange={(kind) => patch({ kind })}
          options={DOC_KINDS.map((k) => ({ value: k, label: t(`assets.doc.kind.${k}`) }))}
          placeholder={t('assets.reg.all')}
        />
        <Select
          label={t('assets.doc.col.state')}
          value={filters.state}
          onChange={(state) => patch({ state })}
          options={DOC_STATES.map((k) => ({ value: k, label: t(`assets.doc.state.${k}`) }))}
          placeholder={t('assets.reg.all')}
        />
        <Select
          label={t('assets.reg.col.orgUnit')}
          value={filters.org_unit_id}
          onChange={(org_unit_id) => patch({ org_unit_id })}
          options={orgUnits}
          placeholder={t('assets.reg.all')}
        />
        <div className="lf-btn-row lf-btn-row--between">
          <span className="caption lf-faint">
            <span className="mono">{rows.length}</span>
          </span>
          {Object.keys(params).length > 0 && (
            <Button variant="ghost" size="sm" onClick={() => setFilters(EMPTY)}>
              {t('assets.common.clear')}
            </Button>
          )}
        </div>
      </div>
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : query.isPending ? (
        <div className="lf-doc__items" aria-busy="true" aria-label={t('assets.reg.loading')} data-testid="document-list-loading">
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
            <p className="lf-empty__title">{t('assets.doc.empty')}</p>
            {Object.keys(params).length === 0 ? (
              <>
                <p className="lf-empty__text" data-testid="empty-first">{t('assets.doc.emptyFirst')}</p>
                {can(ASSETS_CARD_WRITE) && <Link to="/admin/assets/cards">{t('assets.doc.noCards.link')}</Link>}
              </>
            ) : (
              <p className="lf-empty__text">{t('assets.doc.emptyText')}</p>
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
                      <span className={r.number ? 'lf-doc__num' : 'lf-doc__num is-draft'}>{r.number ?? t('assets.doc.draftMark')}</span>
                      <StatusPill tone={tone.tone} glyph={tone.glyph}>
                        {known(DOC_STATES, 'assets.doc.state', r.state)}
                      </StatusPill>
                    </span>
                    <span className="lf-doc__item-sub">
                      <span>{known(DOC_KINDS, 'assets.doc.kind', r.kind)}</span>
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
