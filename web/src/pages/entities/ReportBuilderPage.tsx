/** ReportBuilderPage — REQ-634 part A
 *
 *  Lists, creates, edits and deletes the saved reports (`kind: "report"` of
 *  `/api/v1/entity-views`) of one entity type. The type comes from the route and is
 *  read-only in the editor. The run panel (aggregate call, result tables) is part B.
 *
 *  Hiding the create/save/delete controls without EntitiesViewsManage is UX only: the
 *  server enforces the permission. The route itself is wrapped in
 *  RequirePermission(EntitiesQuery) by the router.
 */

import React, { useCallback, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { reportViewsApi } from '@/api/entityViews'
import { entitiesApi } from '@/api/entities'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { P, useAccess } from '@/auth/access'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { buildFilters, toFilterRow } from '@/lib/entities/filterRows'
import { EntityFilterBuilder, type FilterRow } from '@/components/entities/EntityFilterBuilder'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError } from '@/utils/classifyError'
import type {
  EntityAggregateClause,
  EntityAggregateFn,
  EntityFieldDef,
  ReportCreateRequest,
  ReportUpdateRequest,
  ReportView,
} from '@/types/api'

const AGGREGATE_FNS: EntityAggregateFn[] = ['count', 'sum', 'avg', 'min', 'max']

interface AggregateRow {
  id: string
  fn: EntityAggregateFn
  field: string
}

interface GroupRow {
  id: string
  field: string
}

interface Draft {
  name: string
  filterRows: FilterRow[]
  groupBy: GroupRow[]
  aggregates: AggregateRow[]
  columnsText: string
  sortField: string
  sortDir: 'asc' | 'desc'
}

type Selection = { kind: 'none' } | { kind: 'new' } | { kind: 'open'; id: string }

type FieldErrors = Partial<Record<'name' | 'aggregates' | 'sort', string>>

interface ActionError {
  message: string
  retry: boolean
}

function uid(): string {
  return crypto.randomUUID()
}

function emptyDraft(): Draft {
  return {
    name: '',
    filterRows: [],
    groupBy: [],
    aggregates: [{ id: uid(), fn: 'count', field: '' }],
    columnsText: '',
    sortField: '',
    sortDir: 'asc',
  }
}

function draftFromReport(r: ReportView): Draft {
  return {
    name: r.name,
    filterRows: (r.filter ?? []).map(toFilterRow),
    groupBy: (r.group_by ?? []).map((g) => ({ id: uid(), field: g.field })),
    aggregates: (r.aggregates ?? []).map((a) => ({ id: uid(), fn: a.fn, field: a.field ?? '' })),
    columnsText: (r.columns ?? []).join(', '),
    sortField: r.sort?.[0]?.field ?? '',
    sortDir: r.sort?.[0]?.dir ?? 'asc',
  }
}

function parseColumns(text: string): string[] {
  return text
    .split(',')
    .map((c) => c.trim())
    .filter((c) => c.length > 0)
}

function statusOf(err: unknown): number | undefined {
  if (err && typeof err === 'object') {
    const s = (err as { status?: unknown }).status
    if (typeof s === 'number') return s
  }
  return undefined
}

function detailOf(err: unknown): string | undefined {
  if (err && typeof err === 'object') {
    const d = (err as { details?: Record<string, unknown> }).details?.['detail']
    if (typeof d === 'string') return d
  }
  return undefined
}

