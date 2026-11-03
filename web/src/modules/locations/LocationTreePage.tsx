/** LocationTreePage — GH 3607 / REQ-671, restyled by T-1172 (style S3). The location tree on the left, the chosen
 *  record on the right (MasterDetail; owner rule 2026-11-03: viewing and editing one record happens in the detail
 *  panel, not in a modal). Create (root or child, free or composed address), edit, move, retire. The tree is built
 *  here from the loaded nodes (`parent_id`). With the retired switch off only active rows are loaded, so an active
 *  child of a retired parent shows as a root; the move picker is built from the loaded active rows and the server's
 *  cycle answer stays the authority. Move and retire are short single-answer actions, so they are dialogs. */
import { Fragment, useState } from 'react'
import { useIntl } from 'react-intl'
import { Plus, X } from 'lucide-react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox, Radio } from '@/components/ui/Checkbox'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Dialog } from '@/components/ui/Dialog'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { EmptyState } from '@/components/ui/EmptyState'
import { Field } from '@/components/ui/Field'
import { FormActions, FormRow, FormSection } from '@/components/ui/FormSection'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { TreeView } from '@/components/ui/TreeView'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, locationsApi, type NodeCreate, type NodeUpdate } from './locations.api'
import { LocationsIntlProvider } from './LocationsIntlProvider'
import { LocationsShell, fieldMarked, useErrorText, useLocationRows } from './LocationsShell'
import {
  LOCATION_NODE,
  LOCATION_TYPES,
  isActive,
  kindSuggestions,
  moveTargets,
  pathOf,
  textOf,
  toTreeNodes,
  treeOptions,
} from './locationsModel'
import { useLocationsWrite, type LocationsWriteResult } from './useLocationsWrite'

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

function formOf(record: EntityRecord | null, parent: string): Form {
  if (record === null) return { ...EMPTY, parent_id: parent }
  return {
    code: textOf(record, 'code'),
    name: textOf(record, 'name'),
    node_kind: textOf(record, 'node_kind'),
    segment: textOf(record, 'segment'),
    mode: 'free',
    address: textOf(record, 'address'),
    location_type: textOf(record, 'location_type'),
    parent_id: textOf(record, 'parent_id'),
  }
}

type Write = ReturnType<typeof useLocationsWrite<Cmd>>

