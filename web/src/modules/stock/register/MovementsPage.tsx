/** MovementsPage — GH 3767 / REQ-724, T-1422 (GATE B R12). Posted ledger entries on the lf-journal component:
 *  operations on the left, the legs of the selected operation on the right; under 900 px the legs open inline (V1) and
 *  a Details button opens the full-screen details with Back and previous/next. Filters: cause, document type,
 *  document and posting range. Names and codes only (never an id); times in the tenant time zone (REQ-703 constant). */
import { useEffect, useState, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { Link, useSearchParams } from 'react-router-dom'
import { useInfiniteQuery, useQueries } from '@tanstack/react-query'
import {
  ArrowLeftRight, ClipboardList, HandHelping, PackageMinus, PackageOpen, PackagePlus, RotateCcw, Trash2, Undo2,
} from 'lucide-react'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { PageHeader } from '@/components/ui/PageHeader'
import { HelpLink } from '@/components/help/HelpLink'
import { Select } from '@/components/ui/Select'
import { RegistryFields, RegistrySection } from '@/components/ui/registry'
import {
  DEFAULT_JOURNAL_VARIANT, Journal, JournalDetails, JournalList, type JournalOp, type JournalVariant,
} from '@/components/ui/journal'
import { StockIntlProvider } from '../StockIntlProvider'
import { documentsApi } from '../documents/documents.api'
import { LoadMore, RegisterError } from './RegisterShell'
import { stockApi, type MovementsPageBody } from './stock.api'
import { stockQueryKeys } from './stockQueryKeys'
import { isDocumentUuid, toJournalOps } from './movementsModel'
import {
  CAUSES, DOCUMENT_TYPES, formatStockDateTime, movementNameIds, movementParams, rangeError, type MovementFilters,
} from './stockRegisterModel'
import { useNames } from './stockNames'
import { saveBlob } from '@/lib/saveBlob'

const digits = (v: string) => v.replace(/\D/g, '')

const KIND_ICON: Record<string, ReactNode> = {
  receipt: <PackagePlus className="lf-icon" aria-hidden="true" />,
  issue: <PackageMinus className="lf-icon" aria-hidden="true" />,
  write_off: <Trash2 className="lf-icon" aria-hidden="true" />,
  transfer: <ArrowLeftRight className="lf-icon" aria-hidden="true" />,
  hand_over: <HandHelping className="lf-icon" aria-hidden="true" />,
  return: <Undo2 className="lf-icon" aria-hidden="true" />,
  reversal: <RotateCcw className="lf-icon" aria-hidden="true" />,
  opening: <PackageOpen className="lf-icon" aria-hidden="true" />,
  count_difference: <ClipboardList className="lf-icon" aria-hidden="true" />,
}

const LAYOUT_SCREEN = 'stock.journal'

/** The CSS switches the layout at 900 px of the journal AREA (a container query), not of the window: with the side nav
 *  open a 1100 px window has a narrower area. The row click follows the same measure as the divider and the column handles. */
function areaNarrow(): boolean {
  const w = document.querySelector<HTMLElement>('[data-testid="journal"]')?.clientWidth ?? 0
  return w > 0 && w <= 900 // 0: not laid out (no measure), treated as wide
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
    document_type: '',
    document_id: (search.get('document_id') ?? '').trim(),
    from_seq: '',
    to_seq: '',
  })
  const [selectedId, setSelectedId] = useState<string | null>(initialOpenId ?? initialSelectedId)
  const [expandedId, setExpandedId] = useState<string | null>(variant === 'v1' ? initialOpenId : null)
  const [detailOpen, setDetailOpen] = useState(initialDetail && (initialOpenId ?? initialSelectedId) !== null)
  const [filtersOpen, setFiltersOpen] = useState(initialFiltersOpen)
  const [focusRow, setFocusRow] = useState<string | null>(null)
  const [exporting, setExporting] = useState(false)
  const [exportFailed, setExportFailed] = useState(false)
  const patch = (p: Partial<MovementFilters>) => setFilters((f) => ({ ...f, ...p }))
  const badRange = rangeError(filters.from_seq, filters.to_seq)

  const params = movementParams(filters)
  const query = useInfiniteQuery({
    queryKey: stockQueryKeys.movements(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => stockApi.movements({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: MovementsPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => movementNameIds(p.rows)))

  const dash = t('stock.common.dash')
  const when = (iso: string | null | undefined) => (iso ? formatStockDateTime(iso, { locale: intl.locale }) : dash)
  const ops = toJournalOps(rows, { name, t, when, kindIcon: (c) => KIND_ICON[c] ?? null })
  const selectedRow = rows.find((r) => r.entry_id === selectedId) ?? null
  const selectedOp = ops.find((o) => o.id === selectedId) ?? null
  const index = selectedOp ? ops.indexOf(selectedOp) : -1

  // Posted by: the movement rows carry no poster, so the label comes from the document read (null without a numbered document).
  const docId = selectedRow && isDocumentUuid(selectedRow.document_id) ? selectedRow.document_id : null
  // useQueries with one entry: a silent field lookup, not a screen state (the guard wants a boundary for useQuery).
  const [docQuery] = useQueries({
    queries: [
      {
        queryKey: stockQueryKeys.movementDocument(tenantId, docId ?? ''),
        queryFn: () => documentsApi.get(docId ?? ''),
        enabled: docId !== null,
        retry: false,
      },
    ],
  })

  useEffect(() => {
    if (focusRow === null) return
    document.querySelector<HTMLElement>(`[data-testid="journal-row"][data-id="${CSS.escape(focusRow)}"]`)?.focus()
    setFocusRow(null)
  }, [focusRow])

  // The full-screen view opened (wide Details button): focus Back; leave it if the selected operation left the list.
  const hasSelected = selectedOp !== null
  useEffect(() => {
    if (!detailOpen) return
    if (!hasSelected) {
      if (query.isSuccess) setDetailOpen(false)
      return
    }
    document.querySelector<HTMLElement>('[data-testid="journal-back"]')?.focus()
  }, [detailOpen, hasSelected, query.isSuccess])

  const closeDetails = () => {
    setDetailOpen(false)
    setFocusRow(selectedId)
  }
  const select = (id: string | null) => {
    setSelectedId(id)
  }
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

  const onExport = async () => {
    setExporting(true)
    setExportFailed(false)
    try {
      const { blob } = await stockApi.movementsXlsx(params)
      saveBlob(blob, 'stock-movements.xlsx')
    } catch {
      setExportFailed(true)
    } finally {
      setExporting(false)
    }
  }

  const filterCount = Object.keys(params).length
  const clearFilters = () => patch({ cause: '', document_type: '', document_id: '', from_seq: '', to_seq: '' })
  const state = query.isPending ? 'loading' : query.isError ? 'error' : 'ready'

  const legsLabels = {
    legs: t('stock.journal.legs'),
    heldBy: t('stock.journal.heldBy'),
    hiddenUnit: t('stock.leg.hiddenUnit'),
    change: t('stock.journal.change'),
    location: t('stock.col.location'),
    item: t('stock.col.item'),
  }

  const filtersNode = (
    <>
      <div className="lf-reg__toolrow lf-jrn__row-a">
        <Select
          label={t('stock.filter.cause')}
          value={filters.cause}
          onChange={(cause) => patch({ cause })}
          options={CAUSES.map((c) => ({ value: c, label: t(`stock.cause.${c}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Select
          label={t('stock.filter.docType')}
          value={filters.document_type}
          onChange={(document_type) => patch({ document_type })}
          options={DOCUMENT_TYPES.map((d) => ({ value: d, label: t(`stock.docType.${d}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Field label={t('stock.filter.document')}>
          <input type="text" value={filters.document_id} onChange={(e) => patch({ document_id: e.target.value })} />
        </Field>
      </div>
      <div className="lf-reg__toolrow lf-jrn__row-a">
        <Field label={t('stock.filter.fromSeq')} error={badRange ? t('stock.filter.rangeError') : undefined}>
          <input type="text" inputMode="numeric" value={filters.from_seq} onChange={(e) => patch({ from_seq: digits(e.target.value) })} />
        </Field>
        <Field label={t('stock.filter.toSeq')} error={badRange ? t('stock.filter.rangeError') : undefined}>
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
      empty={{ title: t('stock.movements.empty'), text: t('stock.movements.emptyText') }}
      noMatch={{ title: t('stock.movements.noMatch'), text: t('stock.movements.noMatchText') }}
      onExport={() => void onExport()}
      exporting={exporting}
      rangeText={t('stock.journal.showing', { n: ops.length })}
      foot={<LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />}
      notice={exportFailed ? <Banner tone="danger">{t('stock.movements.exportFailed')}</Banner> : undefined}
      labels={{
        title: t('stock.movements.title'),
        filters: t('stock.journal.filters'),
        export: t('stock.movements.export'),
        details: t('stock.journal.details'),
        expand: t('stock.journal.expand'),
        collapse: t('stock.journal.collapse'),
        clearFilters: t('stock.common.clear'),
        more: (n) => t('stock.journal.more', { n }),
        columns: {
          date: t('stock.col.time'),
          kind: t('stock.col.cause'),
          doc: t('stock.col.document'),
          item: t('stock.col.item'),
          qty: t('stock.col.quantity'),
          location: t('stock.col.location'),
          status: t('stock.col.status'),
        },
        legs: legsLabels,
      }}
    />
  )

  // details: fields and links of the selected operation
  const fields = selectedRow && selectedOp && (
    <RegistrySection pane="fields" id="mv-fields" title={t('stock.journal.operation')}>
      <RegistryFields
        fields={[
          { key: 'event', label: t('stock.journal.f.eventTime'), value: when(selectedRow.event_time), mono: true },
          { key: 'posted', label: t('stock.journal.f.postedAt'), value: when(selectedRow.posting_time), mono: true },
          {
            key: 'by',
            label: t('stock.journal.f.postedBy'),
            value: docQuery.data?.posted_by_label ?? dash,
            empty: !docQuery.data?.posted_by_label,
          },
          { key: 'cause', label: t('stock.journal.f.cause'), value: selectedOp.kindLabel },
          { key: 'reason', label: t('stock.journal.f.reason'), value: selectedRow.reason_code ?? '', empty: !selectedRow.reason_code },
        ]}
      />
    </RegistrySection>
  )

  const reversing = selectedRow ? rows.find((r) => r.reverses_entry_id === selectedRow.entry_id) : undefined
  const original = selectedRow?.reverses_entry_id ? rows.find((r) => r.entry_id === selectedRow.reverses_entry_id) : undefined
  const linkRow = (label: string, row: { entry_id: string; document_number?: string | null } | undefined) =>
    row?.document_number ? (
      <div className="lf-jrn__link">
        <span>{label}</span>
        <Button variant="ghost" size="sm" onClick={() => select(row.entry_id)} data-testid="journal-goto">
          {row.document_number}
        </Button>
      </div>
    ) : null
  const links = selectedOp && (
    <RegistrySection pane="links" id="mv-links" title={t('stock.journal.links')}>
      <div className="lf-jrn__links">
        {selectedOp.docText !== '' && (
          <div className="lf-jrn__link">
            <span>{t('stock.journal.l.doc')}</span>
            {selectedOp.docHref ? <Link to={selectedOp.docHref}>{selectedOp.docText}</Link> : <span>{selectedOp.docText}</span>}
          </div>
        )}
        {linkRow(t('stock.journal.l.reversedBy'), reversing)}
        {linkRow(t('stock.journal.l.reversalOf'), original)}
      </div>
    </RegistrySection>
  )

  const details = (
    <JournalDetails
      labels={{
        pane: t('stock.journal.pane'),
        back: t('stock.journal.back'),
        prev: t('stock.journal.prev'),
        next: t('stock.journal.next'),
        close: t('stock.journal.close'),
        sections: t('stock.journal.operation'),
        position: index >= 0 ? t('stock.journal.position', { a: index + 1, n: ops.length }) : '',
        legsTitle: t('stock.journal.legs'),
        legs: legsLabels,
        blankTitle: t('stock.journal.blank'),
        blankText: t('stock.journal.blankText'),
        details: t('stock.journal.details'),
      }}
      op={selectedOp}
      loading={state === 'loading'}
      hasPrev={index > 0}
      hasNext={index >= 0 && index < ops.length - 1}
      onBack={closeDetails}
      onPrev={() => step(-1)}
      onNext={() => step(1)}
      onOpenFull={() => setDetailOpen(true)}
      fields={fields}
      links={links}
      layoutScreen={LAYOUT_SCREEN}
    />
  )

  return (
    <>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.movements.title')} lede={t('stock.movements.lede')} actions={<HelpLink to="/admin/stock/help/movements" label={t('stock.help.link')} />} />
      <Journal
        variant={variant}
        list={list}
        details={details}
        detailOpen={detailOpen}
        filtersOpen={filtersOpen}
        onClose={closeDetails}
        layoutScreen={LAYOUT_SCREEN}
        splitLabel={t('stock.journal.pane')}
      />
    </>
  )
}

/** `initialSelectedId` selects one entry at first render, `initialOpenId` also expands it in V1, `initialDetail`
 *  opens its details (the screen harness uses these); `variant` names the narrow variant (V1 by default; V2 stays an option). */
export default function MovementsPage({
  initialOpenId,
  initialSelectedId,
  variant = DEFAULT_JOURNAL_VARIANT,
  initialDetail = false,
  initialFiltersOpen = false,
}: { initialOpenId?: string; initialSelectedId?: string; variant?: JournalVariant; initialDetail?: boolean; initialFiltersOpen?: boolean } = {}) {
  return (
    <StockIntlProvider>
      <MovementsInner initialOpenId={initialOpenId ?? null} initialSelectedId={initialSelectedId ?? null} variant={variant} initialDetail={initialDetail} initialFiltersOpen={initialFiltersOpen} />
    </StockIntlProvider>
  )
}