function ReportBuilderPageInner(): React.ReactElement {
  const { entityType } = useParams<{ entityType: string }>()
  const type = entityType ?? ''
  const intl = useIntl()
  const tenantKeys = useTenantScopedQueryKeys()
  const canManage = useAccess().can(P.EntitiesViewsManage)

  const [selection, setSelection] = useState<Selection>({ kind: 'none' })
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [opening, setOpening] = useState(false)
  const [notFound, setNotFound] = useState(false)
  const [busy, setBusy] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [fieldErrors, setFieldErrors] = useState<FieldErrors>({})
  const [actionError, setActionError] = useState<ActionError | null>(null)
  // A second submission while a request is in flight is a no-op, also within one tick.
  const pendingRef = useRef(false)
  const retryRef = useRef<(() => Promise<void>) | null>(null)

  const listQuery = useQuery({
    queryKey: tenantKeys.entities.reports(type),
    queryFn: () => reportViewsApi.list(type),
    enabled: type.length > 0,
    retry: false,
  })
  const reports = listQuery.data?.items ?? []

  // Definition field names feed the inputs; if the fetch fails they stay free text.
  const definitionQuery = useQuery({
    queryKey: tenantKeys.entities.definition(type),
    queryFn: () => entitiesApi.getActiveDefinition(type),
    enabled: type.length > 0,
    retry: false,
  })
  const fields: EntityFieldDef[] = useMemo(
    () => definitionQuery.data?.definition.fields ?? [],
    [definitionQuery.data],
  )
  const listId = 'report-field-names'

  const patch = (p: Partial<Draft>) => setDraft((d) => ({ ...d, ...p }))

  const failure = useCallback(
    (err: unknown): ActionError => {
      const status = statusOf(err)
      const id =
        status === 400
          ? 'entities.reports.error.badRequest'
          : status === 403
            ? 'entities.reports.error.forbidden'
            : status === 404
              ? 'entities.reports.error.notFound'
              : status === 409
                ? 'entities.reports.error.conflict'
                : status === 422
                  ? `entities.reports.error.unprocessable.${detailOf(err) ?? ''}`
                  : null
      if (id && status === 422 && !(id in intl.messages)) {
        return { message: intl.formatMessage({ id: 'entities.reports.error.unprocessable.unknown' }), retry: false }
      }
      if (id) return { message: intl.formatMessage({ id }), retry: false }
      if (status === undefined) {
        return { message: intl.formatMessage({ id: 'entities.reports.error.network' }), retry: true }
      }
      return { message: intl.formatMessage({ id: 'entities.reports.error.generic' }), retry: false }
    },
    [intl],
  )

  /** Runs one request under the pending guard; the draft is never touched on failure. */
  const guarded = async (action: () => Promise<void>) => {
    if (pendingRef.current) return
    pendingRef.current = true
    setBusy(true)
    setActionError(null)
    retryRef.current = () => guarded(action)
    try {
      await action()
    } catch (err) {
      setActionError(failure(err))
    } finally {
      pendingRef.current = false
      setBusy(false)
    }
  }

  const handleNew = () => {
    setSelection({ kind: 'new' })
    setDraft(emptyDraft())
    setNotFound(false)
    setFieldErrors({})
    setActionError(null)
  }

  const handleOpen = async (id: string) => {
    if (pendingRef.current) return
    pendingRef.current = true
    setBusy(true)
    setOpening(true)
    setNotFound(false)
    setFieldErrors({})
    setActionError(null)
    retryRef.current = () => handleOpen(id)
    try {
      const report = await reportViewsApi.get(id)
      setDraft(draftFromReport(report))
      setSelection({ kind: 'open', id })
    } catch (err) {
      if (statusOf(err) === 404) {
        setSelection({ kind: 'none' })
        setNotFound(true)
      } else {
        setActionError(failure(err))
      }
    } finally {
      pendingRef.current = false
      setBusy(false)
      setOpening(false)
    }
  }

  const handleClose = () => {
    setSelection({ kind: 'none' })
    setFieldErrors({})
    setActionError(null)
  }

  /** Local validation; returns the request body, or null (no request) with field messages set. */
  const validate = (): ReportUpdateRequest | null => {
    const errors: FieldErrors = {}
    const name = draft.name.trim()
    if (name.length === 0) errors.name = intl.formatMessage({ id: 'entities.reports.error.nameRequired' })
    const aggregates: EntityAggregateClause[] = draft.aggregates.map((a) => {
      const field = a.field.trim()
      return field ? { fn: a.fn, field } : { fn: a.fn }
    })
    // a non-count function needs a field to aggregate
    if (aggregates.length === 0 || aggregates.some((a) => a.fn !== 'count' && !a.field)) {
      errors.aggregates = intl.formatMessage({ id: 'entities.reports.error.aggregateRequired' })
    }
    const columns = parseColumns(draft.columnsText)
    const sortField = draft.sortField.trim()
    if (sortField && columns.length === 0) {
      errors.sort = intl.formatMessage({ id: 'entities.reports.error.sortNeedsColumns' })
    }
    setFieldErrors(errors)
    if (Object.keys(errors).length > 0) return null
    const body: ReportUpdateRequest = {
      name,
      filter: buildFilters(draft.filterRows, fields),
      group_by: draft.groupBy.filter((g) => g.field.trim()).map((g) => ({ field: g.field.trim() })),
      aggregates,
    }
    if (columns.length > 0) body.columns = columns
    if (sortField) body.sort = [{ field: sortField, dir: draft.sortDir }]
    return body
  }

  const handleSave = () => {
    if (!canManage || pendingRef.current) return
    const body = validate()
    if (!body) return
    void guarded(async () => {
      if (selection.kind === 'open') {
        await reportViewsApi.update(selection.id, body)
      } else {
        const create: ReportCreateRequest = { entity_type: type, ...body }
        const created = await reportViewsApi.create(create)
        setSelection({ kind: 'open', id: created.id })
      }
      await listQuery.refetch()
    })
  }

  const handleDelete = () => {
    setConfirmOpen(false)
    if (!canManage || selection.kind !== 'open') return
    const id = selection.id
    void guarded(async () => {
      await reportViewsApi.remove(id)
      setSelection({ kind: 'none' })
      await listQuery.refetch()
    })
  }

  const inputStyle: React.CSSProperties = {
    border: '1px solid var(--border-default)',
    borderRadius: 'var(--radius-sm)',
    padding: 'var(--space-1) var(--space-2)',
    background: 'var(--surface-card)',
    color: 'var(--text-primary)',
  }
  const sectionStyle: React.CSSProperties = {
    display: 'flex',
    flexDirection: 'column',
    gap: 'var(--space-3)',
    padding: 'var(--space-4)',
    border: '1px solid var(--border-default)',
    borderRadius: 'var(--radius-md)',
    background: 'var(--surface-card)',
  }
  const alertStyle: React.CSSProperties = { color: 'var(--color-error-dark)' }
  const readOnly = !canManage

  const editing = selection.kind !== 'none'

  return (
    <PageLayout
      title={`${intl.formatMessage({ id: 'entities.reports.title' })}: ${type}`}
      actions={
        canManage ? (
          <Button variant="primary" size="md" disabled={busy} onClick={handleNew} data-testid="report-new">
            {intl.formatMessage({ id: 'entities.reports.new.action' })}
          </Button>
        ) : undefined
      }
    >
      <datalist id={listId}>
        {fields.map((f) => (
          <option key={f.name} value={f.name} />
        ))}
      </datalist>

      <section style={sectionStyle} aria-label={intl.formatMessage({ id: 'entities.reports.list.label' })}>
        <strong>{intl.formatMessage({ id: 'entities.reports.list.label' })}</strong>
        <div
          data-testid={listQuery.isLoading ? 'reports-loading' : undefined}
          aria-label={listQuery.isLoading ? intl.formatMessage({ id: 'entities.reports.list.loading' }) : undefined}
        >
          <QueryStateBoundary
            state={listQuery.isLoading ? 'loading' : listQuery.isError ? classifyError(listQuery.error) : 'success'}
            onRetry={() => void listQuery.refetch()}
          >
        {reports.length === 0 && (
          <div data-testid="reports-empty">
            <p>{intl.formatMessage({ id: 'entities.reports.list.empty' })}</p>
            {canManage && (
              <Button variant="primary" size="sm" disabled={busy} onClick={handleNew} data-testid="report-empty-create">
                {intl.formatMessage({ id: 'entities.reports.list.emptyCreate' })}
              </Button>
            )}
          </div>
        )}
        {reports.length > 0 && (
          <ul data-testid="reports-list" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
            {reports.map((r) => (
              <li key={r.id}>
                <button
                  type="button"
                  data-testid={`report-open-${r.id}`}
                  disabled={busy}
                  onClick={() => void handleOpen(r.id)}
                  style={{ ...inputStyle, cursor: busy ? 'not-allowed' : 'pointer' }}
                >
                  {r.name}
                </button>
              </li>
            ))}
          </ul>
        )}
          </QueryStateBoundary>
        </div>
        {opening && (
          <div data-testid="report-opening">{intl.formatMessage({ id: 'entities.reports.open.loading' })}</div>
        )}
        {notFound && (
          <div role="alert" data-testid="report-not-found" style={alertStyle}>
            {intl.formatMessage({ id: 'entities.reports.open.notFound' })}
          </div>
        )}
      </section>

      {editing && (
        <section style={sectionStyle} data-testid="report-editor">
          <strong>
            {intl.formatMessage({
              id: selection.kind === 'new' ? 'entities.reports.editor.titleNew' : 'entities.reports.editor.titleEdit',
            })}
          </strong>
          {readOnly && <p data-testid="report-readonly">{intl.formatMessage({ id: 'entities.reports.readOnly.notice' })}</p>}

          <label htmlFor="report-entity-type">{intl.formatMessage({ id: 'entities.reports.field.entityType' })}</label>
          <input id="report-entity-type" style={inputStyle} value={type} readOnly disabled />

          <label htmlFor="report-name">{intl.formatMessage({ id: 'entities.reports.field.name' })}</label>
          <input
            id="report-name"
            style={inputStyle}
            value={draft.name}
            disabled={readOnly}
            onChange={(e) => patch({ name: e.target.value })}
          />
          {fieldErrors.name && (
            <div role="alert" data-testid="report-name-error" style={alertStyle}>
              {fieldErrors.name}
            </div>
          )}

          <strong>{intl.formatMessage({ id: 'entities.reports.field.filter' })}</strong>
          <EntityFilterBuilder fields={fields} rows={draft.filterRows} onChange={(rows) => patch({ filterRows: rows })} />

          <strong>{intl.formatMessage({ id: 'entities.reports.field.groupBy' })}</strong>
          {draft.groupBy.map((g, i) => (
            <div key={g.id} style={{ display: 'flex', gap: 'var(--space-2)' }}>
              <input
                aria-label={intl.formatMessage({ id: 'entities.reports.field.groupBy' })}
                data-testid={`report-group-${i}`}
                list={listId}
                style={inputStyle}
                value={g.field}
                disabled={readOnly}
                onChange={(e) =>
                  patch({ groupBy: draft.groupBy.map((x) => (x.id === g.id ? { ...x, field: e.target.value } : x)) })
                }
              />
              {!readOnly && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => patch({ groupBy: draft.groupBy.filter((x) => x.id !== g.id) })}
                >
                  {intl.formatMessage({ id: 'entities.reports.groupBy.remove' })}
                </Button>
              )}
            </div>
          ))}
          {!readOnly && (
            <div>
              <Button
                variant="secondary"
                size="sm"
                data-testid="report-group-add"
                onClick={() => patch({ groupBy: [...draft.groupBy, { id: uid(), field: '' }] })}
              >
                {intl.formatMessage({ id: 'entities.reports.groupBy.add' })}
              </Button>
            </div>
          )}

          <strong>{intl.formatMessage({ id: 'entities.reports.field.aggregates' })}</strong>
          {draft.aggregates.map((a, i) => (
            <div key={a.id} style={{ display: 'flex', gap: 'var(--space-2)', alignItems: 'center' }}>
              <select
                aria-label={intl.formatMessage({ id: 'entities.reports.aggregate.fn' })}
                data-testid={`report-agg-fn-${i}`}
                style={inputStyle}
                value={a.fn}
                disabled={readOnly}
                onChange={(e) =>
                  patch({
                    aggregates: draft.aggregates.map((x) =>
                      x.id === a.id ? { ...x, fn: e.target.value as EntityAggregateFn } : x,
                    ),
                  })
                }
              >
                {AGGREGATE_FNS.map((fn) => (
                  <option key={fn} value={fn}>
                    {fn}
                  </option>
                ))}
              </select>
              <input
                aria-label={intl.formatMessage({ id: 'entities.reports.aggregate.field' })}
                data-testid={`report-agg-field-${i}`}
                list={listId}
                style={inputStyle}
                value={a.field}
                disabled={readOnly}
                onChange={(e) =>
                  patch({ aggregates: draft.aggregates.map((x) => (x.id === a.id ? { ...x, field: e.target.value } : x)) })
                }
              />
              {!readOnly && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => patch({ aggregates: draft.aggregates.filter((x) => x.id !== a.id) })}
                >
                  {intl.formatMessage({ id: 'entities.reports.aggregate.remove' })}
                </Button>
              )}
            </div>
          ))}
          {!readOnly && (
            <div>
              <Button
                variant="secondary"
                size="sm"
                data-testid="report-agg-add"
                onClick={() => patch({ aggregates: [...draft.aggregates, { id: uid(), fn: 'count', field: '' }] })}
              >
                {intl.formatMessage({ id: 'entities.reports.aggregate.add' })}
              </Button>
            </div>
          )}
          {fieldErrors.aggregates && (
            <div role="alert" data-testid="report-aggregates-error" style={alertStyle}>
              {fieldErrors.aggregates}
            </div>
          )}

          <label htmlFor="report-columns">{intl.formatMessage({ id: 'entities.reports.field.columns' })}</label>
          <input
            id="report-columns"
            list={listId}
            style={inputStyle}
            value={draft.columnsText}
            disabled={readOnly}
            onChange={(e) => patch({ columnsText: e.target.value })}
          />

          <label htmlFor="report-sort-field">{intl.formatMessage({ id: 'entities.reports.field.sort' })}</label>
          <div style={{ display: 'flex', gap: 'var(--space-2)' }}>
            <input
              id="report-sort-field"
              list={listId}
              style={inputStyle}
              value={draft.sortField}
              disabled={readOnly}
              onChange={(e) => patch({ sortField: e.target.value })}
            />
            <select
              aria-label={intl.formatMessage({ id: 'entities.reports.field.sort' })}
              data-testid="report-sort-dir"
              style={inputStyle}
              value={draft.sortDir}
              disabled={readOnly}
              onChange={(e) => patch({ sortDir: e.target.value as 'asc' | 'desc' })}
            >
              <option value="asc">{intl.formatMessage({ id: 'entities.reports.sort.asc' })}</option>
              <option value="desc">{intl.formatMessage({ id: 'entities.reports.sort.desc' })}</option>
            </select>
          </div>
          {fieldErrors.sort && (
            <div role="alert" data-testid="report-sort-error" style={alertStyle}>
              {fieldErrors.sort}
            </div>
          )}

          {actionError && (
            <div role="alert" data-testid="report-error" style={alertStyle}>
              {actionError.message}{' '}
              {actionError.retry && (
                <Button
                  variant="secondary"
                  size="sm"
                  data-testid="report-retry"
                  disabled={busy}
                  onClick={() => void retryRef.current?.()}
                >
                  {intl.formatMessage({ id: 'entities.reports.error.retry' })}
                </Button>
              )}
            </div>
          )}

          <div style={{ display: 'flex', gap: 'var(--space-3)' }}>
            {canManage && (
              <Button variant="primary" size="md" data-testid="report-save" disabled={busy} onClick={handleSave}>
                {intl.formatMessage({ id: busy ? 'entities.reports.saving' : 'entities.reports.save' })}
              </Button>
            )}
            {canManage && selection.kind === 'open' && (
              <Button variant="danger" size="md" data-testid="report-delete" disabled={busy} onClick={() => setConfirmOpen(true)}>
                {intl.formatMessage({ id: 'entities.reports.delete.action' })}
              </Button>
            )}
            <Button variant="secondary" size="md" data-testid="report-close" disabled={busy} onClick={handleClose}>
              {intl.formatMessage({ id: 'entities.reports.cancel' })}
            </Button>
          </div>
          <ConfirmDialog
            open={confirmOpen}
            title={intl.formatMessage({ id: 'entities.reports.delete.confirmTitle' })}
            body={intl.formatMessage({ id: 'entities.reports.delete.confirmBody' })}
            confirmText={intl.formatMessage({ id: 'entities.reports.delete.confirmAction' })}
            cancelText={intl.formatMessage({ id: 'entities.reports.delete.cancelAction' })}
            confirmVariant="danger"
            isLoading={busy}
            onConfirm={handleDelete}
            onCancel={() => setConfirmOpen(false)}
          />
        </section>
      )}
    </PageLayout>
  )
}

export function ReportBuilderPage(): React.ReactElement {
  const { entityType } = useParams<{ entityType: string }>()
  // key: a different entity type starts with a fresh editor
  return (
    <EntitiesIntlProvider>
      <ReportBuilderPageInner key={entityType ?? ''} />
    </EntitiesIntlProvider>
  )
}

export default ReportBuilderPage
