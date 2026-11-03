/** LotsPage — GH 3605 / REQ-673. The lots screen: list (item filter, retired switch, expiry sort), create,
 *  edit and retire. Restyled on the shared components (design system, rule 2a): a lot is created and edited in the
 *  detail panel of MasterDetail, not in a modal; only Retire asks in a ConfirmDialog. */
import { useEffect, useMemo, useState, type KeyboardEvent } from 'react'
import { useIntl } from 'react-intl'
import { X } from 'lucide-react'
import { useAccess } from '@/auth/access'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { Field } from '@/components/ui/Field'
import { FormActions, FormRow, FormSection } from '@/components/ui/FormSection'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { DELETED_FALSE, catalogItemsApi } from './catalogItems.api'
import { CatalogItemsIntlProvider } from './CatalogItemsIntlProvider'
import { CatalogItemsBoundary, useLotRows } from './CatalogItemsShell'
import type { CatalogItemsUiLocale } from './catalogItemsMessages'
import {
  CATALOG_ITEM,
  CATALOG_LOT,
  errorMessageId,
  lotBodyForCreate,
  lotBodyForEdit,
  reasonOf,
  textOf,
} from './catalogItemsModel'
import { CATALOG_LOTS_WRITE } from './catalogItemsPermissions'
import { useCatalogItemsWrite } from './useCatalogItemsWrite'

type ExpirySort = 'none' | 'asc' | 'desc'
type Translate = (id: string, values?: Record<string, string | number>) => string

const NO_ROWS: EntityRecord[] = []
const ACTIVE_TRUE: EntityQueryFilterClause = { field: 'active', op: 'eq', value: true }

/** "CODE - Name" label for an item row; trailing " - " is stripped when name is empty. */
function itemLabel(r: EntityRecord): string {
  const code = textOf(r, 'code')
  const name = textOf(r, 'name')
  return name ? `${code} - ${name}` : code
}

/** Where a failed write is shown: next to the field it is about, else in a banner at the top of the form. */
function splitError(error: unknown, mode: 'create' | 'edit', t: Translate) {
  if (!error) return {}
  const info = reasonOf(error)
  const text = t(errorMessageId(error))
  if (info.reason === 'field_invalid' && info.field === 'expiry_date') return { expiry: text }
  if (mode === 'create' && (info.reason === 'item_not_found' || info.reason === 'item_inactive')) return { item: text }
  if (mode === 'create' && info.reason === 'record_payload_invalid') return { code: text }
  return { general: text }
}

interface LotPanelProps {
  mode: 'create' | 'edit'
  lot: EntityRecord | null
  itemOptions: { value: string; label: string }[]
  itemText: string
  locale: CatalogItemsUiLocale
  onClose: () => void
  onRetire: (lot: EntityRecord) => void
  onSaved: (message: string) => void
  canWrite: boolean
}

