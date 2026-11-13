/** MovementsPage — T-1334 / C14. Posted asset ledger entries on the lf-journal component: operations on the left, the
 *  legs of the selected operation on the right; under 900 px the legs open inline and a Details button opens the
 *  full-screen details with Back and previous/next. Filters: cause, document and posting range. Names only (never an
 *  id); times in the tenant time zone. A masked leg (scoped read, REQ-682) shows "Hidden" and its quantity only, and no
 *  name is requested for it. The movement view has no document number: the document cell is the kind word, linked. */
import { useEffect, useState, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { Link, useSearchParams } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { ArrowLeftRight, HandHelping, PackagePlus, Trash2, Undo2 } from 'lucide-react'
import { useAuth } from '@/auth/AuthContext'
import { Field } from '@/components/ui/Field'
import { PageHeader } from '@/components/ui/PageHeader'
import { AssetsHelpLink } from '@/modules/assets/help/AssetsHelpLink'
import { Select } from '@/components/ui/Select'
import { RegistryFields, RegistrySection } from '@/components/ui/registry'
import {
  DEFAULT_JOURNAL_VARIANT, Journal, JournalDetails, JournalList, type JournalOp, type JournalVariant,
} from '@/components/ui/journal'
import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { useNames } from '../assetsNames'
import { LoadMore, RegisterError } from './RegisterShell'
import { assetRegisterApi, type AssetMovementsBody } from './assetRegister.api'
import {
  CAUSES, formatAssetsDateTime, movementNameIds, movementParams, rangeError, toJournalOps, type MovementFilters,
} from './registerModel'

const digits = (v: string) => v.replace(/\D/g, '')

const KIND_ICON: Record<string, ReactNode> = {
  commission: <PackagePlus className="lf-icon" aria-hidden="true" />,
  change: <ArrowLeftRight className="lf-icon" aria-hidden="true" />,
  handover: <HandHelping className="lf-icon" aria-hidden="true" />,
  writeoff: <Trash2 className="lf-icon" aria-hidden="true" />,
  reversal: <Undo2 className="lf-icon" aria-hidden="true" />,
}

const LAYOUT_SCREEN = 'assets.journal'

/** The CSS switches the layout at 900 px of the journal AREA (a container query), not of the window. */
function areaNarrow(): boolean {
  const w = document.querySelector<HTMLElement>('[data-testid="journal"]')?.clientWidth ?? 0
  return w > 0 && w <= 900
}

interface InnerProps {
  initialOpenId: string | null
  initialSelectedId: string | null
  variant: JournalVariant
  initialDetail: boolean
  initialFiltersOpen: boolean
}

function MovementsInner({ initialOpenId, initialSelectedId, variant, initialDetail, initialFiltersOpen }: InnerProps) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [search] = useSearchParams()
  const [filters, setFilters] = useState<MovementFilters>({
    cause: '',
    document_id: (search.get('document_id') ?? '').trim(),
    from_seq: '',
    to_seq: '',
  })
  const [selectedId, setSelectedId] = useState<string | null>(initialOpenId ?? initialSelectedId)
  const [expandedId, setExpandedId] = useState<string | null>(variant === 'v1' ? initialOpenId : null)
  const [detailOpen, setDetailOpen] = useState(initialDetail && (initialOpenId ?? initialSelectedId) !== null)
  const [filtersOpen, setFiltersOpen] = useState(initialFiltersOpen)
  const [focusRow, setFocusRow] = useState<string | null>(null)
  const patch = (p: Partial<MovementFilters>) => setFilters((f) => ({ ...f, ...p }))
  const badRange = rangeError(filters.from_seq, filters.to_seq)

  const params = movementParams(filters)
  const query = useInfiniteQuery({
    queryKey: assetsQueryKeys.movements(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => assetRegisterApi.movements({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: AssetMovementsBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => movementNameIds(p.rows)))

  const dash = t('assets.common.dash')
  const when = (iso: string | null | undefined) => (iso ? formatAssetsDateTime(iso, { locale: intl.locale }) : dash)
  const ops = toJournalOps(rows, { name, t, when, kindIcon: (c) => KIND_ICON[c] ?? null })
  const selectedRow = rows.find((r) => r.entry_id === selectedId) ?? null
  const selectedOp = ops.find((o) => o.id === selectedId) ?? null
  const index = selectedOp ? ops.indexOf(selectedOp) : -1

  useEffect(() => {
    if (focusRow === null) return
    document.querySelector<HTMLElement>(`[data-testid="journal-row"][data-id="${CSS.escape(focusRow)}"]`)?.focus()
    setFocusRow(null)
  }, [focusRow])

  const closeDetails = () => {
    setDetailOpen(false)
    setFocusRow(selectedId)
  }
  const select = (id: string | null) => setSelectedId(id)
  const onRow = (op: JournalOp) => {
    if (!areaNarrow()) return select(op.id)
    if (variant === 'v1') {
      select(op.id)
      setExpandedId(expandedId === op.id ? null : op.id)
      return
    }
    select(op.id)
    setDetailOpen(true)
  }
  const step = (dir: -1 | 1) => {
    const next = ops[index + dir]
    if (next) select(next.id)
  }

  const filterCount = Object.keys(params).length
  const clearFilters = () => patch({ cause: '', document_id: '', from_seq: '', to_seq: '' })
  const state = query.isPending ? 'loading' : query.isError ? 'error' : 'ready'

  const legsLabels = {
    legs: t('assets.journal.legs'),
    heldBy: t('assets.journal.heldBy'),
    hiddenUnit: t('assets.journal.hiddenUnit'),
    change: t('assets.journal.change'),
    location: t('assets.reg.col.location'),
    item: t('assets.reg.col.asset'),
  }

  const filtersNode = (
    <>
      <div className="lf-reg__toolrow lf-jrn__row-a">
        <Select
          label={t('assets.reg.filter.cause')}
          value={filters.cause}
          onChange={(cause) => patch({ cause })}
          options={CAUSES.map((c) => ({ value: c, label: t(`assets.cause.${c}`) }))}
          placeholder={t('assets.reg.all')}
        />
        <Field label={t('assets.reg.filter.document')}>
          <input type="text" value={filters.document_id} onChange={(e) => patch({ document_id: e.target.value })} />
        </Field>
      </div>
      <div className="lf-reg__toolrow lf-jrn__row-a">
        <Field label={t('assets.reg.filter.fromSeq')} error={badRange ? t('assets.reg.filter.rangeError') : undefined}>
          <input type="text" inputMode="numeric" value={filters.from_seq} onChange={(e) => patch({ from_seq: digits(e.target.value) })} />
        </Field>
        <Field label={t('assets.reg.filter.toSeq')} error={badRange ? t('assets.reg.filter.rangeError') : undefined}>
          <input type="text" inputMode="numeric" value={filters.to_seq} onChange={(e) => patch({ to_seq: digits(e.target.value) })} />
        </Field>
      </div>
    </>
  )

  const list = (
    <JournalList
      titleId="mv-list-title"
      variant={variant}
      layoutScreen={LAYOUT_SCREEN}
      state={state}
      errorNode={query.isError ? <RegisterError error={query.error} onRetry={() => void query.refetch()} /> : undefined}
      ops={ops}
      selectedId={selectedId}
      expandedId={expandedId}
      onRow={onRow}
      onToggleExpand={(op) => {
        select(op.id)
        setExpandedId(expandedId === op.id ? null : op.id)
      }}
      onDetails={(op) => {
        select(op.id)
        setDetailOpen(true)
      }}
      filtersNode={filtersNode}
      filterCount={filterCount}
      filtersOpen={filtersOpen}
      onToggleFilters={() => setFiltersOpen((v) => !v)}
      onClearFilters={clearFilters}
      filtered={filterCount > 0}
      empty={{ title: t('assets.movements.empty'), text: t('assets.movements.emptyText') }}
      noMatch={{ title: t('assets.movements.noMatch'), text: t('assets.movements.noMatchText') }}
      rangeText={t('assets.journal.showing', { n: ops.length })}
      foot={<LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />}
      labels={{
        title: t('assets.movements.title'),
        filters: t('assets.journal.filters'),
        export: t('assets.journal.export'),
        details: t('assets.journal.details'),
        expand: t('assets.journal.expand'),
        collapse: t('assets.journal.collapse'),
        clearFilters: t('assets.common.clear'),
        more: (n) => t('assets.journal.more', { n }),
        columns: {
          date: t('assets.reg.col.time'),
          kind: t('assets.reg.col.cause'),
          doc: t('assets.reg.col.document'),
          item: t('assets.reg.col.asset'),
          qty: t('assets.reg.col.quantity'),
          location: t('assets.reg.col.location'),
          status: t('assets.reg.col.status'),
        },
        legs: legsLabels,
      }}
    />
  )

  const fields = selectedRow && selectedOp && (
    <RegistrySection pane="fields" id="mv-fields" title={t('assets.journal.operation')}>
      <RegistryFields
        fields={[
          { key: 'event', label: t('assets.journal.f.eventTime'), value: when(selectedRow.event_time), mono: true },
          { key: 'posted', label: t('assets.journal.f.postedAt'), value: when(selectedRow.posting_time), mono: true },
          { key: 'cause', label: t('assets.journal.f.cause'), value: selectedOp.kindLabel },
          { key: 'reason', label: t('assets.journal.f.reason'), value: selectedRow.reason_code ?? '', empty: !selectedRow.reason_code },
        ]}
      />
    </RegistrySection>
  )
  const links = selectedOp && (
    <RegistrySection pane="links" id="mv-links" title={t('assets.journal.links')}>
      <div className="lf-jrn__links">
        {selectedOp.docText !== '' && (
          <div className="lf-jrn__link">
            <span>{t('assets.journal.l.doc')}</span>
            {selectedOp.docHref ? <Link to={selectedOp.docHref}>{selectedOp.docText}</Link> : <span>{selectedOp.docText}</span>}
          </div>
        )}
      </div>
    </RegistrySection>
  )

  const details = (
    <JournalDetails
      labels={{
        pane: t('assets.journal.pane'),
        back: t('assets.journal.back'),
        prev: t('assets.journal.prev'),
        next: t('assets.journal.next'),
        close: t('assets.journal.close'),
        sections: t('assets.journal.operation'),
        position: index >= 0 ? t('assets.journal.position', { a: index + 1, n: ops.length }) : '',
        legsTitle: t('assets.journal.legs'),
        legs: legsLabels,
        blankTitle: t('assets.journal.blank'),
        blankText: t('assets.journal.blankText'),
      }}
      op={selectedOp}
      loading={state === 'loading'}
      hasPrev={index > 0}
      hasNext={index >= 0 && index < ops.length - 1}
      onBack={closeDetails}
      onPrev={() => step(-1)}
      onNext={() => step(1)}
      fields={fields}
      links={links}
      layoutScreen={LAYOUT_SCREEN}
    />
  )

  return (
    <>
      <PageHeader eyebrow={t('assets.reg.eyebrow')} title={t('assets.movements.title')} lede={t('assets.movements.lede')} actions={<AssetsHelpLink topic="movements" />} />
      <Journal
        variant={variant}
        list={list}
        details={details}
        detailOpen={detailOpen}
        filtersOpen={filtersOpen}
        onClose={closeDetails}
        layoutScreen={LAYOUT_SCREEN}
        splitLabel={t('assets.journal.pane')}
      />
    </>
  )
}

/** `initialSelectedId` selects one entry at first render, `initialOpenId` also expands it in V1, `initialDetail`
 *  opens its details (the screen harness uses these). */
export default function MovementsPage({
  initialOpenId,
  initialSelectedId,
  variant = DEFAULT_JOURNAL_VARIANT,
  initialDetail = false,
  initialFiltersOpen = false,
}: { initialOpenId?: string; initialSelectedId?: string; variant?: JournalVariant; initialDetail?: boolean; initialFiltersOpen?: boolean } = {}) {
  return (
    <AssetsIntlProvider>
      <MovementsInner initialOpenId={initialOpenId ?? null} initialSelectedId={initialSelectedId ?? null} variant={variant} initialDetail={initialDetail} initialFiltersOpen={initialFiltersOpen} />
    </AssetsIntlProvider>
  )
}
