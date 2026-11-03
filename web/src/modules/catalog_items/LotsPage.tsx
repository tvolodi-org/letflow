/** LotsPage — GH 3605 / REQ-673. The lots screen: list (item filter, retired switch, expiry sort), create,
 *  edit and retire. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { DELETED_FALSE, catalogItemsApi } from './catalogItems.api'
import { CatalogItemsIntlProvider } from './CatalogItemsIntlProvider'
import {
  CatalogItemsErrorAlert,
  CatalogItemsShell,
  DateField,
  SelectField,
  TextField,
  useLotRows,
} from './CatalogItemsShell'
import { CATALOG_ITEM, CATALOG_LOT, lotBodyForCreate, lotBodyForEdit, reasonOf, textOf } from './catalogItemsModel'
import { useCatalogItemsWrite } from './useCatalogItemsWrite'

type ExpirySort = 'none' | 'asc' | 'desc'

const ACTIVE_TRUE: EntityQueryFilterClause = { field: 'active', op: 'eq', value: true }

function LotsInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)

  const [selectedItem, setSelectedItem] = useState('')
  const [showRetired, setShowRetired] = useState(false)
  const [expirySort, setExpirySort] = useState<ExpirySort>('none')

  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<EntityRecord | null>(null)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const [createForm, setCreateForm] = useState({ item_id: '', code: '', producer: '', mark: '', expiry_date: '' })
  const [editForm, setEditForm] = useState({ producer: '', mark: '', expiry_date: '' })

  const itemsQuery = useLotRows(CATALOG_ITEM, 'all-items', [DELETED_FALSE])
  const allItems = itemsQuery.data ?? []
  const activeItems = allItems.filter((r) => r.field_values['active'] !== false)

  const lotFilters: EntityQueryFilterClause[] = [
    DELETED_FALSE,
    ...(!showRetired ? [ACTIVE_TRUE] : []),
    ...(selectedItem !== '' ? [{ field: 'item_id', op: 'eq' as const, value: selectedItem }] : []),
  ]
  const lotScope = `item:${selectedItem}|retired:${String(showRetired)}|sort:${expirySort}`
  const sortField = expirySort === 'none' ? 'code' : 'expiry_date'
  const lotsQuery = useLotRows(CATALOG_LOT, lotScope, lotFilters, { sortField })
  const lots = lotsQuery.data ?? []

  const itemById = new Map(allItems.map((r) => [r.record_id, r]))

  const createWrite = useCatalogItemsWrite<Record<string, string>>((body, key) =>
    catalogItemsApi.createLot(
      { item_id: body['item_id'] ?? '', code: body['code'] ?? '', ...body },
      key,
    ),
  )
  const editWrite = useCatalogItemsWrite<{ producer: string | null; mark: string | null; expiry_date: string | null }>(
    (body, key) => catalogItemsApi.updateLot(editing?.record_id ?? '', body, key),
  )
  const retireWrite = useCatalogItemsWrite<Record<string, never>>(
    (_body, key) => catalogItemsApi.retireLot(retiring?.record_id ?? '', key),
  )

  function startCreate() {
    createWrite.clearError()
    setCreating(true)
    setEditing(null)
    setCreateForm({ item_id: '', code: '', producer: '', mark: '', expiry_date: '' })
  }

  function startEdit(r: EntityRecord) {
    editWrite.clearError()
    setCreating(false)
    setEditing(r)
    setEditForm({
      producer: textOf(r, 'producer'),
      mark: textOf(r, 'mark'),
      expiry_date: textOf(r, 'expiry_date'),
    })
  }

  async function submitCreate() {
    const body = lotBodyForCreate(createForm)
    const result = await createWrite.submit(body)
    if (result === 'ok') setCreating(false)
  }

  async function submitEdit() {
    if (!editing) return
    const body = lotBodyForEdit(editForm)
    const result = await editWrite.submit(body, editing.record_id)
    if (result !== 'error') setEditing(null)
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await retireWrite.submit({}, target.record_id)
  }

  const expiryField = reasonOf(editWrite.error).field === 'expiry_date' || reasonOf(createWrite.error).field === 'expiry_date'
  const dash = t('catalog_items.common.dash')

  const filterHeader = !creating && !editing ? (
    <div style={{ marginBottom: 'var(--space-3)' }}>
      <SelectField
        name="item-filter"
        label={t('catalog_items.filter.item')}
        value={selectedItem}
        options={activeItems.map((r) => ({
          value: r.record_id,
          label: `${textOf(r, 'code')} - ${textOf(r, 'name')}`.replace(/ - $/, textOf(r, 'code')),
        }))}
        placeholder={t('catalog_items.common.choose')}
        onChange={setSelectedItem}
      />
      <label style={{ display: 'inline-flex', alignItems: 'center', gap: 'var(--space-2)' }}>
        <input
          type="checkbox"
          checked={showRetired}
          onChange={(e) => setShowRetired(e.target.checked)}
          data-testid="show-retired"
        />
        {t('catalog_items.filter.showRetired')}
      </label>
    </div>
  ) : undefined

  return (
    <CatalogItemsShell title={t('catalog_items.title')} queries={[itemsQuery, lotsQuery]} header={filterHeader}>
      <Button variant="primary" size="md" onClick={startCreate} data-testid="create-lot">
        {t('catalog_items.common.create')}
      </Button>

      {creating && (
        <form aria-label={t('catalog_items.create.title')} onSubmit={(e) => { e.preventDefault() }}>
          <h2>{t('catalog_items.create.title')}</h2>
          <CatalogItemsErrorAlert error={createWrite.error} id="create-error" />
          <SelectField
            name="create-item"
            label={t('catalog_items.create.item')}
            value={createForm.item_id}
            options={activeItems.map((r) => ({
              value: r.record_id,
              label: `${textOf(r, 'code')} - ${textOf(r, 'name')}`.replace(/ - $/, textOf(r, 'code')),
            }))}
            placeholder={t('catalog_items.common.choose')}
            onChange={(v) => setCreateForm((f) => ({ ...f, item_id: v }))}
          />
          <TextField
            name="create-code"
            label={t('catalog_items.create.code')}
            value={createForm.code}
            onChange={(v) => setCreateForm((f) => ({ ...f, code: v }))}
          />
          <TextField
            name="create-producer"
            label={t('catalog_items.create.producer')}
            value={createForm.producer}
            onChange={(v) => setCreateForm((f) => ({ ...f, producer: v }))}
          />
          <TextField
            name="create-mark"
            label={t('catalog_items.create.mark')}
            value={createForm.mark}
            onChange={(v) => setCreateForm((f) => ({ ...f, mark: v }))}
          />
          <DateField
            name="create-expiry"
            label={t('catalog_items.create.expiryDate')}
            value={createForm.expiry_date}
            onChange={(v) => setCreateForm((f) => ({ ...f, expiry_date: v }))}
            invalid={reasonOf(createWrite.error).field === 'expiry_date'}
          />
          <Button
            variant="primary"
            size="md"
            disabled={createWrite.isPending || createForm.item_id === '' || createForm.code.trim() === ''}
            onClick={() => void submitCreate()}
            data-testid="create-submit"
          >
            {t('catalog_items.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setCreating(false)}>
            {t('catalog_items.common.cancel')}
          </Button>
        </form>
      )}

      {editing && (
        <form aria-label={t('catalog_items.edit.title')} onSubmit={(e) => { e.preventDefault() }}>
          <h2>{t('catalog_items.edit.title')}</h2>
          <CatalogItemsErrorAlert error={editWrite.error} id="edit-error" />
          <TextField
            name="edit-lot-code"
            label={t('catalog_items.edit.lotCode')}
            value={textOf(editing, 'code')}
            onChange={() => undefined}
            readOnly
          />
          <TextField
            name="edit-item"
            label={t('catalog_items.edit.item')}
            value={(() => { const item = itemById.get(textOf(editing, 'item_id')); return item ? `${textOf(item, 'code')} - ${textOf(item, 'name')}` : textOf(editing, 'item_id') })()}
            onChange={() => undefined}
            readOnly
          />
          <TextField
            name="edit-producer"
            label={t('catalog_items.edit.producer')}
            value={editForm.producer}
            onChange={(v) => setEditForm((f) => ({ ...f, producer: v }))}
          />
          <TextField
            name="edit-mark"
            label={t('catalog_items.edit.mark')}
            value={editForm.mark}
            onChange={(v) => setEditForm((f) => ({ ...f, mark: v }))}
          />
          <DateField
            name="edit-expiry"
            label={t('catalog_items.edit.expiryDate')}
            value={editForm.expiry_date}
            onChange={(v) => setEditForm((f) => ({ ...f, expiry_date: v }))}
            invalid={expiryField}
          />
          <Button
            variant="primary"
            size="md"
            disabled={editWrite.isPending}
            onClick={() => void submitEdit()}
            data-testid="edit-submit"
          >
            {t('catalog_items.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setEditing(null)}>
            {t('catalog_items.common.cancel')}
          </Button>
        </form>
      )}

      {lots.length === 0 ? (
        <p>{t('catalog_items.common.empty')}</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>{t('catalog_items.col.code')}</th>
              <th>{t('catalog_items.col.item')}</th>
              <th>{t('catalog_items.col.producer')}</th>
              <th>{t('catalog_items.col.mark')}</th>
              <th>
                <button
                  type="button"
                  data-testid="expiry-sort-toggle"
                  onClick={() =>
                    setExpirySort((s) => (s === 'none' ? 'asc' : s === 'asc' ? 'desc' : 'none'))
                  }
                >
                  {expirySort === 'asc'
                    ? t('catalog_items.sort.expiryAsc')
                    : expirySort === 'desc'
                      ? t('catalog_items.sort.expiryDesc')
                      : t('catalog_items.sort.expiryNone')}
                </button>
              </th>
              <th>{t('catalog_items.col.active')}</th>
              <th>{t('catalog_items.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {lots.map((lot) => {
              const item = itemById.get(textOf(lot, 'item_id'))
              const itemLabel = item
                ? `${textOf(item, 'code')} ${textOf(item, 'name')}`.trim()
                : textOf(lot, 'item_id') || dash
              const isActive = lot.field_values['active'] !== false
              return (
                <tr key={lot.record_id} data-testid={`lot-row-${textOf(lot, 'code')}`}>
                  <td>{textOf(lot, 'code') || dash}</td>
                  <td>{itemLabel}</td>
                  <td>{textOf(lot, 'producer') || dash}</td>
                  <td>{textOf(lot, 'mark') || dash}</td>
                  <td>{textOf(lot, 'expiry_date') || dash}</td>
                  <td>{isActive ? t('catalog_items.active.yes') : t('catalog_items.active.no')}</td>
                  <td>
                    <Button variant="secondary" size="sm" onClick={() => startEdit(lot)} data-testid={`edit-${textOf(lot, 'code')}`}>
                      {t('catalog_items.common.edit')}
                    </Button>
                    {isActive && (
                      <Button variant="danger" size="sm" onClick={() => setRetiring(lot)} data-testid={`retire-${textOf(lot, 'code')}`}>
                        {t('catalog_items.common.retire')}
                      </Button>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}

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
    </CatalogItemsShell>
  )
}

export default function LotsPage() {
  return (
    <CatalogItemsIntlProvider>
      <LotsInner />
    </CatalogItemsIntlProvider>
  )
}