/** The record panel: one form for create, the same for edit. `key` on the call site resets it per record. */
function LotPanel(props: LotPanelProps) {
  const { mode, lot, locale } = props
  const intl = useIntl()
  const t: Translate = (id, values) => intl.formatMessage({ id }, values)
  const initial = useMemo(
    () => ({
      item_id: '',
      code: lot ? textOf(lot, 'code') : '',
      producer: lot ? textOf(lot, 'producer') : '',
      mark: lot ? textOf(lot, 'mark') : '',
      expiry_date: lot ? textOf(lot, 'expiry_date') : '',
    }),
    [lot],
  )
  const [form, setForm] = useState(initial)
  const write = useCatalogItemsWrite<Record<string, string>>((body, key) =>
    catalogItemsApi.createLot({ item_id: body['item_id'] ?? '', code: body['code'] ?? '', ...body }, key),
  )
  const editWrite = useCatalogItemsWrite<{ producer: string | null; mark: string | null; expiry_date: string | null }>(
    (body, key) => catalogItemsApi.updateLot(lot?.record_id ?? '', body, key),
  )
  const active = mode === 'create' ? write : editWrite
  const errors = splitError(active.error, mode, t)
  const dirty = (Object.keys(initial) as (keyof typeof initial)[]).some((k) => form[k] !== initial[k])
  const set = (k: keyof typeof initial) => (v: string) => setForm((f) => ({ ...f, [k]: v }))

  async function submit() {
    if (mode === 'create') {
      const result = await write.submit(lotBodyForCreate(form))
      if (result === 'ok') props.onSaved(t('catalog_items.toast.created', { code: form.code }))
      return
    }
    if (!lot) return
    const result = await editWrite.submit(lotBodyForEdit(form), lot.record_id)
    if (result === 'ok') props.onSaved(t('catalog_items.toast.saved', { code: textOf(lot, 'code') }))
    else if (result === 'notFound') props.onClose()
  }

  const isActive = lot ? lot.field_values['active'] !== false : true
  const title = mode === 'create' ? t('catalog_items.create.title') : t('catalog_items.edit.title')
  const closeButton = (
    <Button
      variant="ghost"
      size="sm"
      iconOnly
      label={t('catalog_items.common.close')}
      icon={<X className="lf-icon" aria-hidden="true" />}
      onClick={props.onClose}
      data-testid="panel-close"
    />
  )
  return (
    <div data-testid="lot-panel">
      <DetailHeader
        title={title}
        path={lot ? textOf(lot, 'code') : undefined}
        status={
          lot ? (
            <StatusPill tone={isActive ? 'success' : 'neutral'} glyph={isActive ? 'dot' : 'ring'}>
              {isActive ? t('catalog_items.active.yes') : t('catalog_items.active.no')}
            </StatusPill>
          ) : undefined
        }
        actions={
          <>
            {lot && isActive && props.canWrite && (
              <Button variant="danger" size="sm" onClick={() => props.onRetire(lot)} data-testid="panel-retire">
                {t('catalog_items.common.retire')}
              </Button>
            )}
            {closeButton}
          </>
        }
      />
      <div className="lf-card__body">
        <form
          className="lf-form"
          aria-label={title}
          onSubmit={(e) => {
            e.preventDefault()
          }}
        >
          {errors.general && (
            <div id={mode === 'create' ? 'create-error' : 'edit-error'}>
              <Banner tone="danger">{errors.general}</Banner>
            </div>
          )}
          <FormSection>
            {mode === 'create' ? (
              <FormRow>
                <Select
                  locale={locale}
                  name="create-item"
                  label={t('catalog_items.create.item')}
                  value={form.item_id}
                  options={props.itemOptions}
                  placeholder={t('catalog_items.common.choose')}
                  onChange={set('item_id')}
                  error={errors.item}
                />
                <Field locale={locale} label={t('catalog_items.create.code')} mono error={errors.code}>
                  <input name="create-code" value={form.code} onChange={(e) => set('code')(e.target.value)} />
                </Field>
              </FormRow>
            ) : (
              <FormRow>
                <Field locale={locale} label={t('catalog_items.edit.lotCode')} mono readOnly>
                  <input name="edit-lot-code" value={form.code} onChange={() => undefined} />
                </Field>
                <Field locale={locale} label={t('catalog_items.edit.item')} readOnly>
                  <input name="edit-item" value={props.itemText} onChange={() => undefined} />
                </Field>
              </FormRow>
            )}
            <FormRow>
              <Field
                locale={locale}
                label={mode === 'create' ? t('catalog_items.create.producer') : t('catalog_items.edit.producer')}
                optional
              >
                <input
                  name={`${mode}-producer`}
                  value={form.producer}
                  onChange={(e) => set('producer')(e.target.value)}
                />
              </Field>
              <Field
                locale={locale}
                label={mode === 'create' ? t('catalog_items.create.mark') : t('catalog_items.edit.mark')}
                optional
              >
                <input name={`${mode}-mark`} value={form.mark} onChange={(e) => set('mark')(e.target.value)} />
              </Field>
            </FormRow>
            <Field
              locale={locale}
              label={mode === 'create' ? t('catalog_items.create.expiryDate') : t('catalog_items.edit.expiryDate')}
              optional
              mono
              width="m"
              error={errors.expiry}
            >
              <input
                name={`${mode}-expiry`}
                type="date"
                value={form.expiry_date}
                onChange={(e) => set('expiry_date')(e.target.value)}
              />
            </Field>
          </FormSection>
          <FormActions
            locale={locale}
            saving={active.isPending}
            dirty={dirty}
            primary={
              <Button
                variant="primary"
                size="md"
                disabled={active.isPending || (mode === 'create' && (form.item_id === '' || form.code.trim() === ''))}
                onClick={() => void submit()}
                data-testid={mode === 'create' ? 'create-submit' : 'edit-submit'}
              >
                {t('catalog_items.common.save')}
              </Button>
            }
            secondary={
              <Button variant="ghost" size="md" onClick={props.onClose}>
                {t('catalog_items.common.cancel')}
              </Button>
            }
          />
        </form>
      </div>
    </div>
  )
}

