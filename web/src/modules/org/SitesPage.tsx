/** SitesPage — GH 3609 / REQ-669, style S1. Sites (module org): the list on the left, the record in the detail panel
 *  on the right (create, edit, retire). Styling only: the writes and their rules are unchanged. */
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
import { orgApi, type SiteCreate, type SiteUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import { OrgErrorAlert, OrgSelectField, OrgTextField, fieldMarked, labelOf, useOrgRows } from './OrgListShell'
import { OrgDetail, OrgEmpty, OrgForm, OrgScreen, OrgStatus, OrgTree } from './OrgScreen'
import { LEGAL_ENTITY, SITE, isActive, textOf } from './orgModel'
import { ORG_STRUCTURE_WRITE } from './orgPermissions'
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

type Panel = { kind: 'new' } | { kind: 'record'; id: string } | null

function SitesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const canWrite = useAccess().can(ORG_STRUCTURE_WRITE)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useOrgRows(SITE, showRetired)
  const companies = useOrgRows(LEGAL_ENTITY, true)
  const write = useOrgWrite<Cmd>(run)
  const [panel, setPanel] = useState<Panel>(null)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const items = rows.data ?? []
  const companyRows = companies.data ?? []
  const selected = panel?.kind === 'record' ? items.find((r) => r.record_id === panel.id) : undefined
  const activeCompanies = companyRows
    .filter(isActive)
    .map((c) => ({ value: c.record_id, label: textOf(c, 'name') || textOf(c, 'code') }))
  const dash = t('org.common.dash')
  const nodes: TreeNode[] = items.map((r) => ({
    id: r.record_id,
    name: textOf(r, 'name') || textOf(r, 'code'),
    code: textOf(r, 'code'),
    retired: !isActive(r),
  }))

  function openPanel(next: Panel) {
    write.clearError()
    setPanel(next)
  }

  async function save(form: { code: string; name: string; legal_entity_id: string }) {
    const isNew = panel?.kind === 'new'
    const result = await write.submit(
      isNew || !selected
        ? { op: 'create', body: { code: form.code, name: form.name, legal_entity_id: form.legal_entity_id } }
        : { op: 'update', id: selected.record_id, body: { name: form.name, legal_entity_id: form.legal_entity_id } },
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

  const createLabel = t('org.sites.create')
  const detail =
    panel?.kind === 'new' || selected ? (
      <OrgDetail
        title={selected ? textOf(selected, 'name') || textOf(selected, 'code') : t('org.sites.new')}
        path={selected ? labelOf(companyRows, textOf(selected, 'legal_entity_id'), dash) : undefined}
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
        <SiteForm
          key={selected?.record_id ?? 'new'}
          record={selected ?? null}
          readOnly={!canWrite || (selected !== undefined && !isActive(selected))}
          companies={activeCompanies}
          writeError={write.error}
          saving={write.isPending}
          onSubmit={(f) => void save(f)}
          onCancel={() => openPanel(null)}
        />
      </OrgDetail>
    ) : null

  return (
    <OrgScreen
      title={t('org.sites.title')}
      lede={t('org.sites.lede')}
      createLabel={createLabel}
      canWrite={canWrite}
      onCreate={() => openPanel({ kind: 'new' })}
      queries={[rows, companies]}
      showRetired={showRetired}
      onShowRetired={setShowRetired}
      count={nodes.length}
      detail={detail}
      escapeCloses={retiring === null}
      onClosePanel={() => openPanel(null)}
      master={
        nodes.length === 0 ? (
          <OrgEmpty canWrite={canWrite} createLabel={createLabel} onCreate={() => openPanel({ kind: 'new' })} />
        ) : (
          <OrgTree
            label={t('org.sites.title')}
            nodes={nodes}
            selectedId={selected?.record_id ?? null}
            showRetired={showRetired}
            expandedIds={[]}
            onSelect={(id) => openPanel({ kind: 'record', id })}
            onToggle={() => undefined}
          />
        )
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

function SiteForm(props: {
  record: EntityRecord | null
  readOnly: boolean
  companies: { value: string; label: string }[]
  writeError: unknown
  saving: boolean
  onSubmit: (form: { code: string; name: string; legal_entity_id: string }) => void
  onCancel: () => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const initial = {
    code: props.record ? textOf(props.record, 'code') : '',
    name: props.record ? textOf(props.record, 'name') : '',
    legal_entity_id: props.record ? textOf(props.record, 'legal_entity_id') : '',
  }
  const [form, setForm] = useState(initial)
  const isNew = props.record === null
  return (
    <OrgForm
      label={t(isNew ? 'org.common.create' : 'org.common.edit')}
      error={<OrgErrorAlert error={props.writeError} />}
      readOnly={props.readOnly}
      dirty={form.code !== initial.code || form.name !== initial.name || form.legal_entity_id !== initial.legal_entity_id}
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
        <FormRow>
          <OrgSelectField
            name="legal_entity_id"
            label={t('org.sites.company')}
            value={form.legal_entity_id}
            options={props.companies}
            placeholder={t('org.units.choose')}
            disabled={props.readOnly}
            width="m"
            invalid={fieldMarked(props.writeError, 'legal_entity_id')}
            onChange={(v) => setForm({ ...form, legal_entity_id: v })}
          />
        </FormRow>
      </FormSection>
    </OrgForm>
  )
}

export default function SitesPage() {
  return (
    <OrgIntlProvider>
      <SitesInner />
    </OrgIntlProvider>
  )
}
