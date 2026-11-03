/** LocationTreePage — GH 3607 / REQ-671. The location tree: list, create (root or child, free or composed
 *  address), edit, move, retire. The tree is built here from the loaded nodes (`parent_id`). With the retired
 *  switch off only active rows are loaded, so an active child of a retired parent shows as a root; the move
 *  picker is built from the loaded active rows and the server's cycle answer stays the authority. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityRecord } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, locationsApi, type NodeCreate, type NodeUpdate } from './locations.api'
import { LocationsIntlProvider } from './LocationsIntlProvider'
import { LocationsErrorAlert, LocationsShell, SelectField, TextField, fieldMarked, useLocationRows } from './LocationsShell'
import {
  LOCATION_NODE,
  LOCATION_TYPES,
  buildTree,
  isActive,
  kindSuggestions,
  moveTargets,
  textOf,
  treeOptions,
} from './locationsModel'
import { useLocationsWrite } from './useLocationsWrite'

type Cmd =
  | { op: 'create'; body: NodeCreate }
  | { op: 'update'; id: string; body: NodeUpdate }
  | { op: 'move'; id: string; parentId: string | null }
  | { op: 'retire'; id: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return locationsApi.createNode(cmd.body, key)
  if (cmd.op === 'update') return locationsApi.updateNode(cmd.id, cmd.body, key)
  if (cmd.op === 'move') return locationsApi.moveNode(cmd.id, cmd.parentId, key)
  return locationsApi.retireNode(cmd.id, key)
}

interface Form {
  code: string
  name: string
  node_kind: string
  segment: string
  mode: 'free' | 'compose'
  address: string
  location_type: string
  parent_id: string
}
const EMPTY: Form = { code: '', name: '', node_kind: '', segment: '', mode: 'free', address: '', location_type: '', parent_id: '' }

function LocationTreeInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useLocationRows(LOCATION_NODE, showRetired ? 'all' : 'active', [
    DELETED_FALSE,
    ...(showRetired ? [] : [ACTIVE_TRUE]),
  ])
  const write = useLocationsWrite<Cmd>(run)
  const [editing, setEditing] = useState<'new' | EntityRecord | null>(null)
  const [form, setForm] = useState<Form>(EMPTY)
  const [moving, setMoving] = useState<EntityRecord | null>(null)
  const [moveTo, setMoveTo] = useState('')
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const nodes = rows.data ?? []
  const tree = buildTree(nodes, 'parent_id')
  const kinds = kindSuggestions(nodes)
  const dash = t('locations.common.dash')

  function open(target: 'new' | EntityRecord, parent = '') {
    write.clearError()
    setEditing(target)
    setForm(
      target === 'new'
        ? { ...EMPTY, parent_id: parent }
        : {
            code: textOf(target, 'code'),
            name: textOf(target, 'name'),
            node_kind: textOf(target, 'node_kind'),
            segment: textOf(target, 'segment'),
            mode: 'free',
            address: textOf(target, 'address'),
            location_type: textOf(target, 'location_type'),
            parent_id: textOf(target, 'parent_id'),
          },
    )
  }

  async function save() {
    if (editing === null) return
    const result = await write.submit(
      editing === 'new'
        ? {
            op: 'create',
            body: {
              code: form.code,
              name: form.name,
              node_kind: form.node_kind,
              ...(form.parent_id !== '' ? { parent_id: form.parent_id } : {}),
              ...(form.segment.trim() !== '' ? { segment: form.segment } : {}),
              ...(form.location_type !== '' ? { location_type: form.location_type } : {}),
              ...(form.mode === 'compose'
                ? { address_pattern: 'segments' as const }
                : form.address.trim() !== ''
                  ? { address: form.address }
                  : {}),
            },
          }
        : {
            op: 'update',
            id: editing.record_id,
            body: {
              name: form.name,
              node_kind: form.node_kind,
              segment: form.segment === '' ? null : form.segment,
              address: form.address === '' ? null : form.address,
              location_type: form.location_type === '' ? null : form.location_type,
            },
          },
    )
    if (result === 'ok' || result === 'notFound') setEditing(null)
  }

  async function confirmMove() {
    if (!moving) return
    const result = await write.submit({ op: 'move', id: moving.record_id, parentId: moveTo === '' ? null : moveTo })
    if (result !== 'error') setMoving(null)
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await write.submit({ op: 'retire', id: target.record_id })
  }

  return (
    <LocationsShell
      title={t('locations.tree.title')}
      queries={[rows]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      actions={
        <Button variant="primary" size="md" onClick={() => open('new')} data-testid="loc-create">
          {t('locations.common.create')}
        </Button>
      }
    >
      <LocationsErrorAlert error={write.error} />
      {editing !== null && (
        <form
          aria-label={t(editing === 'new' ? 'locations.common.create' : 'locations.common.edit')}
          onSubmit={(e) => {
            e.preventDefault()
            void save()
          }}
        >
          <TextField name="code" label={t('locations.common.code')} value={form.code} readOnly={editing !== 'new'} invalid={fieldMarked(write.error, 'code')} onChange={(v) => setForm({ ...form, code: v })} />
          <TextField name="name" label={t('locations.common.name')} value={form.name} invalid={fieldMarked(write.error, 'name')} onChange={(v) => setForm({ ...form, name: v })} />
          <TextField name="node_kind" label={t('locations.common.kind')} value={form.node_kind} list="locations-kinds" invalid={fieldMarked(write.error, 'node_kind')} onChange={(v) => setForm({ ...form, node_kind: v })} />
          <datalist id="locations-kinds">
            {kinds.map((k) => (
              <option key={k} value={k} />
            ))}
          </datalist>
          <TextField name="segment" label={t('locations.common.segment')} value={form.segment} invalid={fieldMarked(write.error, 'segment')} onChange={(v) => setForm({ ...form, segment: v })} />
          {editing === 'new' && (
            <fieldset style={{ marginBottom: 'var(--space-3)' }}>
              <legend>{t('locations.tree.addressMode')}</legend>
              <label style={{ display: 'block' }}>
                <input type="radio" name="address_mode" checked={form.mode === 'free'} onChange={() => setForm({ ...form, mode: 'free' })} />
                {t('locations.tree.addressFree')}
              </label>
              <label style={{ display: 'block' }}>
                <input type="radio" name="address_mode" checked={form.mode === 'compose'} onChange={() => setForm({ ...form, mode: 'compose' })} />
                {t('locations.tree.addressCompose')}
              </label>
            </fieldset>
          )}
          {(editing !== 'new' || form.mode === 'free') && (
            <TextField name="address" label={t('locations.common.address')} value={form.address} invalid={fieldMarked(write.error, 'address')} onChange={(v) => setForm({ ...form, address: v })} />
          )}
          <SelectField
            name="location_type"
            label={t('locations.common.locationType')}
            value={form.location_type}
            options={LOCATION_TYPES.map((v) => ({ value: v, label: t(`locations.type.${v}`) }))}
            placeholder={t('locations.tree.noType')}
            invalid={fieldMarked(write.error, 'location_type')}
            onChange={(v) => setForm({ ...form, location_type: v })}
          />
          {editing === 'new' && (
            <SelectField
              name="parent_id"
              label={t('locations.common.parent')}
              value={form.parent_id}
              options={treeOptions(nodes, 'parent_id')}
              placeholder={t('locations.tree.noParent')}
              invalid={fieldMarked(write.error, 'parent_id')}
              onChange={(v) => setForm({ ...form, parent_id: v })}
            />
          )}
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void save()} data-testid="loc-save">
            {t('locations.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setEditing(null)}>
            {t('locations.common.cancel')}
          </Button>
        </form>
      )}
      {moving !== null && (
        <form
          aria-label={t('locations.tree.moveTitle', { name: textOf(moving, 'name') })}
          onSubmit={(e) => {
            e.preventDefault()
            void confirmMove()
          }}
        >
          <SelectField
            name="move_to"
            label={t('locations.tree.moveTarget')}
            value={moveTo}
            options={moveTargets(nodes, moving.record_id).map((r) => ({
              value: r.record_id,
              label: textOf(r, 'name') || textOf(r, 'code'),
            }))}
            placeholder={t('locations.tree.moveRoot')}
            invalid={fieldMarked(write.error, 'parent_id')}
            onChange={setMoveTo}
          />
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void confirmMove()} data-testid="loc-move-confirm">
            {t('locations.common.move')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setMoving(null)}>
            {t('locations.common.cancel')}
          </Button>
        </form>
      )}
      {tree.length === 0 ? (
        <p>{t('locations.common.empty')}</p>
      ) : (
        <table role="treegrid">
          <thead>
            <tr>
              <th>{t('locations.common.code')}</th>
              <th>{t('locations.common.name')}</th>
              <th>{t('locations.common.kind')}</th>
              <th>{t('locations.common.address')}</th>
              <th>{t('locations.common.state')}</th>
              <th>{t('locations.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {tree.map(({ record: r, depth }) => (
              <tr key={r.record_id} role="row" aria-level={depth + 1} data-testid={`loc-row-${textOf(r, 'code')}`}>
                <td style={{ paddingLeft: `calc(${depth} * var(--space-4))` }}>{textOf(r, 'code')}</td>
                <td>{textOf(r, 'name')}</td>
                <td>{textOf(r, 'node_kind') || dash}</td>
                <td>{textOf(r, 'address') || dash}</td>
                <td>{t(isActive(r) ? 'locations.common.active' : 'locations.common.retired')}</td>
                <td>
                  {isActive(r) && (
                    <>
                      <Button variant="secondary" size="sm" onClick={() => open('new', r.record_id)}>
                        {t('locations.tree.addChild')}
                      </Button>
                      <Button variant="secondary" size="sm" onClick={() => open(r)}>
                        {t('locations.common.edit')}
                      </Button>
                      <Button
                        variant="secondary"
                        size="sm"
                        onClick={() => {
                          write.clearError()
                          setMoveTo(textOf(r, 'parent_id'))
                          setMoving(r)
                        }}
                      >
                        {t('locations.common.move')}
                      </Button>
                      <Button variant="danger" size="sm" onClick={() => setRetiring(r)}>
                        {t('locations.common.retire')}
                      </Button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <ConfirmDialog
        open={retiring !== null}
        title={t('locations.common.retireTitle')}
        body={t('locations.common.retireBody', { name: retiring ? textOf(retiring, 'name') : '' })}
        confirmText={t('locations.common.retire')}
        cancelText={t('locations.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </LocationsShell>
  )
}

export default function LocationTreePage() {
  return (
    <LocationsIntlProvider>
      <LocationTreeInner />
    </LocationsIntlProvider>
  )
}