function LotsInner({ locale }: { locale: CatalogItemsUiLocale }) {
  const intl = useIntl()
  const t: Translate = (id, values) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const canWrite = useAccess().can(CATALOG_LOTS_WRITE)

  const [selectedItem, setSelectedItem] = useState('')
  const [showRetired, setShowRetired] = useState(false)
  const [expirySort, setExpirySort] = useState<ExpirySort>('none')

  // The detail panel: closed, a new lot, or one lot being edited.
  const [panel, setPanel] = useState<{ mode: 'create' } | { mode: 'edit'; lot: EntityRecord } | null>(null)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const itemsQuery = useLotRows(CATALOG_ITEM, 'all-items', [DELETED_FALSE])
  const allItems = itemsQuery.data ?? NO_ROWS
  const activeItems = allItems.filter((r) => r.field_values['active'] !== false)

  const lotFilters: EntityQueryFilterClause[] = [
    DELETED_FALSE,
    ...(!showRetired ? [ACTIVE_TRUE] : []),
    ...(selectedItem !== '' ? [{ field: 'item_id', op: 'eq' as const, value: selectedItem }] : []),
  ]
  const lotScope = `item:${selectedItem}|retired:${String(showRetired)}|sort:${expirySort}`
  const sortField = expirySort === 'none' ? 'code' : 'expiry_date'
  const sortDir = expirySort === 'desc' ? 'desc' : 'asc'
  const lotsQuery = useLotRows(CATALOG_LOT, lotScope, lotFilters, { sortField, sortDir })
  const lots = lotsQuery.data ?? NO_ROWS
  const itemById = useMemo(() => new Map(allItems.map((r) => [r.record_id, r])), [allItems])

  const retireWrite = useCatalogItemsWrite<Record<string, never>>((_body, key) =>
    catalogItemsApi.retireLot(retiring?.record_id ?? '', key),
  )
  const retireError = retireWrite.error
  useEffect(() => {
    if (!retireError) return
    toast.error(intl.formatMessage({ id: errorMessageId(retireError) }))
    retireWrite.clearError()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reacts to a new error only
  }, [retireError])

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    const result = await retireWrite.submit({}, target.record_id)
    if (result === 'ok') {
      toast.success(t('catalog_items.toast.retired', { code: textOf(target, 'code') }))
      setPanel((p) => (p && p.mode === 'edit' && p.lot.record_id === target.record_id ? null : p))
    }
  }

  const failed = [itemsQuery, lotsQuery].find((q) => q.isError)
  const loading = [itemsQuery, lotsQuery].some((q) => q.isPending && q.fetchStatus !== 'idle')
  const loadError = failed ? t('catalog_items.load.error') : undefined
  const retry = () => void [itemsQuery, lotsQuery].forEach((q) => void q.refetch())

  const dash = t('catalog_items.common.dash')
  const itemOf = (lot: EntityRecord) => {
    const item = itemById.get(textOf(lot, 'item_id'))
    return item ? `${textOf(item, 'code')} ${textOf(item, 'name')}`.trim() : textOf(lot, 'item_id') || dash
  }
  const isActive = (lot: EntityRecord) => lot.field_values['active'] !== false
  const statusPill = (lot: EntityRecord) => (
    <StatusPill tone={isActive(lot) ? 'success' : 'neutral'} glyph={isActive(lot) ? 'dot' : 'ring'}>
      {isActive(lot) ? t('catalog_items.active.yes') : t('catalog_items.active.no')}
    </StatusPill>
  )

  const { fullColumns, compactColumns } = useMemo(() => {
    const codeCol: DataTableColumn<EntityRecord> = {
      key: 'code',
      label: t('catalog_items.col.code'),
      mono: true,
      render: (lot) => textOf(lot, 'code') || dash,
    }
    const expiryCol: DataTableColumn<EntityRecord> = {
      key: 'expiry',
      label: t('catalog_items.col.expiryDate'),
      stackLabel: t('catalog_items.col.expiryStack'),
      mono: true,
      render: (lot) => textOf(lot, 'expiry_date') || dash,
    }
    const activeCol: DataTableColumn<EntityRecord> = {
      key: 'active',
      label: t('catalog_items.col.active'),
      hideStackLabel: true,
      render: statusPill,
    }
    const fullColumns: DataTableColumn<EntityRecord>[] = [
      codeCol,
      {
        key: 'item',
        label: t('catalog_items.col.item'),
        render: (lot) => {
          const item = itemById.get(textOf(lot, 'item_id'))
          return item ? (
            <span>
              <span className="mono">{textOf(item, 'code')}</span> {textOf(item, 'name')}
            </span>
          ) : (
            itemOf(lot)
          )
        },
      },
      { key: 'producer', label: t('catalog_items.col.producer'), render: (lot) => textOf(lot, 'producer') || dash },
      { key: 'mark', label: t('catalog_items.col.mark'), mono: true, render: (lot) => textOf(lot, 'mark') || dash },
      expiryCol,
      activeCol,
      {
        key: 'actions',
        label: t('catalog_items.common.actions'),
        align: 'end',
        render: (lot) =>
          canWrite ? (
            <span className="lf-btn-row" onClick={(e) => e.stopPropagation()}>
              <Button
                variant="secondary"
                size="sm"
                onClick={() => setPanel({ mode: 'edit', lot })}
                data-testid={`edit-${textOf(lot, 'code')}`}
              >
                {t('catalog_items.common.edit')}
              </Button>
              {isActive(lot) && (
                <Button
                  variant="danger"
                  size="sm"
                  onClick={() => setRetiring(lot)}
                  data-testid={`retire-${textOf(lot, 'code')}`}
                >
                  {t('catalog_items.common.retire')}
                </Button>
              )}
            </span>
          ) : null,
      },
    ]
    return { fullColumns, compactColumns: [codeCol, expiryCol, activeCol] }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- t, itemOf and the pill follow intl and itemById
  }, [intl, canWrite, itemById])

  const createAction = canWrite ? (
    <Button variant="primary" size="md" onClick={() => setPanel({ mode: 'create' })} data-testid="create-lot">
      {t('catalog_items.common.create')}
    </Button>
  ) : undefined

  const selectedId = panel?.mode === 'edit' ? panel.lot.record_id : null
  const table = (columns: DataTableColumn<EntityRecord>[], compact: boolean) => (
    <DataTable
      columns={columns}
      data={lots}
      getRowId={(lot) => lot.record_id}
      selectedId={selectedId}
      rowState={(lot) => (isActive(lot) ? undefined : 'retired')}
      density={compact ? 'compact' : 'default'}
      isLoading={loading}
      error={loadError}
      onRetry={retry}
      emptyMessage={t('catalog_items.common.empty')}
      emptyText={t('catalog_items.common.emptyText')}
      emptyAction={createAction}
      onRowClick={canWrite ? (lot) => setPanel({ mode: 'edit', lot }) : undefined}
      labels={{ loading: t('catalog_items.common.loading'), retry: t('catalog_items.common.retry') }}
    />
  )

  const sortLabel =
    expirySort === 'asc'
      ? t('catalog_items.sort.expiryAsc')
      : expirySort === 'desc'
        ? t('catalog_items.sort.expiryDesc')
        : t('catalog_items.sort.expiryNone')

  const toolbar = (
    <div className="lf-toolbar">
      <Select
        locale={locale}
        name="item-filter"
        width="l"
        label={t('catalog_items.filter.item')}
        value={selectedItem}
        options={activeItems.map((r) => ({ value: r.record_id, label: itemLabel(r) }))}
        placeholder={t('catalog_items.common.choose')}
        onChange={setSelectedItem}
      />
      <div className="lf-toolbar__end">
        <Checkbox
          label={t('catalog_items.filter.showRetired')}
          checked={showRetired}
          onChange={setShowRetired}
          data-testid="show-retired"
        />
        <Button
          variant="secondary"
          size="md"
          onClick={() => setExpirySort((s) => (s === 'none' ? 'asc' : s === 'asc' ? 'desc' : 'none'))}
          data-testid="expiry-sort-toggle"
        >
          {sortLabel}
        </Button>
      </div>
    </div>
  )

  function onPanelKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === 'Escape') {
      e.stopPropagation()
      setPanel(null)
    }
  }

  const itemOptions = activeItems.map((r) => ({ value: r.record_id, label: itemLabel(r) }))
  const panelNode = panel ? (
    <div onKeyDown={onPanelKeyDown}>
      <LotPanel
        key={panel.mode === 'edit' ? panel.lot.record_id : 'create'}
        mode={panel.mode}
        lot={panel.mode === 'edit' ? panel.lot : null}
        itemOptions={itemOptions}
        itemText={panel.mode === 'edit' ? itemOf(panel.lot) : ''}
        locale={locale}
        canWrite={canWrite}
        onClose={() => setPanel(null)}
        onRetire={setRetiring}
        onSaved={(message) => {
          toast.success(message)
          setPanel(null)
        }}
      />
    </div>
  ) : null

  return (
    <>
      <PageHeader
        eyebrow={t('catalog_items.eyebrow')}
        title={t('catalog_items.title')}
        lede={t('catalog_items.lede')}
        actions={createAction}
      />
      <CatalogItemsBoundary queries={[itemsQuery, lotsQuery]}>
        {toolbar}
        {panelNode ? (
          <MasterDetail master={table(compactColumns, true)} detail={panelNode} />
        ) : (
          table(fullColumns, false)
        )}
      </CatalogItemsBoundary>

      <ConfirmDialog
        open={retiring !== null}
        title={t('catalog_items.retire.title')}
        body={t('catalog_items.retire.body', { code: retiring ? textOf(retiring, 'code') : '' })}
        confirmText={t('catalog_items.common.retire')}
        cancelText={t('catalog_items.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </>
  )
}

export default function LotsPage({ locale }: { locale?: CatalogItemsUiLocale } = {}) {
  return (
    <CatalogItemsIntlProvider locale={locale}>
      <LotsInnerWithLocale locale={locale} />
    </CatalogItemsIntlProvider>
  )
}

function LotsInnerWithLocale({ locale }: { locale?: CatalogItemsUiLocale }) {
  const intl = useIntl()
  return <LotsInner locale={locale ?? (intl.locale as CatalogItemsUiLocale)} />
}
