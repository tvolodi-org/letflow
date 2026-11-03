/** PositionsPage — GH 3608 / REQ-670. Positions of the org units: list (optionally of one unit), create, edit the name,
 *  retire. Code and unit are fixed after creation. Actions are offered on active rows only, as on UnitsPage. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityRecord } from '@/types/api'
import { orgApi, type PositionCreate, type PositionUpdate } from './org.api'
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
} from './OrgListShell'
import { POSITION, UNIT, isActive, textOf, unitOptions } from './orgModel'
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

function PositionsInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [showRetired, setShowRetired] = useState(false)
  const [unitFilter, setUnitFilter] = useState('')
  const rows = useOrgRows(POSITION, showRetired, unitFilter)
  const units = useOrgRows(UNIT, true)
  const write = useOrgWrite<Cmd>(run)
  const [editing, setEditing] = useState<'new' | EntityRecord | null>(null)
  const [form, setForm] = useState({ code: '', name: '', org_unit_id: '' })
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const positionRows = rows.data ?? []
  const unitRows = units.data ?? []
  const dash = t('org.common.dash')

  function open(target: 'new' | EntityRecord) {
    write.clearError()
    setEditing(target)
    setForm(
      target === 'new'
        ? { code: '', name: '', org_unit_id: unitFilter }
        : { code: textOf(target, 'code'), name: textOf(target, 'name'), org_unit_id: textOf(target, 'org_unit_id') },
    )
  }

  async function save() {
    if (editing === null) return
    const result = await write.submit(
      editing === 'new'
        ? { op: 'create', body: { code: form.code, name: form.name, org_unit_id: form.org_unit_id } }
        : { op: 'update', id: editing.record_id, body: { name: form.name } },
    )
    if (result === 'ok' || result === 'notFound') setEditing(null)
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await write.submit({ op: 'retire', id: target.record_id })
  }

  return (
    <OrgListShell
      title={t('org.positions.title')}
      queries={[rows, units]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      actions={
        <Button variant="primary" size="md" onClick={() => open('new')} data-testid="org-create">
          {t('org.common.create')}
        </Button>
      }
    >
      <OrgUnitFilter value={unitFilter} onChange={setUnitFilter} options={unitOptions(unitRows)} />
      <OrgErrorAlert error={write.error} />
      {editing !== null && (
        <form
          aria-label={t(editing === 'new' ? 'org.common.create' : 'org.common.edit')}
          onSubmit={(e) => {
            e.preventDefault()
            void save()
          }}
        >
          <OrgTextField name="code" label={t('org.common.code')} value={form.code} readOnly={editing !== 'new'} invalid={fieldMarked(write.error, 'code')} onChange={(v) => setForm({ ...form, code: v })} />
          <OrgTextField name="name" label={t('org.common.name')} value={form.name} invalid={fieldMarked(write.error, 'name')} onChange={(v) => setForm({ ...form, name: v })} />
          {editing === 'new' ? (
            <OrgSelectField
              name="org_unit_id"
              label={t('org.positions.unit')}
              value={form.org_unit_id}
              options={unitOptions(unitRows.filter(isActive))}
              placeholder={t('org.units.choose')}
              invalid={fieldMarked(write.error, 'org_unit_id')}
              onChange={(v) => setForm({ ...form, org_unit_id: v })}
            />
          ) : (
            <OrgTextField name="org_unit_id" label={t('org.positions.unit')} value={labelOf(unitRows, form.org_unit_id, dash)} readOnly onChange={() => undefined} />
          )}
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void save()} data-testid="org-save">
            {t('org.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setEditing(null)}>
            {t('org.common.cancel')}
          </Button>
        </form>
      )}
      {positionRows.length === 0 ? (
        <p>{t('org.common.empty')}</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>{t('org.common.code')}</th>
              <th>{t('org.common.name')}</th>
              <th>{t('org.positions.unit')}</th>
              <th>{t('org.common.state')}</th>
              <th>{t('org.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {positionRows.map((r) => (
              <tr key={r.record_id} data-testid={`org-row-${textOf(r, 'code')}`}>
                <td>{textOf(r, 'code')}</td>
                <td>{textOf(r, 'name')}</td>
                <td>{labelOf(unitRows, textOf(r, 'org_unit_id'), dash)}</td>
                <td>{t(isActive(r) ? 'org.common.active' : 'org.common.retired')}</td>
                <td>
                  {isActive(r) && (
                    <>
                      <Button variant="secondary" size="sm" onClick={() => open(r)}>
                        {t('org.common.edit')}
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
        body={t('org.common.retireBody', { name: retiring ? textOf(retiring, 'name') : '' })}
        confirmText={t('org.common.retire')}
        cancelText={t('org.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </OrgListShell>
  )
}

export default function PositionsPage() {
  return (
    <OrgIntlProvider>
      <PositionsInner />
    </OrgIntlProvider>
  )
}
