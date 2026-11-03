/** CodesPage — GH 3606 / REQ-672, restyled in S4 (design: platform/examples/codes.html). The one screen of the
 *  codes module: list (status filter, exact value search, "Show retired"), receive in bulk (one call, in a dialog),
 *  assign / release / retire, change value and the assignment history of a code.
 *
 *  Owner rule 2a: one record is viewed and edited in the detail panel of MasterDetail (list on the left, the code
 *  on the right), never in a modal. Dialogs stay for the short single-answer actions: Receive codes, Assign and
 *  the Retire confirmation. The panel stays open while other rows are clicked, has a close button and closes on
 *  Escape. Targets are read through the generic query route (no other module's code is imported). */
import { useEffect, useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { Search, Plus, X } from 'lucide-react'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import { Checkbox, Radio } from '@/components/ui/Checkbox'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { Dialog } from '@/components/ui/Dialog'
import { Banner } from '@/components/ui/Banner'
import { Field } from '@/components/ui/Field'
import { FilterBar } from '@/components/ui/FilterBar'
import { FormActions, FormSection } from '@/components/ui/FormSection'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { Select } from '@/components/ui/Select'
import { StatusPill, type StatusGlyph, type StatusTone } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { classifyError } from '@/utils/classifyError'
import { DELETED_FALSE, codesApi, type ReceiveEntry } from './codes.api'
import { CodesIntlProvider } from './CodesIntlProvider'
import { CodesShell, errorText, useCodeRows } from './CodesShell'
import type { CodesUiLocale } from './codesMessages'
import {
  CODE_ASSIGNMENT,
  CODE_KINDS,
  CODE_TAG,
  STATUSES,
  TARGET_TYPES,
  entryReasonMessageId,
  parseLines,
  reasonOf,
  targetCode,
  textOf,
} from './codesModel'
import { CODES_WRITE } from './codesPermissions'
import { useCodesWrite } from './useCodesWrite'

type Cmd =
  | { op: 'assign'; id: string; targetType: string; targetId: string }
  | { op: 'release'; id: string }
  | { op: 'retire'; id: string }
  | { op: 'value'; id: string; value: string }

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'assign') return codesApi.assign(cmd.id, { target_type: cmd.targetType, target_id: cmd.targetId }, key)
  if (cmd.op === 'release') return codesApi.release(cmd.id, key)
  if (cmd.op === 'retire') return codesApi.retire(cmd.id, key)
  return codesApi.changeValue(cmd.id, cmd.value, key)
}

function receive(entries: ReceiveEntry[], key: string) {
  return codesApi.receive(entries, key)
}

const OPEN_ASSIGNMENT: EntityQueryFilterClause = { field: 'released_at', op: 'is_null' }

/** Tone and glyph per status: a word and a shape, never colour alone. */
const STATUS_LOOK: Record<string, { tone: StatusTone; glyph: StatusGlyph }> = {
  assigned: { tone: 'success', glyph: 'dot' },
  not_assigned: { tone: 'neutral', glyph: 'ring' },
  retired: { tone: 'neutral', glyph: 'dash' },
}

interface TargetParts {
  type: string
  code: string
  name: string
}

/** What the screen harness opens at first render (never set by the app). */
export interface CodesInitial {
  selectedId?: string
  receive?: boolean
  assignId?: string
}

