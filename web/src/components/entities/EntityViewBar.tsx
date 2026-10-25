/** EntityViewBar — REQ-556
 *
 *  Presentational bar of the record list screen: saved-view selector, column
 *  picker and (only with `canManage`) save and delete controls. It holds no view
 *  state beyond the name being typed and the delete-confirm flag; the page owns
 *  the selection and makes the API calls. Hiding save/delete is UX only: the
 *  server enforces EntitiesViewsManage on create/delete.
 */

import React, { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'

export interface EntityViewOption {
  id: string
  name: string
}

export interface EntityViewBarProps {
  views: EntityViewOption[]
  activeViewId: string | null
  onSelect: (id: string | null) => void
  /** Every column the picker can offer (definition fields). */
  fieldNames: string[]
  /** Columns currently shown, in display order. */
  selectedColumns: string[]
  onToggleColumn: (name: string) => void
  canManage: boolean
  /** Resolves true when the view was saved (the name input is then cleared). */
  onSave: (name: string) => Promise<boolean>
  onDelete: () => void
  /** Message already localised by the caller, or null. */
  saveError: string | null
  deleteError: string | null
  busy: boolean
}

export function EntityViewBar(props: EntityViewBarProps): React.ReactElement {
  const {
    views,
    activeViewId,
    onSelect,
    fieldNames,
    selectedColumns,
    onToggleColumn,
    canManage,
    onSave,
    onDelete,
    saveError,
    deleteError,
    busy,
  } = props
  const intl = useIntl()
  const [name, setName] = useState('')
  const [confirmOpen, setConfirmOpen] = useState(false)

  const trimmed = name.trim()
  const choices = [...fieldNames, ...selectedColumns.filter((c) => !fieldNames.includes(c))]
  const activeKnown = activeViewId != null && views.some((v) => v.id === activeViewId)

  return (
    <div
      data-testid="view-bar"
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-3)',
        padding: 'var(--space-4)',
        border: '1px solid var(--border-default)',
        borderRadius: 'var(--radius-md)',
        background: 'var(--surface-card)',
      }}
    >
      <div style={{ display: 'flex', gap: 'var(--space-3)', alignItems: 'center' }}>
        <label htmlFor="view-select">{intl.formatMessage({ id: 'entities.views.select.label' })}</label>
        <select
          id="view-select"
          data-testid="view-select"
          value={activeKnown ? (activeViewId as string) : ''}
          onChange={(e) => onSelect(e.target.value || null)}
        >
          <option value="">{intl.formatMessage({ id: 'entities.views.select.none' })}</option>
          {views.map((v) => (
            <option key={v.id} value={v.id}>
              {v.name}
            </option>
          ))}
        </select>
      </div>

      <fieldset
        data-testid="view-columns"
        style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-3)', border: 'none', padding: 0 }}
      >
        <legend>{intl.formatMessage({ id: 'entities.views.columns.label' })}</legend>
        {choices.map((c) => {
          const checked = selectedColumns.includes(c)
          return (
            <label key={c} style={{ display: 'flex', gap: 'var(--space-1)', alignItems: 'center' }}>
              <input
                type="checkbox"
                data-testid={`column-toggle-${c}`}
                checked={checked}
                // the server refuses a view with no columns, so the last one stays
                disabled={checked && selectedColumns.length <= 1}
                onChange={() => onToggleColumn(c)}
              />
              {c}
            </label>
          )
        })}
      </fieldset>

      {canManage && (
        <div style={{ display: 'flex', gap: 'var(--space-3)', alignItems: 'center', flexWrap: 'wrap' }}>
          <label htmlFor="view-name">{intl.formatMessage({ id: 'entities.views.save.nameLabel' })}</label>
          <input
            id="view-name"
            data-testid="view-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
          <Button
            variant="primary"
            size="sm"
            data-testid="view-save"
            disabled={busy || trimmed.length === 0}
            onClick={() => {
              void onSave(trimmed).then((ok) => {
                if (ok) setName('')
              })
            }}
          >
            {intl.formatMessage({ id: 'entities.views.save.action' })}
          </Button>
          <Button
            variant="danger"
            size="sm"
            data-testid="view-delete"
            disabled={busy || !activeKnown}
            onClick={() => setConfirmOpen(true)}
          >
            {intl.formatMessage({ id: 'entities.views.delete.action' })}
          </Button>
          <ConfirmDialog
            open={confirmOpen}
            title={intl.formatMessage({ id: 'entities.views.delete.confirmTitle' })}
            body={intl.formatMessage({ id: 'entities.views.delete.confirmBody' })}
            confirmText={intl.formatMessage({ id: 'entities.views.delete.confirmAction' })}
            cancelText={intl.formatMessage({ id: 'entities.views.delete.cancelAction' })}
            confirmVariant="danger"
            isLoading={busy}
            onConfirm={() => {
              setConfirmOpen(false)
              onDelete()
            }}
            onCancel={() => setConfirmOpen(false)}
          />
        </div>
      )}

      {saveError && (
        <div role="alert" data-testid="view-save-error" style={{ color: 'var(--color-error-dark)' }}>
          {saveError}
        </div>
      )}
      {deleteError && (
        <div role="alert" data-testid="view-delete-error" style={{ color: 'var(--color-error-dark)' }}>
          {deleteError}
        </div>
      )}
    </div>
  )
}