/** The create / edit form of the detail panel. Keyed by the record, so a new selection starts from its values. */
function NodeForm(props: {
  record: EntityRecord | null
  parent: string
  nodes: EntityRecord[]
  write: Write
  onDone: (result: LocationsWriteResult) => void
  onCancel: () => void
}) {
  const { record, nodes, write } = props
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [form, setForm] = useState<Form>(() => formOf(record, props.parent))
  const initial = formOf(record, props.parent)
  const dirty = JSON.stringify(form) !== JSON.stringify(initial)
  const isNew = record === null
  const kinds = kindSuggestions(nodes)
  const invalid = (name: string) => (fieldMarked(write.error, name) ? t('locations.common.fieldInvalid') : undefined)

  async function save() {
    const result = await write.submit(
      record === null
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
            id: record.record_id,
            body: {
              name: form.name,
              node_kind: form.node_kind,
              segment: form.segment === '' ? null : form.segment,
              address: form.address === '' ? null : form.address,
              location_type: form.location_type === '' ? null : form.location_type,
            },
          },
    )
    props.onDone(result)
  }

  return (
    <form
      className="lf-form"
      aria-label={isNew ? t('locations.tree.createTitle') : form.name || form.code}
      onSubmit={(e) => {
        e.preventDefault()
        void save()
      }}
    >
      <FormSection>
        <FormRow>
          <Field label={t('locations.common.code')} width="s" mono readOnly={!isNew} hint={isNew ? undefined : t('locations.tree.codeHint')} error={invalid('code')}>
            <input name="code" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} />
          </Field>
          <Field label={t('locations.common.name')} width="m" error={invalid('name')}>
            <input name="name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </Field>
        </FormRow>
        <FormRow>
          <Field label={t('locations.common.kind')} width="m" error={invalid('node_kind')}>
            <input name="node_kind" list="locations-kinds" value={form.node_kind} onChange={(e) => setForm({ ...form, node_kind: e.target.value })} />
          </Field>
          <datalist id="locations-kinds">
            {kinds.map((k) => (
              <option key={k} value={k} />
            ))}
          </datalist>
          <Field label={t('locations.common.segment')} width="s" mono error={invalid('segment')}>
            <input name="segment" value={form.segment} onChange={(e) => setForm({ ...form, segment: e.target.value })} />
          </Field>
        </FormRow>
      </FormSection>
      <FormSection title={t('locations.tree.sectionPlace')}>
        {isNew && (
          <FormRow>
            <Select
              label={t('locations.common.parent')}
              width="l"
              name="parent_id"
              value={form.parent_id}
              options={treeOptions(nodes, 'parent_id')}
              placeholder={t('locations.tree.noParent')}
              error={invalid('parent_id')}
              onChange={(v) => setForm({ ...form, parent_id: v })}
            />
          </FormRow>
        )}
        <FormRow>
          <Select
            label={t('locations.common.locationType')}
            width="m"
            name="location_type"
            value={form.location_type}
            options={LOCATION_TYPES.map((v) => ({ value: v, label: t(`locations.type.${v}`) }))}
            placeholder={t('locations.tree.noType')}
            error={invalid('location_type')}
            onChange={(v) => setForm({ ...form, location_type: v })}
          />
        </FormRow>
      </FormSection>
      <FormSection title={t('locations.tree.addressMode')}>
        {isNew && (
          <div className="lf-btn-row">
            <Radio name="address_mode" label={t('locations.tree.addressFree')} checked={form.mode === 'free'} onChange={() => setForm({ ...form, mode: 'free' })} />
            <Radio name="address_mode" label={t('locations.tree.addressCompose')} checked={form.mode === 'compose'} onChange={() => setForm({ ...form, mode: 'compose' })} />
          </div>
        )}
        {(!isNew || form.mode === 'free') && (
          <FormRow>
            <Field label={t('locations.common.address')} width="l" mono error={invalid('address')}>
              <input name="address" value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} />
            </Field>
          </FormRow>
        )}
      </FormSection>
      <FormActions
        dirty={dirty}
        saving={write.isPending}
        primary={
          <Button variant="primary" size="md" type="submit" loading={write.isPending} disabled={write.isPending} data-testid="loc-save">
            {t('locations.common.save')}
          </Button>
        }
        secondary={
          <Button variant="ghost" size="md" onClick={props.onCancel}>
            {t('locations.common.cancel')}
          </Button>
        }
      />
    </form>
  )
}

/** The read-only facts of a retired location. */
function NodeFacts({ record, nodes }: { record: EntityRecord; nodes: EntityRecord[] }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const dash = t('locations.common.dash')
  const type = textOf(record, 'location_type')
  const parent = nodes.find((n) => n.record_id === textOf(record, 'parent_id'))
  const rows: [string, string, boolean][] = [
    [t('locations.common.code'), textOf(record, 'code'), true],
    [t('locations.common.kind'), textOf(record, 'node_kind'), false],
    [t('locations.common.segment'), textOf(record, 'segment'), true],
    [t('locations.common.address'), textOf(record, 'address'), true],
    [t('locations.common.locationType'), type === '' ? '' : t(`locations.type.${type}`), false],
    [t('locations.common.parent'), parent ? textOf(parent, 'name') || textOf(parent, 'code') : '', false],
  ]
  return (
    <dl className="lf-dl">
      {rows.map(([label, value, mono]) => (
        <Fragment key={label}>
          <dt>{label}</dt>
          <dd className={mono ? 'mono' : undefined}>{value === '' ? dash : value}</dd>
        </Fragment>
      ))}
    </dl>
  )
}

