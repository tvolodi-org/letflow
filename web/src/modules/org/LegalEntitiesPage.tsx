/** LegalEntitiesPage — GH 3609 / REQ-669. List, create, edit and retire legal companies (module org). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityRecord } from '@/types/api'
import { orgApi, type LegalEntityCreate, type LegalEntityUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import { OrgErrorAlert, OrgListShell, OrgTextField, fieldMarked, useOrgRows } from './OrgListShell'
import { LEGAL_ENTITY, binValid, isActive, textOf } from './orgModel'
import { useOrgWrite } from './useOrgWrite'

type Cmd =
  | { op: 'create'; body: LegalEntityCreate }
  | { op: 'update'; id: string; body: LegalEntityUpdate }
  | { op: 'retire'; id: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return orgApi.createLegalEntity(cmd.body, key)
  if (cmd.op === 'update') return orgApi.updateLegalEntity(cmd.id, cmd.body, key)
  return orgApi.retireLegalEntity(cmd.id, key)
}

function LegalEntitiesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useOrgRows(LEGAL_ENTITY, showRetired)
  const write = useOrgWrite<Cmd>(run)
  const [editing, setEditing] = useState<'new' | EntityRecord | null>(null)
  const [form, setForm] = useState({ code: '', name: '', bin: '' })
  const [binError, setBinError] = useState(false)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  function open(target: 'new' | EntityRecord) {
    write.clearError()
    setBinError(false)
    setEditing(target)
    setForm(
      target === 'new'
        ? { code: '', name: '', bin: '' }
        : { code: textOf(target, 'code'), name: textOf(target, 'name'), bin: textOf(target, 'bin') },
    )
  }

  async function save() {
    if (editing === null) return
    if (!binValid(form.bin)) {
      setBinError(true)
      return
    }
    setBinError(false)
    const result = await write.submit(
      editing === 'new'
        ? { op: 'create', body: { code: form.code, name: form.name, bin: form.bin } }
        : { op: 'update', id: editing.record_id, body: { name: form.name, bin: form.bin } },
    )
    if (result === 'ok' || result === 'notFound') setEditing(null)
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await write.submit({ op: 'retire', id: target.record_id }, target.record_id)
  }

  const items = rows.data ?? []
  return (
    <OrgListShell
      title={t('org.legal.title')}
      queries={[rows]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      actions={
        <Button variant="primary" size="md" onClick={() => open('new')} data-testid="org-create">
          {t('org.common.create')}
        </Button>
      }
    >
      <OrgErrorAlert error={write.error} />
      {editing !== null && (
        <form
          aria-label={t(editing === 'new' ? 'org.common.create' : 'org.common.edit')}
          onSubmit={(e) => {
            e.preventDefault()
            void save()
          }}
        >
          <OrgTextField name="code" label={t('org.common.code')} value={form.code} readOnly={editing !== 'new'} onChange={(v) => setForm({ ...form, code: v })} />
          <OrgTextField name="name" label={t('org.common.name')} value={form.name} invalid={fieldMarked(write.error, 'name')} onChange={(v) => setForm({ ...form, name: v })} />
          <OrgTextField
            name="bin"
            label={t('org.legal.bin')}
            value={form.bin}
            numeric
            maxLength={12}
            invalid={binError || fieldMarked(write.error, 'bin')}
            onChange={(v) => setForm({ ...form, bin: v })}
          />
          {binError && <div role="alert">{t('org.error.binFormat')}</div>}
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void save()} data-testid="org-save">
            {t('org.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setEditing(null)}>
            {t('org.common.cancel')}
          </Button>
        </form>
      )}
      {items.length === 0 ? (
        <p>{t('org.common.empty')}</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>{t('org.common.code')}</th>
              <th>{t('org.common.name')}</th>
              <th>{t('org.legal.bin')}</th>
              <th>{t('org.common.state')}</th>
              <th>{t('org.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {items.map((r) => (
              <tr key={r.record_id} data-testid={`org-row-${textOf(r, 'code')}`}>
                <td>{textOf(r, 'code')}</td>
                <td>{textOf(r, 'name')}</td>
                <td>{textOf(r, 'bin')}</td>
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

export default function LegalEntitiesPage() {
  return (
    <OrgIntlProvider>
      <LegalEntitiesInner />
    </OrgIntlProvider>
  )
}
