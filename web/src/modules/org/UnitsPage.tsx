/** UnitsPage — GH 3609 / REQ-669. The org unit tree: list, create (root or child), edit, move, retire.
 *  The tree is built here from all loaded units (`parent` is not a queried column). With the retired switch
 *  off only active rows are loaded, so an active child of a retired parent shows as a root; the move picker is
 *  built from the loaded active rows and the server's cycle answer stays the authority. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityRecord } from '@/types/api'
import { orgApi, type UnitCreate, type UnitUpdate } from './org.api'
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
import { LEGAL_ENTITY, SITE, UNIT, buildUnitTree, isActive, moveTargets, textOf } from './orgModel'
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

const option = (r: EntityRecord) => ({ value: r.record_id, label: textOf(r, 'name') || textOf(r, 'code') })

function UnitsInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useOrgRows(UNIT, showRetired)
  const companies = useOrgRows(LEGAL_ENTITY, true)
  const sites = useOrgRows(SITE, true)
  const write = useOrgWrite<Cmd>(run)
  const [editing, setEditing] = useState<'new' | EntityRecord | null>(null)
  const [form, setForm] = useState({ code: '', name: '', legal_entity_id: '', site_id: '', parent: '' })
  const [moving, setMoving] = useState<EntityRecord | null>(null)
  const [moveTo, setMoveTo] = useState('')
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const unitRows = rows.data ?? []
  const companyRows = companies.data ?? []
  const siteRows = sites.data ?? []
  const tree = buildUnitTree(unitRows)
  const dash = t('org.common.dash')

  function open(target: 'new' | EntityRecord, parent = '') {
    write.clearError()
    setEditing(target)
    setForm(
      target === 'new'
        ? { code: '', name: '', legal_entity_id: '', site_id: '', parent }
        : {
            code: textOf(target, 'code'),
            name: textOf(target, 'name'),
            legal_entity_id: textOf(target, 'legal_entity_id'),
            site_id: textOf(target, 'site_id'),
            parent: textOf(target, 'parent'),
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
              legal_entity_id: form.legal_entity_id,
              site_id: form.site_id,
              ...(form.parent !== '' ? { parent: form.parent } : {}),
            },
          }
        : {
            op: 'update',
            id: editing.record_id,
            body: { name: form.name, legal_entity_id: form.legal_entity_id, site_id: form.site_id },
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
    <OrgListShell
      title={t('org.units.title')}
      queries={[rows, companies, sites]}
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
            label={t('org.units.company')}
            value={form.legal_entity_id}
            options={companyRows.filter(isActive).map(option)}
            placeholder={t('org.units.choose')}
            invalid={fieldMarked(write.error, 'legal_entity_id')}
            onChange={(v) => setForm({ ...form, legal_entity_id: v })}
          />
          <OrgSelectField
            name="site_id"
            label={t('org.units.site')}
            value={form.site_id}
            options={siteRows.filter(isActive).map(option)}
            placeholder={t('org.units.choose')}
            invalid={fieldMarked(write.error, 'site_id')}
            onChange={(v) => setForm({ ...form, site_id: v })}
          />
          {editing === 'new' && (
            <OrgSelectField
              name="parent"
              label={t('org.units.parent')}
              value={form.parent}
              options={unitRows.filter(isActive).map(option)}
              placeholder={t('org.units.noParent')}
              invalid={fieldMarked(write.error, 'parent')}
              onChange={(v) => setForm({ ...form, parent: v })}
            />
          )}
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void save()} data-testid="org-save">
            {t('org.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setEditing(null)}>
            {t('org.common.cancel')}
          </Button>
        </form>
      )}
      {moving !== null && (
        <form
          aria-label={t('org.units.moveTitle', { name: textOf(moving, 'name') })}
          onSubmit={(e) => {
            e.preventDefault()
            void confirmMove()
          }}
        >
          <OrgSelectField
            name="move_to"
            label={t('org.units.moveTarget')}
            value={moveTo}
            options={moveTargets(unitRows, moving.record_id).map(option)}
            placeholder={t('org.units.moveRoot')}
            invalid={fieldMarked(write.error, 'parent_id')}
            onChange={setMoveTo}
          />
          <Button variant="primary" size="md" disabled={write.isPending} onClick={() => void confirmMove()} data-testid="org-move-confirm">
            {t('org.units.move')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setMoving(null)}>
            {t('org.common.cancel')}
          </Button>
        </form>
      )}
      {tree.length === 0 ? (
        <p>{t('org.common.empty')}</p>
      ) : (
        <table role="treegrid">
          <thead>
            <tr>
              <th>{t('org.common.code')}</th>
              <th>{t('org.common.name')}</th>
              <th>{t('org.units.company')}</th>
              <th>{t('org.units.site')}</th>
              <th>{t('org.common.state')}</th>
              <th>{t('org.common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {tree.map(({ record: r, depth }) => (
              <tr key={r.record_id} role="row" aria-level={depth + 1} data-testid={`org-row-${textOf(r, 'code')}`}>
                <td style={{ paddingLeft: `calc(${depth} * var(--space-4))` }}>{textOf(r, 'code')}</td>
                <td>{textOf(r, 'name')}</td>
                <td>{labelOf(companyRows, textOf(r, 'legal_entity_id'), dash)}</td>
                <td>{labelOf(siteRows, textOf(r, 'site_id'), dash)}</td>
                <td>{t(isActive(r) ? 'org.common.active' : 'org.common.retired')}</td>
                <td>
                  {isActive(r) && (
                    <>
                      <Button variant="secondary" size="sm" onClick={() => open('new', r.record_id)}>
                        {t('org.units.addChild')}
                      </Button>
                      <Button variant="secondary" size="sm" onClick={() => open(r)}>
                        {t('org.common.edit')}
                      </Button>
                      <Button
                        variant="secondary"
                        size="sm"
                        onClick={() => {
                          write.clearError()
                          setMoveTo(textOf(r, 'parent'))
                          setMoving(r)
                        }}
                      >
                        {t('org.units.move')}
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

export default function UnitsPage() {
  return (
    <OrgIntlProvider>
      <UnitsInner />
    </OrgIntlProvider>
  )
}
