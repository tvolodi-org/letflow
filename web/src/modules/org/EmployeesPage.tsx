/** EmployeesPage — GH 3608 / REQ-670, style S2. Employees of the org units: the list (optionally of one unit) on the
 *  left, the record in the detail panel on the right (create, edit name and user link, retire); the transfer to a unit
 *  and position is a short single-answer dialog. The user picker reads the tenant's users; without UsersManage that call
 *  is refused and the picker degrades to a note. Styling only: the writes and their rules are unchanged. */
import { useState } from 'react'
import { Archive, ArrowRightLeft } from 'lucide-react'
import { useIntl } from 'react-intl'
import { useAccess } from '@/auth/access'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Dialog } from '@/components/ui/Dialog'
import { FormRow, FormSection } from '@/components/ui/FormSection'
import type { TreeNode } from '@/components/ui/TreeView'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { orgApi, type EmployeeCreate, type EmployeeTransfer, type EmployeeUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import {
  OrgErrorAlert,
  OrgSelectField,
  OrgTextField,
  OrgUnitFilter,
  fieldMarked,
  labelOf,
  useOrgRows,
  useUserSearch,
} from './OrgListShell'
import { OrgDetail, OrgEmpty, OrgForm, OrgScreen, OrgStatus, OrgTree } from './OrgScreen'
import { EMPLOYEE, POSITION, UNIT, errorMessageId, isActive, positionsOfUnit, reasonOf, textOf, unitOptions } from './orgModel'
import { ORG_EMPLOYEES_WRITE } from './orgPermissions'
import { useOrgWrite } from './useOrgWrite'

type Cmd =
  | { op: 'create'; body: EmployeeCreate }
  | { op: 'update'; id: string; body: EmployeeUpdate }
  | { op: 'transfer'; id: string; body: EmployeeTransfer }
  | { op: 'retire'; id: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return orgApi.createEmployee(cmd.body, key)
  if (cmd.op === 'update') return orgApi.updateEmployee(cmd.id, cmd.body, key)
  if (cmd.op === 'transfer') return orgApi.transferEmployee(cmd.id, cmd.body, key)
  return orgApi.retireEmployee(cmd.id, key)
}

const positionOption = (r: EntityRecord) => ({ value: r.record_id, label: textOf(r, 'name') || textOf(r, 'code') })

type Panel = { kind: 'new' } | { kind: 'record'; id: string } | null

interface EmployeeValues {
  code: string
  full_name: string
  org_unit_id: string
  position_id: string
  user_id: string
}

function EmployeesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const canWrite = useAccess().can(ORG_EMPLOYEES_WRITE)
  const [showRetired, setShowRetired] = useState(false)
  const [unitFilter, setUnitFilter] = useState('')
  const rows = useOrgRows(EMPLOYEE, showRetired, unitFilter)
  const units = useOrgRows(UNIT, true)
  const positions = useOrgRows(POSITION, true)
  const write = useOrgWrite<Cmd>(run)
  const [panel, setPanel] = useState<Panel>(null)
  const [userLinked, setUserLinked] = useState(false)
  const [transferring, setTransferring] = useState<EntityRecord | null>(null)
  const [transferTo, setTransferTo] = useState({ org_unit_id: '', position_id: '' })
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const items = rows.data ?? []
  const unitRows = units.data ?? []
  const positionRows = positions.data ?? []
  const selected = panel?.kind === 'record' ? items.find((r) => r.record_id === panel.id) : undefined
  const dash = t('org.common.dash')
  const nameOf = (r: EntityRecord) => textOf(r, 'full_name') || textOf(r, 'code')
  const nodes: TreeNode[] = items.map((r) => ({
    id: r.record_id,
    name: nameOf(r),
    code: textOf(r, 'code'),
    meta: labelOf(unitRows, textOf(r, 'org_unit_id'), dash),
    retired: !isActive(r),
  }))

  function openPanel(next: Panel) {
    write.clearError()
    setUserLinked(false)
    setPanel(next)
  }

  async function save(form: EmployeeValues) {
    const isNew = panel?.kind === 'new'
    setUserLinked(form.user_id !== '')
    const result = await write.submit(
      isNew || !selected
        ? {
            op: 'create',
            body: {
              code: form.code,
              full_name: form.full_name,
              org_unit_id: form.org_unit_id,
              ...(form.position_id !== '' ? { position_id: form.position_id } : {}),
              ...(form.user_id !== '' ? { user_id: form.user_id } : {}),
            },
          }
        : {
            op: 'update',
            id: selected.record_id,
            body: { full_name: form.full_name, user_id: form.user_id === '' ? null : form.user_id },
          },
    )
    if (result === 'ok') {
      toast.success(t(isNew ? 'org.common.created' : 'org.common.saved'))
      if (isNew) setPanel(null)
    }
    if (result === 'notFound') setPanel(null)
  }

  async function confirmTransfer() {
    if (!transferring) return
    setUserLinked(false)
    const result = await write.submit({
      op: 'transfer',
      id: transferring.record_id,
      body: {
        org_unit_id: transferTo.org_unit_id,
        position_id: transferTo.position_id === '' ? null : transferTo.position_id,
      },
    })
    if (result !== 'error') setTransferring(null)
    if (result === 'ok') toast.success(t('org.employees.transferred'))
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    setUserLinked(false)
    const result = await write.submit({ op: 'retire', id: target.record_id })
    if (result === 'ok') {
      toast.success(t('org.common.retiredDone'))
      setPanel(null)
    }
  }

  const createLabel = t('org.employees.create')
  const activeSelected = selected !== undefined && isActive(selected)
  const pathOf = (r: EntityRecord) => {
    const unit = labelOf(unitRows, textOf(r, 'org_unit_id'), dash)
    const position = textOf(r, 'position_id')
    return position === '' ? unit : `${unit} / ${labelOf(positionRows, position, dash)}`
  }
  const detail =
    panel?.kind === 'new' || selected ? (
      <OrgDetail
        title={selected ? nameOf(selected) : t('org.employees.new')}
        path={selected ? pathOf(selected) : undefined}
        status={selected ? <OrgStatus active={isActive(selected)} /> : undefined}
        actions={
          canWrite && selected && activeSelected ? (
            <>
              <Button
                variant="secondary"
                size="sm"
                icon={<ArrowRightLeft className="lf-icon" aria-hidden="true" />}
                onClick={() => {
                  write.clearError()
                  setTransferTo({ org_unit_id: textOf(selected, 'org_unit_id'), position_id: textOf(selected, 'position_id') })
                  setTransferring(selected)
                }}
                data-testid="org-transfer-open"
              >
                {t('org.employees.transfer')}
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
        <EmployeeForm
          key={selected?.record_id ?? 'new'}
          record={selected ?? null}
          readOnly={!canWrite || (selected !== undefined && !activeSelected)}
          units={unitRows}
          positions={positionRows}
          presetUnit={unitFilter}
          writeError={transferring === null ? write.error : null}
          userLinked={userLinked}
          saving={write.isPending}
          onSubmit={(f) => void save(f)}
          onCancel={() => openPanel(null)}
        />
      </OrgDetail>
    ) : null

  return (
    <OrgScreen
      title={t('org.employees.title')}
      lede={t('org.employees.lede')}
      createLabel={createLabel}
      canWrite={canWrite}
      onCreate={() => openPanel({ kind: 'new' })}
      queries={[rows, units, positions]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      count={nodes.length}
      detail={detail}
      escapeCloses={retiring === null && transferring === null}
      onClosePanel={() => openPanel(null)}
      master={
        <>
          <OrgUnitFilter value={unitFilter} onChange={setUnitFilter} options={unitOptions(unitRows)} />
          {nodes.length === 0 ? (
            <OrgEmpty canWrite={canWrite} createLabel={createLabel} onCreate={() => openPanel({ kind: 'new' })} />
          ) : (
            <OrgTree
              label={t('org.employees.title')}
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
      <Dialog
        open={transferring !== null}
        title={transferring ? t('org.employees.transferTitle', { name: nameOf(transferring) }) : ''}
        confirmText={t('org.employees.transfer')}
        cancelText={t('org.common.cancel')}
        onConfirm={() => void confirmTransfer()}
        onCancel={() => setTransferring(null)}
        isLoading={write.isPending}
        error={
          transferring !== null && write.error
            ? t(errorMessageId(write.error), { fields: (reasonOf(write.error).fields ?? []).join(', ') })
            : null
        }
        testId="org-transfer"
      >
        {transferring !== null && (
          <FormSection>
            <OrgSelectField
              name="transfer_unit"
              label={t('org.employees.unit')}
              value={transferTo.org_unit_id}
              options={unitOptions(unitRows.filter(isActive))}
              placeholder={t('org.units.choose')}
              invalid={fieldMarked(write.error, 'org_unit_id')}
              onChange={(v) => setTransferTo({ org_unit_id: v, position_id: '' })}
            />
            <OrgSelectField
              name="transfer_position"
              label={t('org.employees.position')}
              value={transferTo.position_id}
              options={positionsOfUnit(positionRows, transferTo.org_unit_id).map(positionOption)}
              placeholder={t('org.employees.noPosition')}
              invalid={fieldMarked(write.error, 'position_id')}
              onChange={(v) => setTransferTo({ ...transferTo, position_id: v })}
            />
          </FormSection>
        )}
      </Dialog>
      <ConfirmDialog
        open={retiring !== null}
        title={t('org.common.retireTitle')}
        body={t('org.common.retireBody', { name: retiring ? nameOf(retiring) : '' })}
        confirmText={t('org.common.retire')}
        cancelText={t('org.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </OrgScreen>
  )
}

function EmployeeForm(props: {
  record: EntityRecord | null
  readOnly: boolean
  units: EntityRecord[]
  positions: EntityRecord[]
  presetUnit: string
  writeError: unknown
  userLinked: boolean
  saving: boolean
  onSubmit: (form: EmployeeValues) => void
  onCancel: () => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const dash = t('org.common.dash')
  const r = props.record
  const initial: EmployeeValues = {
    code: r ? textOf(r, 'code') : '',
    full_name: r ? textOf(r, 'full_name') : '',
    org_unit_id: r ? textOf(r, 'org_unit_id') : props.presetUnit,
    position_id: r ? textOf(r, 'position_id') : '',
    user_id: r ? textOf(r, 'user_id') : '',
  }
  const [form, setForm] = useState(initial)
  const [userSearch, setUserSearch] = useState('')
  const users = useUserSearch(userSearch, !props.readOnly)
  const isNew = r === null
  const userOptions = (() => {
    const found = (users.data ?? []).map((u) => ({ value: u.id, label: `${u.display_name} — ${u.email}` }))
    if (form.user_id !== '' && !found.some((o) => o.value === form.user_id)) found.unshift({ value: form.user_id, label: form.user_id })
    return found
  })()
  return (
    <OrgForm
      label={t(isNew ? 'org.common.create' : 'org.common.edit')}
      error={<OrgErrorAlert error={props.writeError} userLinked={props.userLinked} />}
      readOnly={props.readOnly}
      dirty={(Object.keys(initial) as (keyof EmployeeValues)[]).some((k) => form[k] !== initial[k])}
      saving={props.saving}
      onSubmit={() => props.onSubmit(form)}
      onCancel={props.onCancel}
    >
      <FormSection>
        <FormRow>
          <OrgTextField
            name="code"
            label={t('org.employees.personnelNumber')}
            value={form.code}
            readOnly={!isNew || props.readOnly}
            mono
            width="s"
            hint={isNew ? undefined : t('org.common.codeHint')}
            invalid={fieldMarked(props.writeError, 'code')}
            onChange={(v) => setForm({ ...form, code: v })}
          />
          <OrgTextField
            name="full_name"
            label={t('org.employees.fullName')}
            value={form.full_name}
            readOnly={props.readOnly}
            width="m"
            invalid={fieldMarked(props.writeError, 'full_name')}
            onChange={(v) => setForm({ ...form, full_name: v })}
          />
        </FormRow>
        <FormRow>
          {isNew ? (
            <>
              <OrgSelectField
                name="org_unit_id"
                label={t('org.employees.unit')}
                value={form.org_unit_id}
                options={unitOptions(props.units.filter(isActive))}
                placeholder={t('org.units.choose')}
                disabled={props.readOnly}
                width="m"
                invalid={fieldMarked(props.writeError, 'org_unit_id')}
                onChange={(v) => setForm({ ...form, org_unit_id: v, position_id: '' })}
              />
              <OrgSelectField
                name="position_id"
                label={t('org.employees.position')}
                value={form.position_id}
                options={positionsOfUnit(props.positions, form.org_unit_id).map(positionOption)}
                placeholder={t('org.employees.noPosition')}
                disabled={props.readOnly}
                width="m"
                invalid={fieldMarked(props.writeError, 'position_id')}
                onChange={(v) => setForm({ ...form, position_id: v })}
              />
            </>
          ) : (
            <>
              <OrgTextField
                name="org_unit_id"
                label={t('org.employees.unit')}
                value={labelOf(props.units, form.org_unit_id, dash)}
                readOnly
                width="m"
                onChange={() => undefined}
              />
              <OrgTextField
                name="position_id"
                label={t('org.employees.position')}
                value={labelOf(props.positions, form.position_id, dash)}
                readOnly
                width="m"
                onChange={() => undefined}
              />
            </>
          )}
        </FormRow>
        {!props.readOnly && (
          <FormRow>
            <OrgTextField name="user_search" label={t('org.employees.searchUser')} value={userSearch} width="m" onChange={setUserSearch} />
            <OrgSelectField
              name="user_id"
              label={t('org.employees.user')}
              value={form.user_id}
              options={userOptions}
              placeholder={t('org.employees.noUser')}
              width="m"
              invalid={fieldMarked(props.writeError, 'user_id')}
              onChange={(v) => setForm({ ...form, user_id: v })}
            />
          </FormRow>
        )}
        {!props.readOnly && users.isError && (
          <p className="lf-hint" role="status">
            {t('org.employees.usersUnavailable')}
          </p>
        )}
        {!props.readOnly && form.user_id !== '' && (
          <div className="lf-btn-row">
            <Button variant="secondary" size="sm" onClick={() => setForm({ ...form, user_id: '' })} data-testid="org-remove-user">
              {t('org.employees.removeUser')}
            </Button>
          </div>
        )}
      </FormSection>
    </OrgForm>
  )
}

export default function EmployeesPage() {
  return (
    <OrgIntlProvider>
      <EmployeesInner />
    </OrgIntlProvider>
  )
}