function LocationTreeInner({ initialSelectedId }: { initialSelectedId?: string }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const errorText = useErrorText()
  const [showRetired, setShowRetired] = useState(false)
  const rows = useLocationRows(LOCATION_NODE, showRetired ? 'all' : 'active', [
    DELETED_FALSE,
    ...(showRetired ? [] : [ACTIVE_TRUE]),
  ])
  const write = useLocationsWrite<Cmd>(run)
  const [selectedId, setSelectedId] = useState<string | null>(initialSelectedId ?? null)
  const [creating, setCreating] = useState<{ parent: string } | null>(null)
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(new Set())
  const [moving, setMoving] = useState<EntityRecord | null>(null)
  const [moveTo, setMoveTo] = useState('')
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const nodes = rows.data ?? []
  const treeNodes = toTreeNodes(nodes)
  const expandable = new Set(nodes.map((n) => textOf(n, 'parent_id')).filter((p) => p !== ''))
  const expandedIds = [...expandable].filter((id) => !collapsed.has(id))
  const selected = nodes.find((n) => n.record_id === selectedId) ?? null
  const panelOpen = creating !== null || selected !== null

  function select(id: string) {
    write.clearError()
    setCreating(null)
    setSelectedId(id)
  }
  function startCreate(parent = '') {
    write.clearError()
    setSelectedId(null)
    setCreating({ parent })
  }
  function closePanel() {
    write.clearError()
    setCreating(null)
    setSelectedId(null)
  }
  function toggle(id: string) {
    setCollapsed((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function formDone(result: LocationsWriteResult) {
    if (result === 'ok') {
      toast.success(t(creating !== null ? 'locations.toast.created' : 'locations.toast.updated'))
      closePanel()
    } else if (result === 'notFound') {
      // the record is gone: close the panel but keep the error banner that says so
      setCreating(null)
      setSelectedId(null)
    }
  }

  async function confirmMove() {
    if (!moving) return
    const result = await write.submit({ op: 'move', id: moving.record_id, parentId: moveTo === '' ? null : moveTo })
    if (result !== 'error') {
      if (result === 'ok') toast.success(t('locations.toast.moved'))
      setMoving(null)
    }
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    const result = await write.submit({ op: 'retire', id: target.record_id })
    if (result !== 'error') {
      if (result === 'ok') toast.success(t('locations.toast.retired'))
      setRetiring(null)
    }
  }

  const dialogOpen = moving !== null || retiring !== null
  const createButton = (
    <Button variant="primary" size="md" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={() => startCreate()} data-testid="loc-create">
      {t('locations.common.create')}
    </Button>
  )

  let detail
  if (creating !== null) {
    detail = (
      <>
        <DetailHeader
          title={t('locations.tree.createTitle')}
          path={creating.parent !== '' ? pathOf(nodes, creating.parent) || undefined : undefined}
          actions={<Button variant="ghost" size="sm" iconOnly label={t('locations.tree.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={closePanel} />}
        />
        <div className="lf-card__body">
          <NodeForm key={`new:${creating.parent}`} record={null} parent={creating.parent} nodes={nodes} write={write} onDone={formDone} onCancel={closePanel} />
        </div>
      </>
    )
  } else if (selected !== null) {
    const active = isActive(selected)
    detail = (
      <>
        <DetailHeader
          title={textOf(selected, 'name') || textOf(selected, 'code')}
          path={pathOf(nodes, selected.record_id) || undefined}
          status={
            <StatusPill tone={active ? 'success' : 'neutral'} glyph={active ? 'dot' : 'dash'}>
              {t(active ? 'locations.common.active' : 'locations.common.retired')}
            </StatusPill>
          }
          actions={
            <>
              {active && (
                <>
                  <Button variant="secondary" size="sm" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={() => startCreate(selected.record_id)}>
                    {t('locations.tree.addChild')}
                  </Button>
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => {
                      write.clearError()
                      setMoveTo(textOf(selected, 'parent_id'))
                      setMoving(selected)
                    }}
                  >
                    {t('locations.common.move')}
                  </Button>
                  <Button variant="danger" size="sm" onClick={() => setRetiring(selected)}>
                    {t('locations.common.retire')}
                  </Button>
                </>
              )}
              <Button variant="ghost" size="sm" iconOnly label={t('locations.tree.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={closePanel} />
            </>
          }
        />
        <div className="lf-card__body">
          {active ? (
            <NodeForm key={selected.record_id} record={selected} parent="" nodes={nodes} write={write} onDone={formDone} onCancel={closePanel} />
          ) : (
            <NodeFacts record={selected} nodes={nodes} />
          )}
        </div>
      </>
    )
  } else {
    detail = (
      <div className="lf-card__body">
        <EmptyState title={t('locations.tree.pickTitle')} text={t('locations.tree.pickHint')} data-testid="loc-pick-hint" />
      </div>
    )
  }

  return (
    <LocationsShell
      title={t('locations.tree.title')}
      eyebrow={t('locations.tree.eyebrow')}
      lede={t('locations.tree.lede')}
      queries={[rows]}
      actions={createButton}
    >
      {write.error && !dialogOpen ? <Banner tone="danger"><span id="locations-error">{errorText(write.error)}</span></Banner> : null}
      {nodes.length === 0 && !panelOpen ? (
        <EmptyState
          title={t('locations.tree.emptyTitle')}
          text={t('locations.tree.emptyText')}
          action={
            <Button variant="primary" size="md" onClick={() => startCreate()}>
              {t('locations.common.create')}
            </Button>
          }
        />
      ) : (
        <div
          onKeyDown={(e) => {
            if (e.key === 'Escape' && !e.defaultPrevented && panelOpen && !dialogOpen) closePanel()
          }}
        >
          <MasterDetail
            master={
              <>
                <div className="lf-md__tools">
                  <div className="lf-btn-row">
                    <Checkbox label={t('locations.common.showRetired')} checked={showRetired} onChange={setShowRetired} />
                    <span className="caption lf-faint">
                      <span className="mono">{nodes.length}</span> {t('locations.tree.countUnit')}
                    </span>
                  </div>
                </div>
                <TreeView
                  nodes={treeNodes}
                  selectedId={selectedId}
                  expandedIds={expandedIds}
                  onSelect={select}
                  onToggle={toggle}
                  showRetired={showRetired}
                  aria-label={t('locations.tree.treeLabel')}
                  labels={{
                    expand: t('locations.tree.expand'),
                    collapse: t('locations.tree.collapse'),
                    retired: t('locations.common.retired'),
                    loading: t('locations.tree.loading'),
                  }}
                />
              </>
            }
            detail={detail}
          />
        </div>
      )}
      <Dialog
        open={moving !== null}
        title={t('locations.tree.moveTitle', { name: moving ? textOf(moving, 'name') : '' })}
        confirmText={t('locations.common.move')}
        cancelText={t('locations.common.cancel')}
        isLoading={write.isPending}
        error={moving !== null && write.error ? errorText(write.error) : null}
        onConfirm={() => void confirmMove()}
        onCancel={() => setMoving(null)}
        testId="loc-move"
      >
        {moving !== null && (
          <Select
            label={t('locations.tree.moveTarget')}
            name="move_to"
            value={moveTo}
            options={moveTargets(nodes, moving.record_id).map((r) => ({
              value: r.record_id,
              label: textOf(r, 'name') || textOf(r, 'code'),
            }))}
            placeholder={t('locations.tree.moveRoot')}
            error={fieldMarked(write.error, 'parent_id') ? t('locations.common.fieldInvalid') : undefined}
            onChange={setMoveTo}
          />
        )}
      </Dialog>
      <ConfirmDialog
        open={retiring !== null}
        title={t('locations.common.retireTitle')}
        body={t('locations.common.retireBody', { name: retiring ? textOf(retiring, 'name') : '' })}
        confirmText={t('locations.common.retire')}
        cancelText={t('locations.common.cancel')}
        confirmVariant="danger"
        isLoading={write.isPending}
        error={retiring !== null && write.error ? errorText(write.error) : null}
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </LocationsShell>
  )
}

/** `initialSelectedId` opens the detail panel on a record at first render (the screen harness uses it). */
export default function LocationTreePage({ initialSelectedId }: { initialSelectedId?: string } = {}) {
  return (
    <LocationsIntlProvider>
      <LocationTreeInner initialSelectedId={initialSelectedId} />
    </LocationsIntlProvider>
  )
}
