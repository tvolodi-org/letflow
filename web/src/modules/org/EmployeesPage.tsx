/** EmployeesPage — GH 3608 / REQ-670. Employees of the org units: list (optionally of one unit), create, edit (name and
 *  user link), transfer to a unit and position, retire. Actions are offered on active rows only, as on UnitsPage.
 *  The user picker reads the tenant's users; without UsersManage that call is refused and the picker degrades to a note. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityRecord } from '@/types/api'
import { orgApi, type EmployeeCreate, type EmployeeTransfer, type EmployeeUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import {
  OrgErrorAlert,
  OrgListShell,
  OrgSelectField,
  OrgTextField,
  OrgUnitFilter,
  fieldMarked,
  labelOf,
  useOrgRows,
  useUserSearch,
} from './OrgListShell'
import { EMPLOYEE, POSITION, UNIT, isActive, positionsOfUnit, textOf, unitOptions } from './orgModel'
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

function EmployeesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [showRetired, setShowRetired] = useState(false)
  const [unitFilter, setUnitFilter] = useState('')
  const rows = useOrgRows(EMPLOYEE, showRetired, unitFilter)
  const units = useOrgRows(UNIT, true)
  const positions = useOrgRows(POSITION, true)
  const write = useOrgWrite<Cmd>(run)
  const [editing, setEditing] = useState<'new' | EntityRecord | null>(null)
  const [form, setForm] = useState({ code: '', full_name: '', org_unit_id: '', position_id: '', user_id: '' })
  const [userSearch, setUserSearch] = useState('')
  const [userLinked, setUserLinked] = useState(false)
  const [transferring, setTransferring] = useState<EntityRecord | null>(null)
  const [transferTo, setTransferTo] = useState({ org_unit_id: '', position_id: '' })
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)
  const users = useUserSearch(userSearch, editing !== null)

  const employeeRows = rows.data ?? []
  const unitRows = units.data ?? []
  const positionRows = positions.data ?? []
  const dash = t('org.common.dash')

  const userOptions = (() => {
    const found = (users.data ?? []).map((u) => ({ value: u.id, label: `${u.display_name} — ${u.email}` }))
    if (form.user_id !== '' && !found.some((o) => o.value === form.user_id)) found.unshift({ value: form.user_id, label: form.user_id })
    return found
  })()

  function open(target: 'new' | EntityRecord) {
    write.clearError()
    setUserLinked(false)
    setUserSearch('')
    setEditing(target)
    setForm(
      target === 'new'
        ? { code: '', full_name: '', org_unit_id: unitFilter, position_id: '', user_id: '' }
        : {
            code: textOf(target, 'code'),
            full_name: textOf(target, 'full_name'),
            org_unit_id: textOf(target, 'org_unit_id'),
            position_id: textOf(target, 'position_id'),
            user_id: textOf(target, 'user_id'),
          },
    )
  }

  async function save() {
    if (editing === null) return
    setUserLinked(form.user_id !== '')
    const result = await write.submit(
      editing === 'new'
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
            id: editing.record_id,
            body: { full_name: form.full_name, user_id: form.user_id === '' ? null : form.user_id },
          },
    )
    if (result === 'ok' || result === 'notFound') setEditing(null)
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
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    setUserLinked(false)
    await write.submit({ op: 'retire', id: target.record_id })
  }

  return (
    <OrgListShell
      title={t('org.employees.title')}
      queries={[rows, units, positions]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      actions={
        <Button variant="primary" size="md" onClick={() => open('new')} data-testid="org-create">
          {t('org.common.create')}
        </Button>
      }
    >
      <OrgUnitFilter value={unitFilter} onChange={setUnitFilter} options={unitOptions(unitRows)} />
      <OrgErrorAlert error={write.error} userLinked={userLinked} />
      {editing !== null && (
        <form
          aria-label={t(editing === 'new' ? 'org.common.create' : 'org.common.edit')}
          onSubmit={(e) => {
            e.preventDefault()
            void save()
          }}
        >
          <OrgTextField name="code" label={t('org.employees.personnelNumber')} value={form.code} readOnly={editing !== 'new'} invalid={fieldMarked(write.error, 'code')} onChange={(v) => setForm({ ...form, code: v })} />
          <OrgTextField name="full_name" label={t('org.employees.fullName')} value={form.full_name} invalid={fieldMarked(write.error, 'full_name')} onChange={(v) => setForm({ ...form, full_name: v })} />
          {editing === 'new' ? (
            <>
              <OrgSelectField
                name="org_unit_id"
                label={t('org.employees.unit')}
                value={form.org_unit_id}
                options={unitOptions(unitRows.filter(isActive))}
                placeholder={t('org.units.choose')}
                invalid={fieldMarked(write.error, 'org_unit_id')}
                onChange={(v) => setForm({ ...form, org_unit_id: v, position_id: '' })}
              />
              <OrgSelectField
                name="position_id"
                label={t('org.employees.position')}
                value={form.position_id}
                options={positionsOfUnit(positionRows, form.org_unit_id).map(positionOption)}
                placeholder={t('org.employees.noPosition')}
                invalid={fieldMarked(write.error, 'position_id')}
                onChange={(v) => setForm({ ...form, position_id: v })}
              />
            </>
          ) : (
            <>
              <OrgTextField name="org_unit_id" label={t('org.employees.unit')} value={labelOf(unitRows, form.org_unit_id, dash)} readOnly onChange={() => undefined} />
              <OrgTextField name="position_id" label={t('org.employees.position')} value={labelOf(positionRows, form.position_id, dash)} readOnly onChange={() => undefined} />
            </>
          )}
          <OrgTextField name="user_search" label={t('org.employees.searchUser')} value={userSearch} onChange={setUserSearch} />
          <OrgSelectField
            name="user_id"
            label={t('org.employees.user')}
            value={form.user_id}
            options={userOptions}
            placeholder={t('org.employees.noUser')}
            invalid={fieldMarked(write.error, 'user_id')}
            onChange={(v) => setForm({ ...form, user_id: v })}
          />
          {users.isError && <p role="status">{t('org.employees.usersUnavailable')}</p>}
          {form.user_id !== '' && (
            <Button variant="secondary" size="sm" onClick={() => setForm({ ...form, user_id: '' })} data-testid="org-remove-user">
              {t('org.employees.removeUser')}
            </Button>
          )}
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void save()} data-testid="org-save">
            {t('org.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setEditing(null)}>
            {t('org.common.cancel')}
          </Button>
        </form>
      )}
      {transferring !== null && (
        <form
          aria-label={t('org.employees.transferTitle', { name: textOf(transferring, 'full_name') })}
          onSubmit={(e) => {
            e.preventDefault()
            void confirmTransfer()
          }}
        >
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
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void confirmTransfer()} data-testid="org-transfer-confirm">
            {t('org.employees.transfer')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setTransferring(null)}>
            {t('org.common.cancel')}
          </Button>
        </form>
      )}
      {employeeRows.length === 0 ? (
        <p>{t('org.common.empty')}</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>{t('org.employees.personnelNumber')}</th>
              <th>{t('org.employees.fullName')}</th>
              <th>{t('org.employees.unit')}</th>
              <th>{t('org.employees.position')}</th>
              <th>{t('org.employees.userLinked')}</th>
              <th>{t('org.common.state')}</th>
              <th>{t('org.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {employeeRows.map((r) => (
              <tr key={r.record_id} data-testid={`org-row-${textOf(r, 'code')}`}>
                <td>{textOf(r, 'code')}</td>
                <td>{textOf(r, 'full_name')}</td>
                <td>{labelOf(unitRows, textOf(r, 'org_unit_id'), dash)}</td>
                <td>{labelOf(positionRows, textOf(r, 'position_id'), dash)}</td>
                <td>{t(textOf(r, 'user_id') !== '' ? 'org.employees.yes' : 'org.employees.no')}</td>
                <td>{t(isActive(r) ? 'org.common.active' : 'org.common.retired')}</td>
                <td>
                  {isActive(r) && (
                    <>
                      <Button variant="secondary" size="sm" onClick={() => open(r)}>
                        {t('org.common.edit')}
                      </Button>
                      <Button
                        variant="secondary"
                        size="sm"
                        onClick={() => {
                          write.clearError()
                          setTransferTo({ org_unit_id: textOf(r, 'org_unit_id'), position_id: textOf(r, 'position_id') })
                          setTransferring(r)
                        }}
                      >
                        {t('org.employees.transfer')}
                      </Button>
                      <Button variant="danger" size="sm" onClick={() => setRetiring(r)}>
                        {t('org.common.retire')}
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
        title={t('org.common.retireTitle')}
        body={t('org.common.retireBody', { name: retiring ? textOf(retiring, 'full_name') : '' })}
        confirmText={t('org.common.retire')}
        cancelText={t('org.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </OrgListShell>
  )
}

export default function EmployeesPage() {
  return (
    <OrgIntlProvider>
      <EmployeesInner />
    </OrgIntlProvider>
  )
}