function CodesInner({ initial }: { initial?: CodesInitial }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const { can } = useAccess()
  const canWrite = can(CODES_WRITE)

  const [status, setStatus] = useState('')
  const [valueInput, setValueInput] = useState('')
  const [valueFilter, setValueFilter] = useState('')
  const [showRetired, setShowRetired] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(initial?.selectedId ?? null)
  const [receiveOpen, setReceiveOpen] = useState(initial?.receive ?? false)
  const [text, setText] = useState('')
  const [kind, setKind] = useState<string>(CODE_KINDS[0])
  const [assigningId, setAssigningId] = useState<string | null>(initial?.assignId ?? null)
  const [targetType, setTargetType] = useState<string>(TARGET_TYPES[0])
  const [targetId, setTargetId] = useState('')
  const [draft, setDraft] = useState<{ id: string; value: string } | null>(null)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)
  const [lastOp, setLastOp] = useState<Cmd['op'] | null>(null)

  const rows = useCodeRows(CODE_TAG, `status:${status}|value:${valueFilter}`, [
    DELETED_FALSE,
    ...(status !== '' ? [{ field: 'status', op: 'eq' as const, value: status }] : []),
    ...(valueFilter !== '' ? [{ field: 'value', op: 'eq' as const, value: valueFilter }] : []),
  ], { sortField: 'value' })
  // Stable references: DataTable's table model resets (and re-renders) when `data` changes identity.
  const codes = useMemo(() => {
    const loaded = rows.data ?? []
    return showRetired || status === 'retired' ? loaded : loaded.filter((c) => textOf(c, 'status') !== 'retired')
  }, [rows.data, showRetired, status])
  const selected = codes.find((c) => c.record_id === selectedId) ?? null
  const assigning = codes.find((c) => c.record_id === assigningId) ?? null
  const anyAssigned = codes.some((c) => textOf(c, 'status') === 'assigned')
  const needTargets = anyAssigned || assigning !== null || selected !== null

  const open = useCodeRows(CODE_ASSIGNMENT, 'open', [DELETED_FALSE, OPEN_ASSIGNMENT], {
    sortField: 'assigned_at',
    enabled: anyAssigned,
  })
  const targetOpts = { enabled: needTargets }
  const targetQueries = [
    useCodeRows(TARGET_TYPES[0], 'all', [DELETED_FALSE], targetOpts),
    useCodeRows(TARGET_TYPES[1], 'all', [DELETED_FALSE], targetOpts),
    useCodeRows(TARGET_TYPES[2], 'all', [DELETED_FALSE], targetOpts),
  ]
  const historyRows = useCodeRows(
    CODE_ASSIGNMENT,
    `history:${selected?.record_id ?? ''}`,
    [DELETED_FALSE, { field: 'code_id', op: 'eq', value: selected?.record_id ?? '' }],
    { sortField: 'assigned_at', enabled: selected !== null },
  )

  const history = useMemo(
    () => [...(historyRows.data ?? [])].sort((x, y) => textOf(x, 'assigned_at').localeCompare(textOf(y, 'assigned_at'))),
    [historyRows.data],
  )

  const targetsOf = (type: string): EntityRecord[] => targetQueries[TARGET_TYPES.indexOf(type as never)]?.data ?? []
  const dash = t('codes.common.dash')
  const typeLabel = (type: string) =>
    (TARGET_TYPES as readonly string[]).includes(type) ? t(`codes.target.${type}`) : dash
  const targetParts = (type: string, id: string): TargetParts => {
    const rec = targetsOf(type).find((r) => r.record_id === id)
    return { type: typeLabel(type), code: targetCode(rec), name: rec ? textOf(rec, 'name') : '' }
  }
  const openByCode = new Map<string, EntityRecord>()
  for (const a of open.data ?? []) {
    if (textOf(a, 'released_at') === '') openByCode.set(textOf(a, 'code_id'), a)
  }

  const receiveWrite = useCodesWrite<ReceiveEntry[]>(receive)
  const rowWrite = useCodesWrite<Cmd>(run)

  const lines = parseLines(text)
  const info = reasonOf(receiveWrite.error)
  const badLine = info.reason === 'entry_invalid' && info.index !== undefined ? lines[info.index] : undefined
  const lineError = badLine
    ? t('codes.receive.lineError', { line: badLine.line, reason: t(entryReasonMessageId(info.entryReason)) })
    : undefined
  const receiveError = badLine ? null : errorText(intl, receiveWrite.error)
  const rowError = errorText(intl, rowWrite.error)

  const failed = [rows, open, historyRows, ...targetQueries].find((q) => q.isError)
  const isLoading = rows.isPending && rows.fetchStatus !== 'idle'

  // Escape closes the detail panel (a dialog on top handles its own Escape first).
  const dialogOpen = receiveOpen || assigning !== null || retiring !== null
  useEffect(() => {
    if (selectedId === null || dialogOpen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented) setSelectedId(null)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [selectedId, dialogOpen])

  function retry() {
    for (const q of [rows, open, historyRows, ...targetQueries]) void q.refetch()
  }

  function selectRow(r: EntityRecord) {
    if (r.record_id !== selectedId) rowWrite.clearError()
    setSelectedId(r.record_id)
  }

  async function submitReceive() {
    const result = await receiveWrite.submit(lines.map((l) => ({ value: l.value, kind })))
    if (result === 'ok') {
      toast.success(t('codes.toast.received', { count: lines.length }))
      setText('')
      setReceiveOpen(false)
    }
  }

  function closeReceive() {
    receiveWrite.clearError()
    setReceiveOpen(false)
  }

  /** Runs one row command. `done` closes the dialog or form it came from; a gone code (404) closes it too. */
  async function submitRow(cmd: Cmd, toastId: string, done?: () => void) {
    setLastOp(cmd.op)
    const result = await rowWrite.submit(cmd)
    if (result === 'ok') toast.success(t(toastId))
    if (result !== 'error') done?.()
  }

  function startAssign(r: EntityRecord) {
    rowWrite.clearError()
    setAssigningId(r.record_id)
    setTargetType(TARGET_TYPES[0])
    setTargetId('')
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await submitRow({ op: 'retire', id: target.record_id }, 'codes.toast.retired')
  }

  const pickable = targetsOf(targetType).filter((r) => r.field_values['active'] !== false)
  const dashCell = <span className="lf-faint">{dash}</span>

  const pill = (st: string) => {
    const look = STATUS_LOOK[st]
    return look ? (
      <StatusPill tone={look.tone} glyph={look.glyph}>
        {t(`codes.status.${st}`)}
      </StatusPill>
    ) : (
      dashCell
    )
  }
  const kindLabel = (k: string) => ((CODE_KINDS as readonly string[]).includes(k) ? t(`codes.kind.${k}`) : dash)
  const targetCell = (p: TargetParts) => (
    <span className="lf-cell-2">
      <span>
        {p.code === '' ? dash : <span className="mono">{p.code}</span>}
        {p.name !== '' && ` · ${p.name}`}
      </span>
      <span className="caption">{p.type}</span>
    </span>
  )

  /** The row action: Assign for a free code, Release for an assigned one; the click must not select the row. */
  const rowAction = (c: EntityRecord) => {
    const st = textOf(c, 'status')
    if (!canWrite || st === 'retired') return null
    return (
      <span
        role="presentation"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => e.stopPropagation()}
      >
        {st === 'not_assigned' ? (
          <Button variant="primary" size="sm" onClick={() => startAssign(c)}>
            {t('codes.action.assign')}
          </Button>
        ) : (
          <Button
            variant="secondary"
            size="sm"
            disabled={rowWrite.isPending}
            onClick={() => void submitRow({ op: 'release', id: c.record_id }, 'codes.toast.released')}
          >
            {t('codes.action.release')}
          </Button>
        )}
      </span>
    )
  }

  const valueCol: DataTableColumn<EntityRecord> = {
    key: 'value',
    label: t('codes.common.value'),
    render: (c) => textOf(c, 'value'),
    sortable: true,
    mono: true,
  }
  const statusCol: DataTableColumn<EntityRecord> = {
    key: 'status',
    label: t('codes.common.status'),
    render: (c) => pill(textOf(c, 'status')),
    sortable: true,
    sortValue: (c) => textOf(c, 'status'),
  }
  // Beside the detail panel the list is narrow: one column, the status pill under the value.
  const columns: DataTableColumn<EntityRecord>[] = selected
    ? [
        {
          key: 'value',
          label: t('codes.common.value'),
          render: (c) => (
            <span className="lf-cell-2">
              <span className="mono">{textOf(c, 'value')}</span>
              <span>{pill(textOf(c, 'status'))}</span>
            </span>
          ),
          sortable: true,
          sortValue: (c) => textOf(c, 'value'),
        },
      ]
    : [
        valueCol,
        {
          key: 'kind',
          label: t('codes.common.kind'),
          render: (c) => kindLabel(textOf(c, 'kind')),
          sortable: true,
          sortValue: (c) => textOf(c, 'kind'),
        },
        statusCol,
        {
          key: 'target',
          label: t('codes.common.target'),
          render: (c) => {
            const a = openByCode.get(c.record_id)
            return textOf(c, 'status') === 'assigned' && a
              ? targetCell(targetParts(textOf(a, 'target_type'), textOf(a, 'target_id')))
              : dashCell
          },
        },
        { key: 'actions', label: t('codes.common.actions'), render: rowAction },
      ]

  const filtered = status !== '' || valueFilter !== ''
  const table = (
    <DataTable
      columns={columns}
      data={codes}
      getRowId={(c) => c.record_id}
      selectedId={selected?.record_id ?? null}
      onRowClick={selectRow}
      rowState={(c) => (textOf(c, 'status') === 'retired' ? 'retired' : undefined)}
      isLoading={isLoading}
      error={failed ? t('codes.list.loadError') : undefined}
      onRetry={retry}
      emptyMessage={t(filtered ? 'codes.list.emptyFiltered' : 'codes.common.empty')}
      emptyText={filtered ? undefined : canWrite ? t('codes.list.emptyText') : undefined}
      emptyAction={
        !filtered && canWrite ? (
          <Button variant="primary" size="md" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={() => setReceiveOpen(true)}>
            {t('codes.receive.open')}
          </Button>
        ) : undefined
      }
      labels={{ loading: t('codes.list.loading'), retry: t('codes.common.retry') }}
    />
  )

  let detail = null
  if (selected) {
    const st = textOf(selected, 'status')
    const value = textOf(selected, 'value')
    const a = openByCode.get(selected.record_id)
    const current = draft && draft.id === selected.record_id ? draft.value : value
    const valueError = lastOp === 'value' ? rowError : null
    detail = (
      <div data-testid="codes-detail">
        <DetailHeader
          title={value}
          path={kindLabel(textOf(selected, 'kind'))}
          status={pill(st)}
          actions={
            <>
              {canWrite && st === 'not_assigned' && (
                <Button variant="primary" size="sm" onClick={() => startAssign(selected)}>
                  {t('codes.action.assign')}
                </Button>
              )}
              {canWrite && st === 'assigned' && (
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={rowWrite.isPending}
                  onClick={() => void submitRow({ op: 'release', id: selected.record_id }, 'codes.toast.released')}
                >
                  {t('codes.action.release')}
                </Button>
              )}
              {canWrite && st !== 'retired' && (
                <Button variant="danger" size="sm" onClick={() => setRetiring(selected)}>
                  {t('codes.action.retire')}
                </Button>
              )}
              <Button
                variant="ghost"
                size="sm"
                iconOnly
                label={t('codes.detail.close')}
                icon={<X className="lf-icon" aria-hidden="true" />}
                onClick={() => setSelectedId(null)}
                data-testid="codes-detail-close"
              />
            </>
          }
        />
        <div className="lf-card__body lf-form">
          {st === 'assigned' && a && (
            <div>
              <p className="lf-label">{t('codes.common.target')}</p>
              {targetCell(targetParts(textOf(a, 'target_type'), textOf(a, 'target_id')))}
            </div>
          )}
          {canWrite && st !== 'retired' && (
            <FormSection title={t('codes.detail.valueSection')}>
              <Field label={t('codes.value.newValue')} mono width="l" error={valueError ?? undefined}>
                <input
                  name="new_value"
                  value={current}
                  onChange={(e) => setDraft({ id: selected.record_id, value: e.target.value })}
                />
              </Field>
              <FormActions
                primary={
                  <Button
                    variant="primary"
                    size="md"
                    disabled={rowWrite.isPending || current.trim() === '' || current === value}
                    onClick={() =>
                      void submitRow({ op: 'value', id: selected.record_id, value: current }, 'codes.toast.valueChanged', () =>
                        setDraft(null),
                      )
                    }
                    data-testid="value-confirm"
                  >
                    {t('codes.common.save')}
                  </Button>
                }
              />
            </FormSection>
          )}
          <FormSection title={t('codes.detail.historySection')}>
            <DataTable
              columns={[
                {
                  key: 'target',
                  label: t('codes.common.target'),
                  render: (x) => targetCell(targetParts(textOf(x, 'target_type'), textOf(x, 'target_id'))),
                },
                { key: 'assigned', label: t('codes.history.assignedAt'), render: (x) => stamp(intl, textOf(x, 'assigned_at'), dash), mono: true },
                {
                  key: 'released',
                  label: t('codes.history.releasedAt'),
                  render: (x) => (textOf(x, 'released_at') === '' ? t('codes.history.open') : stamp(intl, textOf(x, 'released_at'), dash)),
                  mono: true,
                },
              ]}
              data={history}
              getRowId={(x) => x.record_id}
              isLoading={historyRows.isPending && historyRows.fetchStatus !== 'idle'}
              emptyMessage={t('codes.history.empty')}
              labels={{ loading: t('codes.list.loading'), retry: t('codes.common.retry') }}
            />
          </FormSection>
        </div>
      </div>
    )
  }

  const rowBanner = rowError && lastOp !== 'assign' && lastOp !== 'value' ? <Banner tone="danger">{rowError}</Banner> : null

  return (
    <>
      <CodesShell
        eyebrow={t('codes.eyebrow')}
        title={t('codes.title')}
        lede={t('codes.lede')}
        state={failed ? classifyError(failed.error) : 'success'}
        onRetry={retry}
        actions={
          canWrite ? (
            <Button variant="primary" size="md" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={() => setReceiveOpen(true)} data-testid="receive-open">
              {t('codes.receive.open')}
            </Button>
          ) : undefined
        }
      >
        <FilterBar>
          <Field
            label={t('codes.list.searchValue')}
            width="l"
            mono
            leadingIcon={<Search className="lf-icon" aria-hidden="true" />}
          >
            <input
              name="search"
              value={valueInput}
              placeholder={t('codes.list.exactPh')}
              onChange={(e) => setValueInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') setValueFilter(valueInput)
              }}
            />
          </Field>
          <Select
            name="status"
            label={t('codes.list.filterStatus')}
            width="s"
            value={status}
            options={STATUSES.filter((s) => showRetired || s !== 'retired').map((s) => ({ value: s, label: t(`codes.status.${s}`) }))}
            placeholder={t('codes.common.all')}
            onChange={setStatus}
          />
          <Button variant="secondary" size="md" onClick={() => setValueFilter(valueInput)} data-testid="codes-search">
            {t('codes.list.search')}
          </Button>
          <div className="lf-toolbar__end">
            <Checkbox
              label={t('codes.list.showRetired')}
              checked={showRetired}
              onChange={(on) => {
                setShowRetired(on)
                if (!on && status === 'retired') setStatus('')
              }}
              data-testid="codes-show-retired"
            />
          </div>
        </FilterBar>
        {rowBanner}
        {selected ? <MasterDetail master={table} detail={detail} /> : table}
      </CodesShell>

      <Dialog
        open={receiveOpen}
        testId="receive-dialog"
        title={t('codes.receive.title')}
        subtitle={t('codes.receive.sub')}
        confirmText={t('codes.receive.submit')}
        cancelText={t('codes.common.cancel')}
        isLoading={receiveWrite.isPending}
        confirmDisabled={lines.length === 0 || kind === ''}
        error={receiveError}
        onConfirm={() => void submitReceive()}
        onCancel={closeReceive}
      >
        <div className="lf-form">
          <Select
            name="kind"
            label={t('codes.receive.kind')}
            width="s"
            value={kind}
            options={CODE_KINDS.map((k) => ({ value: k, label: t(`codes.kind.${k}`) }))}
            placeholder={t('codes.common.choose')}
            onChange={setKind}
          />
          <Field label={t('codes.receive.values')} mono error={lineError}>
            <textarea rows={6} value={text} onChange={(e) => setText(e.target.value)} />
          </Field>
        </div>
      </Dialog>

      <Dialog
        open={assigning !== null}
        testId="assign-dialog"
        title={t('codes.assign.title')}
        subtitle={assigning ? `${textOf(assigning, 'value')} · ${kindLabel(textOf(assigning, 'kind'))}` : undefined}
        confirmText={t('codes.action.assign')}
        cancelText={t('codes.common.cancel')}
        isLoading={rowWrite.isPending}
        confirmDisabled={targetId === ''}
        error={lastOp === 'assign' ? rowError : null}
        onConfirm={() => {
          if (assigning)
            void submitRow({ op: 'assign', id: assigning.record_id, targetType, targetId }, 'codes.toast.assigned', () =>
              setAssigningId(null),
            )
        }}
        onCancel={() => setAssigningId(null)}
      >
        <div className="lf-form">
          <div role="radiogroup" aria-labelledby="codes-assign-type">
            <p className="lf-label" id="codes-assign-type">
              {t('codes.assign.targetType')}
            </p>
            <div className="lf-btn-row">
              {TARGET_TYPES.map((x) => (
                <Radio
                  key={x}
                  name="target_type"
                  value={x}
                  label={t(`codes.target.${x}`)}
                  checked={targetType === x}
                  onChange={() => {
                    setTargetType(x)
                    setTargetId('')
                  }}
                />
              ))}
            </div>
          </div>
          <Select
            name="target_id"
            label={t('codes.assign.target')}
            value={targetId}
            hint={pickable.length === 0 ? t('codes.assign.noTargets') : undefined}
            options={pickable.map((r) => ({
              value: r.record_id,
              label: `${textOf(r, 'code')} - ${textOf(r, 'name')}`.replace(/ - $/, ''),
            }))}
            placeholder={t('codes.common.choose')}
            onChange={setTargetId}
          />
          <Banner tone="info">{t('codes.assign.note')}</Banner>
        </div>
      </Dialog>

      <ConfirmDialog
        open={retiring !== null}
        title={t('codes.retire.title')}
        body={t('codes.retire.body', { value: retiring ? textOf(retiring, 'value') : '' })}
        confirmText={t('codes.action.retire')}
        cancelText={t('codes.common.cancel')}
        confirmVariant="danger"
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </>
  )
}

function stamp(intl: ReturnType<typeof useIntl>, iso: string, dash: string): string {
  if (iso === '') return dash
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : intl.formatDate(d, { dateStyle: 'medium', timeStyle: 'short' })
}

export default function CodesPage({ locale, initial }: { locale?: CodesUiLocale; initial?: CodesInitial }) {
  return (
    <CodesIntlProvider locale={locale}>
      <CodesInner initial={initial} />
    </CodesIntlProvider>
  )
}
