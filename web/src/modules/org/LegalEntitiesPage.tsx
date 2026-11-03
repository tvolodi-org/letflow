/** LegalEntitiesPage — GH 3609 / REQ-669, style S1. Legal companies (module org): the list on the left, the record in
 *  the detail panel on the right (create, edit, retire). Styling only: the writes and their rules are unchanged. */
import { useState } from 'react'
import { Archive } from 'lucide-react'
import { useIntl } from 'react-intl'
import { useAccess } from '@/auth/access'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { FormRow, FormSection } from '@/components/ui/FormSection'
import { useToast } from '@/hooks/useToast'
import type { TreeNode } from '@/components/ui/TreeView'
import type { EntityRecord } from '@/types/api'
import { orgApi, type LegalEntityCreate, type LegalEntityUpdate } from './org.api'
import { OrgIntlProvider } from './OrgIntlProvider'
import { OrgErrorAlert, OrgTextField, fieldMarked, useOrgRows } from './OrgListShell'
import { OrgDetail, OrgEmpty, OrgForm, OrgScreen, OrgStatus, OrgTree } from './OrgScreen'
import { LEGAL_ENTITY, binValid, isActive, textOf } from './orgModel'
import { ORG_STRUCTURE_WRITE } from './orgPermissions'
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

type Panel = { kind: 'new' } | { kind: 'record'; id: string } | null

function LegalEntitiesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const canWrite = useAccess().can(ORG_STRUCTURE_WRITE)
  const [showRetired, setShowRetired] = useState(false)
  const rows = useOrgRows(LEGAL_ENTITY, showRetired)
  const write = useOrgWrite<Cmd>(run)
  const [panel, setPanel] = useState<Panel>(null)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)
  const [binError, setBinError] = useState(false)

  const items = rows.data ?? []
  const selected = panel?.kind === 'record' ? items.find((r) => r.record_id === panel.id) : undefined
  const nodes: TreeNode[] = items.map((r) => ({
    id: r.record_id,
    name: textOf(r, 'name') || textOf(r, 'code'),
    code: textOf(r, 'code'),
    retired: !isActive(r),
  }))

  function openPanel(next: Panel) {
    write.clearError()
    setBinError(false)
    setPanel(next)
  }

  async function save(form: { code: string; name: string; bin: string }) {
    if (!binValid(form.bin)) {
      setBinError(true)
      return
    }
    setBinError(false)
    const isNew = panel?.kind === 'new'
    const result = await write.submit(
      isNew || !selected
        ? { op: 'create', body: { code: form.code, name: form.name, bin: form.bin } }
        : { op: 'update', id: selected.record_id, body: { name: form.name, bin: form.bin } },
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
    const result = await write.submit({ op: 'retire', id: target.record_id }, target.record_id)
    if (result === 'ok') {
      toast.success(t('org.common.retiredDone'))
      setPanel(null)
    }
  }

  const createLabel = t('org.legal.create')
  const detail =
    panel?.kind === 'new' || selected ? (
      <OrgDetail
        title={selected ? textOf(selected, 'name') || textOf(selected, 'code') : t('org.legal.new')}
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
        <LegalForm
          key={selected?.record_id ?? 'new'}
          record={selected ?? null}
          readOnly={!canWrite || (selected !== undefined && !isActive(selected))}
          writeError={write.error}
          binError={binError}
          saving={write.isPending}
          onSubmit={(f) => void save(f)}
          onCancel={() => openPanel(null)}
        />
      </OrgDetail>
    ) : null

  return (
    <OrgScreen
      title={t('org.legal.title')}
      lede={t('org.legal.lede')}
      createLabel={createLabel}
      canWrite={canWrite}
      onCreate={() => openPanel({ kind: 'new' })}
      queries={[rows]}
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
            label={t('org.legal.title')}
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

function LegalForm(props: {
  record: EntityRecord | null
  readOnly: boolean
  writeError: unknown
  binError: boolean
  saving: boolean
  onSubmit: (form: { code: string; name: string; bin: string }) => void
  onCancel: () => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const initial = {
    code: props.record ? textOf(props.record, 'code') : '',
    name: props.record ? textOf(props.record, 'name') : '',
    bin: props.record ? textOf(props.record, 'bin') : '',
  }
  const [form, setForm] = useState(initial)
  const isNew = props.record === null
  return (
    <OrgForm
      label={t(isNew ? 'org.common.create' : 'org.common.edit')}
      error={<OrgErrorAlert error={props.writeError} />}
      readOnly={props.readOnly}
      dirty={form.code !== initial.code || form.name !== initial.name || form.bin !== initial.bin}
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
          <OrgTextField
            name="bin"
            label={t('org.legal.bin')}
            value={form.bin}
            readOnly={props.readOnly}
            numeric
            mono
            maxLength={12}
            width="s"
            hint={t('org.legal.binHint')}
            error={props.binError ? t('org.error.binFormat') : undefined}
            invalid={fieldMarked(props.writeError, 'bin')}
            onChange={(v) => setForm({ ...form, bin: v })}
          />
        </FormRow>
      </FormSection>
    </OrgForm>
  )
}

export default function LegalEntitiesPage() {
  return (
    <OrgIntlProvider>
      <LegalEntitiesInner />
    </OrgIntlProvider>
  )
}
