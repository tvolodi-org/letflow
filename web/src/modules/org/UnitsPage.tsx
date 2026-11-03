/** UnitsPage — GH 3609 / REQ-669, style S1. The org unit tree: the TreeView on the left, the unit in the detail
 *  panel on the right (create root or child, edit, move, retire). The tree is built here from all loaded units
 *  (`parent` is not a queried column). With the retired switch off only active rows are loaded, so an active child
 *  of a retired parent shows as a root; the move picker is built from the loaded active rows and the server's
 *  cycle answer stays the authority. Move is a short single-answer action, so it is a dialog; everything else is
 *  the panel (skill rule 2a). Styling only: the writes and their rules are unchanged. */
import { useState } from 'react'
import { Archive, Move, Plus } from 'lucide-react'
import { useIntl } from 'react-intl'
import { useAccess } from '@/auth/access'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Dialog } from '@/components/ui/Dialog'
import { FormRow, FormSection } from '@/components/ui/FormSection'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { orgApi, type UnitCreate, type UnitUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import {
  OrgErrorAlert,
  OrgSelectField,
  OrgTextField,
  fieldMarked,
  useOrgRows,
} from './OrgListShell'
import { OrgDetail, OrgEmpty, OrgForm, OrgScreen, OrgStatus, OrgTree } from './OrgScreen'
import {
  LEGAL_ENTITY,
  SITE,
  UNIT,
  branchIds,
  errorMessageId,
  isActive,
  moveTargets,
  reasonOf,
  textOf,
  unitPath,
  unitTreeNodes,
} from './orgModel'
import { ORG_STRUCTURE_WRITE } from './orgPermissions'
import { useOrgWrite } from './useOrgWrite'

type Cmd =
  | { op: 'create'; body: UnitCreate }
  | { op: 'update'; id: string; body: UnitUpdate }
  | { op: 'move'; id: string; parentId: string | null }
  | { op: 'retire'; id: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return orgApi.createUnit(cmd.body, key)
  if (cmd.op === 'update') return orgApi.updateUnit(cmd.id, cmd.body, key)
  if (cmd.op === 'move') return orgApi.moveUnit(cmd.id, cmd.parentId, key)
  return orgApi.retireUnit(cmd.id, key)
}

type Panel = { kind: 'new'; parent: string } | { kind: 'record'; id: string } | null

const option = (r: EntityRecord) => ({ value: r.record_id, label: textOf(r, 'name') || textOf(r, 'code') })

function UnitsInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const canWrite = useAccess().can(ORG_STRUCTURE_WRITE)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useOrgRows(UNIT, showRetired)
  const companies = useOrgRows(LEGAL_ENTITY, true)
  const sites = useOrgRows(SITE, true)
  const write = useOrgWrite<Cmd>(run)
  const [panel, setPanel] = useState<Panel>(null)
  const [moving, setMoving] = useState<EntityRecord | null>(null)
  const [moveTo, setMoveTo] = useState('')
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)
  const [collapsed, setCollapsed] = useState<string[]>([])

  const unitRows = rows.data ?? []
  const companyRows = companies.data ?? []
  const siteRows = sites.data ?? []
  const selected = panel?.kind === 'record' ? unitRows.find((r) => r.record_id === panel.id) : undefined
  const nodes = unitTreeNodes(unitRows)
  const expandedIds = branchIds(nodes).filter((id) => !collapsed.includes(id))

  function openPanel(next: Panel) {
    write.clearError()
    setPanel(next)
  }

  async function save(form: { code: string; name: string; legal_entity_id: string; site_id: string; parent: string }) {
    const isNew = panel?.kind === 'new'
    const result = await write.submit(
      isNew || !selected
        ? {
            op: 'create',
            body: {
              code: form.code,
              name: form.name,
              legal_entity_id: form.legal_entity_id,
              site_id: form.site_id,
              ...(form.parent !== '' ? { parent: form.parent } : {}),
            },
          }
        : {
            op: 'update',
            id: selected.record_id,
            body: { name: form.name, legal_entity_id: form.legal_entity_id, site_id: form.site_id },
          },
    )
    if (result === 'ok') {
      toast.success(t(isNew ? 'org.common.created' : 'org.common.saved'))
      if (isNew) setPanel(null)
    }
    if (result === 'notFound') setPanel(null)
  }

  async function confirmMove() {
    if (!moving) return
    const result = await write.submit({ op: 'move', id: moving.record_id, parentId: moveTo === '' ? null : moveTo })
    if (result !== 'error') setMoving(null)
    if (result === 'ok') toast.success(t('org.units.moved'))
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    const result = await write.submit({ op: 'retire', id: target.record_id })
    if (result === 'ok') {
      toast.success(t('org.common.retiredDone'))
      setPanel(null)
    }
  }

  const createLabel = t('org.units.create')
  const activeSelected = selected !== undefined && isActive(selected)
  const detail =
    panel?.kind === 'new' || selected ? (
      <OrgDetail
        title={selected ? textOf(selected, 'name') || textOf(selected, 'code') : t('org.units.new')}
        path={selected ? unitPath(unitRows, selected.record_id) || undefined : undefined}
        status={selected ? <OrgStatus active={isActive(selected)} /> : undefined}
        actions={
          canWrite && selected && activeSelected ? (
            <>
              <Button
                variant="secondary"
                size="sm"
                icon={<Plus className="lf-icon" aria-hidden="true" />}
                onClick={() => openPanel({ kind: 'new', parent: selected.record_id })}
                data-testid="org-add-child"
              >
                {t('org.units.addChild')}
              </Button>
              <Button
                variant="secondary"
                size="sm"
                icon={<Move className="lf-icon" aria-hidden="true" />}
                onClick={() => {
                  write.clearError()
                  setMoveTo(textOf(selected, 'parent'))
                  setMoving(selected)
                }}
                data-testid="org-move-open"
              >
                {t('org.units.move')}
              </Button>
              <Button
                variant="danger"
                size="sm"
                icon={<Archive className="lf-icon" aria-hidden="true" />}
                onClick={() => setRetiring(selected)}
                data-testid="org-retire"
              >
                {t('org.common.retire')}
              </Button>
            </>
          ) : undefined
        }
        onClose={() => openPanel(null)}
      >
        <UnitForm
          key={selected?.record_id ?? `new-${panel?.kind === 'new' ? panel.parent : ''}`}
          record={selected ?? null}
          parent={panel?.kind === 'new' ? panel.parent : ''}
          parentCompany={
            panel?.kind === 'new' && panel.parent !== ''
              ? textOf(unitRows.find((u) => u.record_id === panel.parent) ?? ({} as EntityRecord), 'legal_entity_id')
              : ''
          }
          readOnly={!canWrite || (selected !== undefined && !activeSelected)}
          units={unitRows}
          companies={companyRows.filter(isActive).map(option)}
          sites={siteRows.filter(isActive).map(option)}
          writeError={moving === null ? write.error : null}
          saving={write.isPending}
          onSubmit={(f) => void save(f)}
          onCancel={() => openPanel(null)}
        />
      </OrgDetail>
    ) : null

  return (
    <OrgScreen
      title={t('org.units.title')}
      lede={t('org.units.lede')}
      createLabel={createLabel}
      canWrite={canWrite}
      onCreate={() => openPanel({ kind: 'new', parent: '' })}
      queries={[rows, companies, sites]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      count={unitRows.length}
      detail={detail}
      escapeCloses={retiring === null && moving === null}
      onClosePanel={() => openPanel(null)}
      master={
        nodes.length === 0 ? (
          <OrgEmpty canWrite={canWrite} createLabel={createLabel} onCreate={() => openPanel({ kind: 'new', parent: '' })} />
        ) : (
          <OrgTree
            label={t('org.units.title')}
            nodes={nodes}
            selectedId={selected?.record_id ?? null}
            showRetired={showRetired}
            expandedIds={expandedIds}
            onSelect={(id) => openPanel({ kind: 'record', id })}
            onToggle={(id) => setCollapsed((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]))}
          />
        )
      }
    >
      <Dialog
        open={moving !== null}
        title={t('org.units.moveTitle', { name: moving ? textOf(moving, 'name') : '' })}
        confirmText={t('org.units.move')}
        cancelText={t('org.common.cancel')}
        onConfirm={() => void confirmMove()}
        onCancel={() => setMoving(null)}
        isLoading={write.isPending}
        error={moving !== null && write.error ? t(errorMessageId(write.error), { fields: (reasonOf(write.error).fields ?? []).join(', ') }) : null}
        testId="org-move"
      >
        {moving !== null && (
          <OrgSelectField
            name="move_to"
            label={t('org.units.moveTarget')}
            value={moveTo}
            options={moveTargets(unitRows, moving.record_id).map(option)}
            placeholder={t('org.units.moveRoot')}
            invalid={fieldMarked(write.error, 'parent_id')}
            onChange={setMoveTo}
          />
        )}
      </Dialog>
      <ConfirmDialog
        open={retiring !== null}
        title={t('org.common.retireTitle')}
        body={t('org.common.retireBody', { name: retiring ? textOf(retiring, 'name') : '' })}
        confirmText={t('org.common.retire')}
        cancelText={t('org.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </OrgScreen>
  )
}

function UnitForm(props: {
  record: EntityRecord | null
  parent: string
  /** Legal company a new child unit starts with (the parent's); empty for a root. */
  parentCompany: string
  readOnly: boolean
  units: EntityRecord[]
  companies: { value: string; label: string }[]
  sites: { value: string; label: string }[]
  writeError: unknown
  saving: boolean
  onSubmit: (form: { code: string; name: string; legal_entity_id: string; site_id: string; parent: string }) => void
  onCancel: () => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const r = props.record
  const initial = {
    code: r ? textOf(r, 'code') : '',
    name: r ? textOf(r, 'name') : '',
    legal_entity_id: r ? textOf(r, 'legal_entity_id') : props.parentCompany,
    site_id: r ? textOf(r, 'site_id') : '',
    parent: r ? textOf(r, 'parent') : props.parent,
  }
  const [form, setForm] = useState(initial)
  const isNew = r === null
  const dirty = (Object.keys(initial) as (keyof typeof initial)[]).some((k) => form[k] !== initial[k])
  return (
    <OrgForm
      label={t(isNew ? 'org.common.create' : 'org.common.edit')}
      error={<OrgErrorAlert error={props.writeError} />}
      readOnly={props.readOnly}
      dirty={dirty}
      saving={props.saving}
      onSubmit={() => props.onSubmit(form)}
      onCancel={props.onCancel}
    >
      <FormSection>
        <FormRow>
          <OrgTextField
            name="code"
            label={t('org.common.code')}
            value={form.code}
            readOnly={!isNew || props.readOnly}
            mono
            width="s"
            hint={isNew ? undefined : t('org.common.codeHint')}
            onChange={(v) => setForm({ ...form, code: v })}
          />
          <OrgTextField
            name="name"
            label={t('org.common.name')}
            value={form.name}
            readOnly={props.readOnly}
            width="m"
            invalid={fieldMarked(props.writeError, 'name')}
            onChange={(v) => setForm({ ...form, name: v })}
          />
        </FormRow>
      </FormSection>
      <FormSection title={t('org.units.place')}>
        <FormRow>
          <OrgSelectField
            name="parent"
            label={t('org.units.parent')}
            value={form.parent}
            options={(isNew ? props.units.filter(isActive) : props.units).map(option)}
            placeholder={t('org.units.noParent')}
            disabled={!isNew || props.readOnly}
            hint={isNew ? undefined : t('org.units.parentHint')}
            width="m"
            invalid={fieldMarked(props.writeError, 'parent')}
            onChange={(v) => setForm({ ...form, parent: v })}
          />
          <OrgSelectField
            name="legal_entity_id"
            label={t('org.units.company')}
            value={form.legal_entity_id}
            options={props.companies}
            placeholder={t('org.units.choose')}
            disabled={props.readOnly}
            width="m"
            invalid={fieldMarked(props.writeError, 'legal_entity_id')}
            onChange={(v) => setForm({ ...form, legal_entity_id: v })}
          />
        </FormRow>
        <FormRow>
          <OrgSelectField
            name="site_id"
            label={t('org.units.site')}
            value={form.site_id}
            options={props.sites}
            placeholder={t('org.units.choose')}
            disabled={props.readOnly}
            width="m"
            invalid={fieldMarked(props.writeError, 'site_id')}
            onChange={(v) => setForm({ ...form, site_id: v })}
          />
        </FormRow>
      </FormSection>
    </OrgForm>
  )
}

export default function UnitsPage() {
  return (
    <OrgIntlProvider>
      <UnitsInner />
    </OrgIntlProvider>
  )
}
