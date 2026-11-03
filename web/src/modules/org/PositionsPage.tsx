/** PositionsPage — GH 3608 / REQ-670, style S2. Positions of the org units: the list (optionally of one unit) on the
 *  left, the record in the detail panel on the right (create, edit the name, retire). Code and unit are fixed after
 *  creation. Styling only: the writes and their rules are unchanged. */
import { useState } from 'react'
import { Archive } from 'lucide-react'
import { useIntl } from 'react-intl'
import { useAccess } from '@/auth/access'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { FormRow, FormSection } from '@/components/ui/FormSection'
import type { TreeNode } from '@/components/ui/TreeView'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { orgApi, type PositionCreate, type PositionUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import {
  OrgErrorAlert,
  OrgSelectField,
  OrgTextField,
  OrgUnitFilter,
  fieldMarked,
  labelOf,
  useOrgRows,
} from './OrgListShell'
import { OrgDetail, OrgEmpty, OrgForm, OrgScreen, OrgStatus, OrgTree } from './OrgScreen'
import { POSITION, UNIT, isActive, textOf, unitOptions } from './orgModel'
import { ORG_EMPLOYEES_WRITE } from './orgPermissions'
import { useOrgWrite } from './useOrgWrite'

type Cmd =
  | { op: 'create'; body: PositionCreate }
  | { op: 'update'; id: string; body: PositionUpdate }
  | { op: 'retire'; id: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return orgApi.createPosition(cmd.body, key)
  if (cmd.op === 'update') return orgApi.updatePosition(cmd.id, cmd.body, key)
  return orgApi.retirePosition(cmd.id, key)
}

type Panel = { kind: 'new' } | { kind: 'record'; id: string } | null

function PositionsInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const canWrite = useAccess().can(ORG_EMPLOYEES_WRITE)
  const [showRetired, setShowRetired] = useState(false)
  const [unitFilter, setUnitFilter] = useState('')
  const rows = useOrgRows(POSITION, showRetired, unitFilter)
  const units = useOrgRows(UNIT, true)
  const write = useOrgWrite<Cmd>(run)
  const [panel, setPanel] = useState<Panel>(null)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const items = rows.data ?? []
  const unitRows = units.data ?? []
  const selected = panel?.kind === 'record' ? items.find((r) => r.record_id === panel.id) : undefined
  const dash = t('org.common.dash')
  const nodes: TreeNode[] = items.map((r) => ({
    id: r.record_id,
    name: textOf(r, 'name') || textOf(r, 'code'),
    code: textOf(r, 'code'),
    meta: labelOf(unitRows, textOf(r, 'org_unit_id'), dash),
    retired: !isActive(r),
  }))

  function openPanel(next: Panel) {
    write.clearError()
    setPanel(next)
  }

  async function save(form: { code: string; name: string; org_unit_id: string }) {
    const isNew = panel?.kind === 'new'
    const result = await write.submit(
      isNew || !selected
        ? { op: 'create', body: { code: form.code, name: form.name, org_unit_id: form.org_unit_id } }
        : { op: 'update', id: selected.record_id, body: { name: form.name } },
    )
    if (result === 'ok') {
      toast.success(t(isNew ? 'org.common.created' : 'org.common.saved'))
      if (isNew) setPanel(null)
    }
    if (result === 'notFound') setPanel(null)
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

  const createLabel = t('org.positions.create')
  const detail =
    panel?.kind === 'new' || selected ? (
      <OrgDetail
        title={selected ? textOf(selected, 'name') || textOf(selected, 'code') : t('org.positions.new')}
        path={selected ? labelOf(unitRows, textOf(selected, 'org_unit_id'), dash) : undefined}
        status={selected ? <OrgStatus active={isActive(selected)} /> : undefined}
        actions={
          canWrite && selected && isActive(selected) ? (
            <Button
              variant="danger"
              size="sm"
              icon={<Archive className="lf-icon" aria-hidden="true" />}
              onClick={() => setRetiring(selected)}
              data-testid="org-retire"
            >
              {t('org.common.retire')}
            </Button>
          ) : undefined
        }
        onClose={() => openPanel(null)}
      >
        <PositionForm
          key={selected?.record_id ?? 'new'}
          record={selected ?? null}
          readOnly={!canWrite || (selected !== undefined && !isActive(selected))}
          units={unitOptions(unitRows.filter(isActive))}
          unitLabel={selected ? labelOf(unitRows, textOf(selected, 'org_unit_id'), dash) : ''}
          presetUnit={unitFilter}
          writeError={write.error}
          saving={write.isPending}
          onSubmit={(f) => void save(f)}
          onCancel={() => openPanel(null)}
        />
      </OrgDetail>
    ) : null

  return (
    <OrgScreen
      title={t('org.positions.title')}
      lede={t('org.positions.lede')}
      createLabel={createLabel}
      canWrite={canWrite}
      onCreate={() => openPanel({ kind: 'new' })}
      queries={[rows, units]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      count={nodes.length}
      detail={detail}
      escapeCloses={retiring === null}
      onClosePanel={() => openPanel(null)}
      master={
        <>
          <OrgUnitFilter value={unitFilter} onChange={setUnitFilter} options={unitOptions(unitRows)} />
          {nodes.length === 0 ? (
            <OrgEmpty canWrite={canWrite} createLabel={createLabel} onCreate={() => openPanel({ kind: 'new' })} />
          ) : (
            <OrgTree
              label={t('org.positions.title')}
              nodes={nodes}
              selectedId={selected?.record_id ?? null}
              showRetired={showRetired}
              expandedIds={[]}
              onSelect={(id) => openPanel({ kind: 'record', id })}
              onToggle={() => undefined}
            />
          )}
        </>
      }
    >
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

function PositionForm(props: {
  record: EntityRecord | null
  readOnly: boolean
  units: { value: string; label: string }[]
  unitLabel: string
  presetUnit: string
  writeError: unknown
  saving: boolean
  onSubmit: (form: { code: string; name: string; org_unit_id: string }) => void
  onCancel: () => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const initial = {
    code: props.record ? textOf(props.record, 'code') : '',
    name: props.record ? textOf(props.record, 'name') : '',
    org_unit_id: props.record ? textOf(props.record, 'org_unit_id') : props.presetUnit,
  }
  const [form, setForm] = useState(initial)
  const isNew = props.record === null
  return (
    <OrgForm
      label={t(isNew ? 'org.common.create' : 'org.common.edit')}
      error={<OrgErrorAlert error={props.writeError} />}
      readOnly={props.readOnly}
      dirty={form.code !== initial.code || form.name !== initial.name || form.org_unit_id !== initial.org_unit_id}
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
            invalid={fieldMarked(props.writeError, 'code')}
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
        <FormRow>
          {isNew ? (
            <OrgSelectField
              name="org_unit_id"
              label={t('org.positions.unit')}
              value={form.org_unit_id}
              options={props.units}
              placeholder={t('org.units.choose')}
              disabled={props.readOnly}
              width="m"
              invalid={fieldMarked(props.writeError, 'org_unit_id')}
              onChange={(v) => setForm({ ...form, org_unit_id: v })}
            />
          ) : (
            <OrgTextField
              name="org_unit_id"
              label={t('org.positions.unit')}
              value={props.unitLabel}
              readOnly
              width="m"
              onChange={() => undefined}
            />
          )}
        </FormRow>
      </FormSection>
    </OrgForm>
  )
}

export default function PositionsPage() {
  return (
    <OrgIntlProvider>
      <PositionsInner />
    </OrgIntlProvider>
  )
}
