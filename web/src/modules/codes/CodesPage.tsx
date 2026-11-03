/** CodesPage — GH 3606 / REQ-672. The one screen of the codes module: list (status filter, exact value search),
 *  receive in bulk (one call), assign, release, retire (after a warning), change value, and the assignment
 *  history of a code. Targets are read through the generic query route (no other module's code is imported). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { DELETED_FALSE, codesApi, type ReceiveEntry } from './codes.api'
import { CodesIntlProvider } from './CodesIntlProvider'
import { CodesErrorAlert, CodesShell, SelectField, TextField, useCodeRows } from './CodesShell'
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

function CodesInner() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)

  const [status, setStatus] = useState('')
  const [valueInput, setValueInput] = useState('')
  const [valueFilter, setValueFilter] = useState('')
  const [text, setText] = useState('')
  const [kind, setKind] = useState<string>(CODE_KINDS[0])
  const [assigning, setAssigning] = useState<EntityRecord | null>(null)
  const [targetType, setTargetType] = useState('')
  const [targetId, setTargetId] = useState('')
  const [changing, setChanging] = useState<EntityRecord | null>(null)
  const [newValue, setNewValue] = useState('')
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)
  const [history, setHistory] = useState<EntityRecord | null>(null)

  const rows = useCodeRows(CODE_TAG, `status:${status}|value:${valueFilter}`, [
    DELETED_FALSE,
    ...(status !== '' ? [{ field: 'status', op: 'eq' as const, value: status }] : []),
    ...(valueFilter !== '' ? [{ field: 'value', op: 'eq' as const, value: valueFilter }] : []),
  ], { sortField: 'value' })
  const codes = rows.data ?? []
  const anyAssigned = codes.some((c) => textOf(c, 'status') === 'assigned')
  const needTargets = anyAssigned || assigning !== null || history !== null

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
    `history:${history?.record_id ?? ''}`,
    [DELETED_FALSE, { field: 'code_id', op: 'eq', value: history?.record_id ?? '' }],
    { sortField: 'assigned_at', enabled: history !== null },
  )

  const targetsOf = (type: string): EntityRecord[] => targetQueries[TARGET_TYPES.indexOf(type as never)]?.data ?? []
  const dash = t('codes.common.dash')
  const typeLabel = (type: string) =>
    (TARGET_TYPES as readonly string[]).includes(type) ? t(`codes.target.${type}`) : dash
  const targetText = (type: string, id: string) => {
    const code = targetCode(targetsOf(type).find((r) => r.record_id === id))
    return code === '' ? `${typeLabel(type)} ${dash}` : `${typeLabel(type)} ${code}`
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

  async function submitReceive() {
    const result = await receiveWrite.submit(lines.map((l) => ({ value: l.value, kind })))
    if (result === 'ok') setText('')
  }

  async function submitRow(cmd: Cmd, close?: () => void) {
    const result = await rowWrite.submit(cmd)
    if (result !== 'error') close?.()
  }

  function startAssign(r: EntityRecord) {
    rowWrite.clearError()
    setChanging(null)
    setAssigning(r)
    setTargetType('')
    setTargetId('')
  }

  function startChange(r: EntityRecord) {
    rowWrite.clearError()
    setAssigning(null)
    setChanging(r)
    setNewValue(textOf(r, 'value'))
  }

  async function confirmRetire() {
    if (!retiring) return
    const target = retiring
    setRetiring(null)
    await submitRow({ op: 'retire', id: target.record_id })
  }

  const pickable = targetsOf(targetType).filter((r) => r.field_values['active'] !== false)
  const queries = [rows, open, historyRows, ...targetQueries]

  return (
    <CodesShell title={t('codes.title')} queries={queries}>
      <section aria-labelledby="codes-receive-title">
        <h2 id="codes-receive-title">{t('codes.receive.title')}</h2>
        <CodesErrorAlert error={receiveWrite.error} id="codes-receive-error" />
        {badLine && (
          <div role="alert" data-testid="receive-line-error" style={{ color: 'var(--color-error-dark)' }}>
            {t('codes.receive.lineError', { line: badLine.line, reason: t(entryReasonMessageId(info.entryReason)) })}
          </div>
        )}
        <label htmlFor="codes-receive-text" style={{ display: 'block' }}>
          {t('codes.receive.values')}
        </label>
        <textarea
          id="codes-receive-text"
          rows={6}
          value={text}
          aria-invalid={badLine ? true : undefined}
          onChange={(e) => setText(e.target.value)}
        />
        {badLine && <p data-testid="receive-line-value">{badLine.value}</p>}
        <SelectField
          name="kind"
          label={t('codes.receive.kind')}
          value={kind}
          options={CODE_KINDS.map((k) => ({ value: k, label: t(`codes.kind.${k}`) }))}
          placeholder={t('codes.common.choose')}
          onChange={setKind}
        />
        <Button
          variant="primary"
          size="md"
          disabled={receiveWrite.isPending || lines.length === 0 || kind === ''}
          onClick={() => void submitReceive()}
          data-testid="receive-submit"
        >
          {t('codes.receive.submit')}
        </Button>
      </section>

      <section>
        <form
          onSubmit={(e) => {
            e.preventDefault()
            setValueFilter(valueInput)
          }}
        >
          <SelectField
            name="status"
            label={t('codes.list.filterStatus')}
            value={status}
            options={STATUSES.map((s) => ({ value: s, label: t(`codes.status.${s}`) }))}
            placeholder={t('codes.common.all')}
            onChange={setStatus}
          />
          <TextField name="search" label={t('codes.list.searchValue')} value={valueInput} onChange={setValueInput} />
          <Button variant="secondary" size="md" onClick={() => setValueFilter(valueInput)} data-testid="codes-search">
            {t('codes.list.search')}
          </Button>
        </form>
        <CodesErrorAlert error={rowWrite.error} />
        {codes.length === 0 ? (
          <p>{t('codes.common.empty')}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{t('codes.common.value')}</th>
                <th>{t('codes.common.kind')}</th>
                <th>{t('codes.common.status')}</th>
                <th>{t('codes.common.target')}</th>
                <th>{t('codes.common.actions')}</th>
              </tr>
            </thead>
            <tbody>
              {codes.map((c) => {
                const st = textOf(c, 'status')
                const a = openByCode.get(c.record_id)
                const k = textOf(c, 'kind')
                return (
                  <tr key={c.record_id} data-testid={`code-row-${textOf(c, 'value')}`}>
                    <td>{textOf(c, 'value')}</td>
                    <td>{(CODE_KINDS as readonly string[]).includes(k) ? t(`codes.kind.${k}`) : dash}</td>
                    <td>{(STATUSES as readonly string[]).includes(st) ? t(`codes.status.${st}`) : dash}</td>
                    <td>{st === 'assigned' && a ? targetText(textOf(a, 'target_type'), textOf(a, 'target_id')) : dash}</td>
                    <td>
                      {st === 'not_assigned' && (
                        <Button variant="secondary" size="sm" onClick={() => startAssign(c)}>
                          {t('codes.action.assign')}
                        </Button>
                      )}
                      {st === 'assigned' && (
                        <Button
                          variant="secondary"
                          size="sm"
                          disabled={rowWrite.isPending}
                          onClick={() => void submitRow({ op: 'release', id: c.record_id })}
                        >
                          {t('codes.action.release')}
                        </Button>
                      )}
                      {st !== 'retired' && (
                        <>
                          <Button variant="secondary" size="sm" onClick={() => startChange(c)}>
                            {t('codes.action.changeValue')}
                          </Button>
                          <Button variant="danger" size="sm" onClick={() => setRetiring(c)}>
                            {t('codes.action.retire')}
                          </Button>
                        </>
                      )}
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => {
                          setHistory(c)
                        }}
                      >
                        {t('codes.action.history')}
                      </Button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </section>

      {assigning && (
        <form
          aria-label={t('codes.action.assign')}
          onSubmit={(e) => {
            e.preventDefault()
          }}
        >
          <SelectField
            name="target_type"
            label={t('codes.assign.targetType')}
            value={targetType}
            options={TARGET_TYPES.map((x) => ({ value: x, label: t(`codes.target.${x}`) }))}
            placeholder={t('codes.common.choose')}
            onChange={(v) => {
              setTargetType(v)
              setTargetId('')
            }}
          />
          <SelectField
            name="target_id"
            label={t('codes.assign.target')}
            value={targetId}
            options={pickable.map((r) => ({
              value: r.record_id,
              label: `${textOf(r, 'code')} - ${textOf(r, 'name')}`.replace(/ - $/, ''),
            }))}
            placeholder={t('codes.common.choose')}
            onChange={setTargetId}
          />
          <Button
            variant="primary"
            size="md"
            disabled={rowWrite.isPending || targetType === '' || targetId === ''}
            onClick={() =>
              void submitRow({ op: 'assign', id: assigning.record_id, targetType, targetId }, () => setAssigning(null))
            }
            data-testid="assign-confirm"
          >
            {t('codes.action.assign')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setAssigning(null)}>
            {t('codes.common.cancel')}
          </Button>
        </form>
      )}

      {changing && (
        <form
          aria-label={t('codes.action.changeValue')}
          onSubmit={(e) => {
            e.preventDefault()
          }}
        >
          <TextField name="new_value" label={t('codes.value.newValue')} value={newValue} onChange={setNewValue} />
          <Button
            variant="primary"
            size="md"
            disabled={rowWrite.isPending || newValue.trim() === ''}
            onClick={() => void submitRow({ op: 'value', id: changing.record_id, value: newValue }, () => setChanging(null))}
            data-testid="value-confirm"
          >
            {t('codes.common.save')}
          </Button>
          <Button variant="ghost" size="md" onClick={() => setChanging(null)}>
            {t('codes.common.cancel')}
          </Button>
        </form>
      )}

      {history && (
        <section aria-label={t('codes.history.title', { value: textOf(history, 'value') })} data-testid="history-panel">
          <h2>{t('codes.history.title', { value: textOf(history, 'value') })}</h2>
          {(historyRows.data ?? []).length === 0 ? (
            <p>{t('codes.history.empty')}</p>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>{t('codes.common.target')}</th>
                  <th>{t('codes.history.assignedAt')}</th>
                  <th>{t('codes.history.releasedAt')}</th>
                </tr>
              </thead>
              <tbody>
                {[...(historyRows.data ?? [])]
                  .sort((x, y) => textOf(x, 'assigned_at').localeCompare(textOf(y, 'assigned_at')))
                  .map((a) => (
                    <tr key={a.record_id} data-testid="history-row">
                      <td>{targetText(textOf(a, 'target_type'), textOf(a, 'target_id'))}</td>
                      <td>{stamp(intl, textOf(a, 'assigned_at'), dash)}</td>
                      <td>{textOf(a, 'released_at') === '' ? t('codes.history.open') : stamp(intl, textOf(a, 'released_at'), dash)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          )}
          <Button variant="ghost" size="sm" onClick={() => setHistory(null)}>
            {t('codes.common.cancel')}
          </Button>
        </section>
      )}

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
    </CodesShell>
  )
}

function stamp(intl: ReturnType<typeof useIntl>, iso: string, dash: string): string {
  if (iso === '') return dash
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : intl.formatDate(d, { dateStyle: 'medium', timeStyle: 'short' })
}

export default function CodesPage() {
  return (
    <CodesIntlProvider>
      <CodesInner />
    </CodesIntlProvider>
  )
}
