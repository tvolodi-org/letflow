/** CountSheet — GH 3735 / REQ-702. The lines of a count with typed input (status counting), the surplus-line form and
 *  the entry log. A typed quantity is sent unchanged as {counted_quantity: text}; text that is not a decimal string
 *  at least 0 is not sent and shows a field error. From status counted on the counted cells are plain text. */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Field } from '@/components/ui/Field'
import { FormActions, FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import { LoadMore, RegisterError } from '../register/RegisterShell'
import { useNames } from '../register/stockNames'
import { usePickerOptions } from '../register/stockPickers'
import type { NameIds } from '../register/stockRegisterModel'
import { countsApi, type CountEntry, type CountLine, type CountPage } from './counts.api'
import { countsQueryKeys } from './countsQueryKeys'
import { fieldOf, formatInZone, isDecimalNonNegative, reasonMessageId } from './countsModel'
import { useCountsWrite } from './useCountsWrite'
import { formatQuantity } from '@/lib/formatQuantity'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { actorLabel, tokenSubject } from '@/lib/references/actorLabel'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'

const NONE: never[] = []

export function usePagedList<T>(key: readonly unknown[], load: (cursor: string) => Promise<CountPage<T>>) {
  return useInfiniteQuery({
    queryKey: key,
    queryFn: ({ pageParam }) => load(pageParam),
    initialPageParam: '' as string,
    getNextPageParam: (last: CountPage<T>, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
}

function lineNameIds(rows: CountLine[]): NameIds {
  const out: NameIds = {}
  const add = (type: keyof NameIds, id: string | null | undefined) => {
    if (id) (out[type] ??= []).push(id)
  }
  for (const r of rows) {
    add('location_node', r.location_id)
    add('catalog_item', r.catalog_item_id)
    add('catalog_lot', r.catalog_lot_id)
    add('org_employee', r.responsible_employee_id)
    add('catalog_uom', r.unit_ref)
  }
  return out
}

/** The counted cell of a line in status counting: the typed text, sent on Enter or blur when it changed. */
function CountInput({ orderId, line, canRecord }: { orderId: string; line: CountLine; canRecord: boolean }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const server = line.counted_quantity ?? ''
  const [text, setText] = useState(server)
  const [invalid, setInvalid] = useState(false)
  // The last text the server accepted: Enter followed by blur must not send it twice.
  const sent = useRef<string | null>(null)
  useEffect(() => {
    setText(server)
    sent.current = null
  }, [server])
  const write = useCountsWrite((qty: string) => countsApi.recordCount(orderId, line.line_no, qty))

  async function commit() {
    if (text === server || text === sent.current) {
      setInvalid(false)
      return
    }
    if (!isDecimalNonNegative(text)) {
      setInvalid(true)
      return
    }
    setInvalid(false)
    const res = await write.submit(text)
    if (res.ok) {
      sent.current = text
      toast.success(t('counts.toast.counted'))
    }
  }

  if (!canRecord) return <span>{server === '' ? t('stock.common.dash') : server}</span>
  const error = invalid ? t('counts.sheet.quantityInvalid') : write.error ? t(reasonMessageId(write.error)) : undefined
  return (
    <Field
      label={t('counts.sheet.quantityLabel', { line: line.line_no })}
      hideLabel
      mono
      error={error}
      data-testid={`count-field-${line.line_no}`}
    >
      <input
        inputMode="decimal"
        size={6}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onBlur={() => void commit()}
        onKeyDown={(e) => {
          if (e.key === 'Enter') void commit()
        }}
        data-testid={`count-input-${line.line_no}`}
      />
    </Field>
  )
}

function SurplusForm({ orderId }: { orderId: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [f, setF] = useState({ location: '', item: '', unit: '', lot: '', responsible: '', qty: '' })
  const [invalid, setInvalid] = useState(false)
  const set = (k: keyof typeof f) => (v: string) => setF((x) => ({ ...x, [k]: v }))
  const locations = usePickerOptions('location_node', NONE, open)
  const items = usePickerOptions('catalog_item', NONE, open)
  const units = usePickerOptions('catalog_uom', NONE, open)
  const people = usePickerOptions('org_employee', NONE, open)
  const lots = usePickerOptions('catalog_lot', [{ field: 'item_id', op: 'eq', value: f.item }], open && f.item !== '')
  const write = useCountsWrite((body: Parameters<typeof countsApi.addSurplus>[1]) => countsApi.addSurplus(orderId, body))

  async function add() {
    if (!isDecimalNonNegative(f.qty) || f.location === '' || f.item === '' || f.unit === '') {
      setInvalid(true)
      return
    }
    setInvalid(false)
    const res = await write.submit({
      location_id: f.location,
      catalog_item_id: f.item,
      unit_ref: f.unit,
      counted_quantity: f.qty,
      ...(f.lot !== '' ? { catalog_lot_id: f.lot } : {}),
      ...(f.responsible !== '' ? { responsible_employee_id: f.responsible } : {}),
    })
    if (res.ok) {
      toast.success(t('counts.toast.surplus'))
      setF({ location: '', item: '', unit: '', lot: '', responsible: '', qty: '' })
    }
  }

  if (!open) {
    return (
      <div className="lf-form__actions">
        <Button variant="secondary" size="sm" onClick={() => setOpen(true)} data-testid="surplus-show">
          {t('counts.surplus.show')}
        </Button>
      </div>
    )
  }
  const field = fieldOf(write.error)
  const errorText = write.error ? t(reasonMessageId(write.error)) : undefined
  return (
    <FormSection title={t('counts.surplus.title')}>
      <div className="lf-form" data-testid="surplus-form">
        {errorText !== undefined && <Banner tone="danger">{errorText}</Banner>}
        <Select label={t('counts.surplus.location')} value={f.location} onChange={set('location')} options={locations} placeholder={t('counts.form.select')} />
        <Select label={t('counts.surplus.item')} value={f.item} onChange={(v) => setF((x) => ({ ...x, item: v, lot: '' }))} options={items} placeholder={t('counts.form.select')} />
        <Select label={t('counts.surplus.unit')} width="s" value={f.unit} onChange={set('unit')} options={units} placeholder={t('counts.form.select')} />
        <Select label={t('counts.surplus.lot')} optional value={f.lot} onChange={set('lot')} options={lots} placeholder={t('stock.common.dash')} disabled={f.item === ''} />
        <Select label={t('counts.surplus.responsible')} optional value={f.responsible} onChange={set('responsible')} options={people} placeholder={t('stock.common.dash')} />
        <Field
          label={t('counts.surplus.quantity')}
          mono
          width="s"
          error={invalid || (field === 'counted_quantity' && errorText) ? t('counts.sheet.quantityInvalid') : undefined}
        >
          <input inputMode="decimal" name="surplus_quantity" value={f.qty} onChange={(e) => set('qty')(e.target.value)} />
        </Field>
        <FormActions
          primary={
            <Button variant="primary" size="md" loading={write.isPending} onClick={() => void add()} data-testid="surplus-add">
              {t('counts.surplus.add')}
            </Button>
          }
          secondary={<Button variant="ghost" size="md" onClick={() => setOpen(false)}>{t('counts.surplus.hide')}</Button>}
        />
      </div>
    </FormSection>
  )
}

function EntryLog({ orderId }: { orderId: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const query = usePagedList<CountEntry>(countsQueryKeys.entries(tenantId, orderId), (cursor) =>
    countsApi.entries(orderId, cursor ? { cursor } : {}),
  )
  const rows = (query.data?.pages ?? []).flatMap((p) => p.rows)
  const dash = t('stock.common.dash')
  const uiLocale = useUiLocale()
  const name = useNames((query.data?.pages ?? []).map((p) => ({ org_employee: p.rows.map((r) => r.entered_by_employee_id).filter((v): v is string => !!v) })))
  // The person's name, never the id: the server label, else the linked employee, else "You" / "Another user".
  const entrant = (r: CountEntry): string =>
    r.entered_by_label ||
    (r.entered_by_employee_id ? name('org_employee', r.entered_by_employee_id) : '') ||
    (r.entered_by ? actorLabel(r.entered_by, tokenSubject(session?.token), REFERENCE_MESSAGES[uiLocale]) : '') ||
    dash
  const columns: DataTableColumn<CountEntry>[] = [
    { key: 'entry', label: t('counts.col.entryNo'), render: (r) => r.entry_no, mono: true },
    { key: 'user', label: t('counts.col.user'), render: (r) => entrant(r) },
    { key: 'time', label: t('counts.col.time'), render: (r) => formatInZone(r.entered_at) || dash, mono: true },
    { key: 'line', label: t('counts.col.line'), render: (r) => r.line_no, mono: true },
    { key: 'before', label: t('counts.col.before'), render: (r) => (r.quantity_before == null ? dash : formatQuantity(r.quantity_before)), mono: true, align: 'end' },
    { key: 'after', label: t('counts.col.after'), render: (r) => (r.quantity_after == null ? dash : formatQuantity(r.quantity_after)), mono: true, align: 'end' },
    { key: 'method', label: t('counts.col.method'), render: (r) => r.method ?? dash },
  ]
  return (
    <FormSection title={t('counts.entries.title')}>
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : (
        <div className="lf-field" data-testid="entry-log">
          <DataTable
            columns={columns}
            data={rows}
            isLoading={query.isPending}
            getRowId={(r) => String(r.entry_no)}
            emptyMessage={t('counts.entries.empty')}
            emptyText={t('counts.entries.emptyText')}
            labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
          />
          <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
        </div>
      )}
    </FormSection>
  )
}

export function CountSheet({ orderId, status, canRecord, highlightLine = null }: { orderId: string; status: string; canRecord: boolean; highlightLine?: number | null }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const counting = status === 'counting'
  const query = usePagedList<CountLine>(countsQueryKeys.lines(tenantId, orderId), (cursor) =>
    countsApi.lines(orderId, cursor ? { cursor } : {}),
  )
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => lineNameIds(p.rows)))
  const dash = t('stock.common.dash')
  const columns: DataTableColumn<CountLine>[] = [
    {
      key: 'line',
      label: t('counts.col.line'),
      render: (r) => (
        <>
          {r.line_no}
          {r.line_no === highlightLine && <> <StatusPill tone="info" glyph="dot">{t('counts.scan.lastScanned')}</StatusPill></>}
        </>
      ),
      mono: true,
    },
    {
      key: 'location',
      label: t('counts.col.location'),
      render: (r) => (
        <>
          {name('location_node', r.location_id)}
          {r.kind === 'surplus' && <> <StatusPill tone="warning" glyph="triangle">{t('counts.sheet.surplusTag')}</StatusPill></>}
        </>
      ),
    },
    { key: 'item', label: t('counts.col.item'), render: (r) => name('catalog_item', r.catalog_item_id) },
    { key: 'lot', label: t('counts.col.lot'), render: (r) => name('catalog_lot', r.catalog_lot_id) || dash },
    { key: 'responsible', label: t('counts.col.responsible'), render: (r) => name('org_employee', r.responsible_employee_id) || dash },
    { key: 'unit', label: t('counts.col.unit'), render: (r) => name('catalog_uom', r.unit_ref) },
    { key: 'book', label: t('counts.col.book'), render: (r) => (r.book_quantity == null ? dash : formatQuantity(r.book_quantity)), mono: true, align: 'end' },
    {
      key: 'counted',
      label: t('counts.col.counted'),
      render: (r) => <CountInput orderId={orderId} line={r} canRecord={counting && canRecord} />,
      mono: true,
      align: 'end',
    },
  ]
  return (
    <>
      <FormSection title={t('counts.sheet.title')}>
        {query.isError ? (
          <RegisterError error={query.error} onRetry={() => void query.refetch()} />
        ) : (
          <div className="lf-field lf-count-sheet" data-testid="count-sheet">
            <DataTable
              columns={columns}
              data={rows}
              isLoading={query.isPending}
              getRowId={(r) => String(r.line_no)}
              emptyMessage={t('counts.sheet.empty')}
              emptyText={t('counts.sheet.emptyText')}
              labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
            />
            <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
          </div>
        )}
      </FormSection>
      {counting && canRecord && <SurplusForm orderId={orderId} />}
      <EntryLog orderId={orderId} />
    </>
  )
}
