/** SitesPage — GH 3609 / REQ-669. List, create, edit and retire sites (module org). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityRecord } from '@/types/api'
import { orgApi, type SiteCreate, type SiteUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import {
  OrgErrorAlert,
  OrgListShell,
  OrgSelectField,
  OrgTextField,
  fieldMarked,
  labelOf,
  useOrgRows,
} from './OrgListShell'
import { LEGAL_ENTITY, SITE, isActive, textOf } from './orgModel'
import { useOrgWrite } from './useOrgWrite'

type Cmd =
  | { op: 'create'; body: SiteCreate }
  | { op: 'update'; id: string; body: SiteUpdate }
  | { op: 'retire'; id: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return orgApi.createSite(cmd.body, key)
  if (cmd.op === 'update') return orgApi.updateSite(cmd.id, cmd.body, key)
  return orgApi.retireSite(cmd.id, key)
}

function SitesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useOrgRows(SITE, showRetired)
  const companies = useOrgRows(LEGAL_ENTITY, true)
  const write = useOrgWrite<Cmd>(run)
  const [editing, setEditing] = useState<'new' | EntityRecord | null>(null)
  const [form, setForm] = useState({ code: '', name: '', legal_entity_id: '' })
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const companyRows = companies.data ?? []
  const activeCompanies = companyRows
    .filter(isActive)
    .map((c) => ({ value: c.record_id, label: textOf(c, 'name') || textOf(c, 'code') }))

  function open(target: 'new' | EntityRecord) {
    write.clearError()
    setEditing(target)
    setForm(
      target === 'new'
        ? { code: '', name: '', legal_entity_id: '' }
        : { code: textOf(target, 'code'), name: textOf(target, 'name'), legal_entity_id: textOf(target, 'legal_entity_id') },
    )
  }

  async function save() {
    if (editing === null) return
    const result = await write.submit(
      editing === 'new'
        ? { op: 'create', body: { code: form.code, name: form.name, legal_entity_id: form.legal_entity_id } }
        : { op: 'update', id: editing.record_id, body: { name: form.name, legal_entity_id: form.legal_entity_id } },
    )
    if (result === 'ok' || result === 'notFound') setEditing(null)
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await write.submit({ op: 'retire', id: target.record_id })
  }

  const items = rows.data ?? []
  return (
    <OrgListShell
      title={t('org.sites.title')}
      queries={[rows, companies]}
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
          <OrgSelectField
            name="legal_entity_id"
            label={t('org.sites.company')}
            value={form.legal_entity_id}
            options={activeCompanies}
            placeholder={t('org.units.choose')}
            invalid={fieldMarked(write.error, 'legal_entity_id')}
            onChange={(v) => setForm({ ...form, legal_entity_id: v })}
          />
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
              <th>{t('org.sites.company')}</th>
              <th>{t('org.common.state')}</th>
              <th>{t('org.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {items.map((r) => (
              <tr key={r.record_id} data-testid={`org-row-${textOf(r, 'code')}`}>
                <td>{textOf(r, 'code')}</td>
                <td>{textOf(r, 'name')}</td>
                <td>{labelOf(companyRows, textOf(r, 'legal_entity_id'), t('org.common.dash'))}</td>
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

export default function SitesPage() {
  return (
    <OrgIntlProvider>
      <SitesInner />
    </OrgIntlProvider>
  )
}
