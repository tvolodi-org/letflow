/** SolutionPackOverridesPage — REQ-631 part A
 *
 *  Lists, creates, edits (a new version) and retires the per-tenant overrides of one solution
 *  pack, over the four REQ-596 routes. Route: `/solution-packs/:packId/overrides`, wrapped in
 *  RequirePermission(DefinitionsRead) by the router.
 *
 *  Hiding the create/edit/retire controls without SolutionOverridesManage is UX only: the server
 *  enforces the permission. The tenant is never sent: it comes from the session. A failed write
 *  keeps the input and does not touch the list; only a 2xx refetches it. An override is never
 *  deleted or patched in place: edit is a new version, retire is its own POST.
 */

import React, { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { solutionPacksApi, type PackOverride } from '@/api/solutionPacks'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { P, useAccess } from '@/auth/access'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError } from '@/utils/classifyError'

const ARTEFACT_TYPES = ['process_definition', 'variable_schema'] as const

/** 422 details that map to a field of the form; every other known detail is a general message. */
const FIELD_OF_DETAIL: Record<string, 'patch' | 'id' | 'reason'> = {
  property_not_overridable: 'patch',
  override_exists: 'id',
  reason_required: 'reason',
}

const GENERAL_DETAILS = new Set([
  'override_version_taken',
  'override_retired',
  'invalid_patch_value',
  'invalid_input',
])

type FormMode = { kind: 'create' } | { kind: 'edit'; row: PackOverride }

interface FormErrors {
  patch?: string
  id?: string
  reason?: string
  general?: string
}

const errorStyle: React.CSSProperties = { color: 'var(--color-error-dark)', fontSize: '.85rem' }
const fieldStyle: React.CSSProperties = {
  width: '100%',
  padding: '.4rem .6rem',
  borderRadius: '4px',
  border: '1px solid var(--border-default)',
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

/** One row per override_id: the list is the latest version already; keep the highest defensively. */
function latestPerOverride(rows: PackOverride[]): PackOverride[] {
  const byId = new Map<string, PackOverride>()
  for (const row of rows) {
    const seen = byId.get(row.override_id)
    if (!seen || row.override_version > seen.override_version) byId.set(row.override_id, row)
  }
  return [...byId.values()]
}

/** The patch text must parse to a JSON object (not an array, not null). */
function parsePatch(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(text)
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    // fall through
  }
  return null
}

function SolutionPackOverridesPageInner(): React.ReactElement {
  const { packId: packIdParam } = useParams<{ packId: string }>()
  const packId = packIdParam ?? ''
  const intl = useIntl()
  const access = useAccess()
  const canManage = access.can(P.SolutionOverridesManage)
  const queryClient = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const listKey = tenantKeys.solutionPackOverrides.list(packId)

  const listQuery = useQuery({
    queryKey: listKey,
    queryFn: () => solutionPacksApi.listOverrides(packId),
  })

  const [form, setForm] = useState<FormMode | null>(null)
  const [artefactType, setArtefactType] = useState<string>(ARTEFACT_TYPES[0])
  const [artefactId, setArtefactId] = useState('')
  const [patchText, setPatchText] = useState('{}')
  const [reason, setReason] = useState('')
  const [errors, setErrors] = useState<FormErrors>({})
  const [retireRow, setRetireRow] = useState<PackOverride | null>(null)
  const [retireReason, setRetireReason] = useState('')
  const [retireError, setRetireError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const msg = (id: string): string => intl.formatMessage({ id: `solutionOverrides.${id}` })

  const openCreate = (): void => {
    setRetireRow(null)
    setForm({ kind: 'create' })
    setArtefactType(ARTEFACT_TYPES[0])
    setArtefactId('')
    setPatchText('{}')
    setReason('')
    setErrors({})
  }

  const openEdit = (row: PackOverride): void => {
    setRetireRow(null)
    setForm({ kind: 'edit', row })
    setPatchText(JSON.stringify(row.patch, null, 2))
    setReason('')
    setErrors({})
  }

  const openRetire = (row: PackOverride): void => {
    setForm(null)
    setRetireRow(row)
    setRetireReason('')
    setRetireError(null)
  }

  /** Maps a failed write to a message; `field` is set only for the 422 details tied to a field. */
  const failure = (err: unknown): { field?: 'patch' | 'id' | 'reason'; message: string } => {
    const status = statusOf(err)
    if (status === 422) {
      const detail = detailOf(err) ?? ''
      if (detail in FIELD_OF_DETAIL) {
        return { field: FIELD_OF_DETAIL[detail], message: msg(`error.${detail}`) }
      }
      return { message: msg(GENERAL_DETAILS.has(detail) ? `error.${detail}` : 'error.unknown') }
    }
    if (status === 404) return { message: msg('notFound') }
    if (status === 403) return { message: msg('error.forbidden') }
    if (status === undefined) return { message: msg('error.network') }
    return { message: msg('error.generic') }
  }

  const refetchAfterWrite = async (): Promise<void> => {
    await queryClient.invalidateQueries({ queryKey: listKey })
  }

  const submitForm = async (): Promise<void> => {
    if (!form || submitting) return
    const next: FormErrors = {}
    const patch = parsePatch(patchText)
    if (form.kind === 'create' && artefactId.trim() === '') next.id = msg('error.artefactIdRequired')
    if (patch === null) next.patch = msg('error.patchInvalid')
    if (reason.trim() === '') next.reason = msg('error.reasonRequired')
    if (patch === null || Object.keys(next).length > 0) {
      setErrors(next)
      return
    }
    setErrors({})
    setSubmitting(true)
    try {
      if (form.kind === 'create') {
        await solutionPacksApi.createOverride(packId, {
          artefact_type: artefactType,
          artefact_id: artefactId.trim(),
          patch,
          reason: reason.trim(),
        })
      } else {
        await solutionPacksApi.newOverrideVersion(packId, form.row.override_id, {
          patch,
          reason: reason.trim(),
          base_version: form.row.override_version,
        })
      }
      setForm(null)
      await refetchAfterWrite()
    } catch (err) {
      const { field, message } = failure(err)
      setErrors(field ? { [field]: message } : { general: message })
    } finally {
      setSubmitting(false)
    }
  }

  const submitRetire = async (): Promise<void> => {
    if (!retireRow || submitting || retireReason.trim() === '') return
    setSubmitting(true)
    setRetireError(null)
    try {
      await solutionPacksApi.retireOverride(packId, retireRow.override_id, {
        reason: retireReason.trim(),
        base_version: retireRow.override_version,
      })
      setRetireRow(null)
      await refetchAfterWrite()
    } catch (err) {
      setRetireError(failure(err).message)
    } finally {
      setSubmitting(false)
    }
  }

  const rows = latestPerOverride(listQuery.data?.overrides ?? [])
  const listNotFound = listQuery.isError && statusOf(listQuery.error) === 404
  const statusLabel = (s: string): string =>
    intl.messages[`solutionOverrides.status.${s}`] ? msg(`status.${s}`) : s

  return (
    <PageLayout title={msg('title')}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }} data-testid="overrides-page">
        {listNotFound ? (
          <div role="alert" data-testid="overrides-not-found" style={errorStyle}>
            {msg('notFound')}
          </div>
        ) : (
          <QueryStateBoundary
            state={listQuery.isLoading ? 'loading' : listQuery.isError ? classifyError(listQuery.error) : 'success'}
            onRetry={() => void listQuery.refetch()}
          >
            {canManage && form === null && (
              <div>
                <Button variant="primary" size="sm" data-testid="override-new" onClick={openCreate}>
                  {msg('action.create')}
                </Button>
              </div>
            )}
            {rows.length === 0 ? (
              <p data-testid="overrides-empty">{msg('list.empty')}</p>
            ) : (
              <table data-testid="overrides-table" style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead>
                  <tr>
                    <th>{msg('column.type')}</th>
                    <th>{msg('column.id')}</th>
                    <th>{msg('column.version')}</th>
                    <th>{msg('column.madeAgainst')}</th>
                    <th>{msg('column.status')}</th>
                    <th>{msg('column.reason')}</th>
                    {canManage && <th>{msg('column.actions')}</th>}
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.override_id} data-testid={`override-row-${row.override_id}`}>
                      <td>{row.artefact_type}</td>
                      <td>{row.artefact_id}</td>
                      <td>{row.override_version}</td>
                      <td>{row.made_against}</td>
                      <td>{statusLabel(row.status)}</td>
                      <td>{row.reason}</td>
                      {canManage && (
                        <td>
                          {row.status === 'active' && (
                            <Button
                              variant="secondary"
                              size="sm"
                              data-testid={`override-edit-${row.override_id}`}
                              onClick={() => openEdit(row)}
                            >
                              {msg('action.edit')}
                            </Button>
                          )}
                          {(row.status === 'active' || row.status === 'orphaned') && (
                            <Button
                              variant="danger"
                              size="sm"
                              data-testid={`override-retire-${row.override_id}`}
                              onClick={() => openRetire(row)}
                            >
                              {msg('action.retire')}
                            </Button>
                          )}
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </QueryStateBoundary>
        )}

        {canManage && form !== null && (
          <section data-testid="override-form" style={{ display: 'flex', flexDirection: 'column', gap: '.75rem', maxWidth: '720px' }}>
            {form.kind === 'create' ? (
              <>
                <label>
                  {msg('field.type')}
                  <select
                    style={fieldStyle}
                    value={artefactType}
                    disabled={submitting}
                    onChange={(e) => setArtefactType(e.target.value)}
                  >
                    {ARTEFACT_TYPES.map((t) => (
                      <option key={t} value={t}>
                        {t}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  {msg('field.id')}
                  <input
                    type="text"
                    style={fieldStyle}
                    value={artefactId}
                    disabled={submitting}
                    onChange={(e) => setArtefactId(e.target.value)}
                  />
                </label>
                {errors.id && (
                  <div role="alert" data-testid="override-error-id" style={errorStyle}>
                    {errors.id}
                  </div>
                )}
              </>
            ) : (
              <div data-testid="override-edit-target">
                {form.row.artefact_type} / {form.row.artefact_id}
              </div>
            )}
            <label>
              {msg('field.patch')}
              <textarea
                rows={10}
                style={{ ...fieldStyle, fontFamily: 'monospace' }}
                value={patchText}
                disabled={submitting}
                onChange={(e) => setPatchText(e.target.value)}
              />
            </label>
            {errors.patch && (
              <div role="alert" data-testid="override-error-patch" style={errorStyle}>
                {errors.patch}
              </div>
            )}
            <label>
              {msg('field.reason')}
              <textarea
                rows={2}
                style={fieldStyle}
                value={reason}
                disabled={submitting}
                onChange={(e) => setReason(e.target.value)}
              />
            </label>
            {errors.reason && (
              <div role="alert" data-testid="override-error-reason" style={errorStyle}>
                {errors.reason}
              </div>
            )}
            {errors.general && (
              <div role="alert" data-testid="override-error-general" style={errorStyle}>
                {errors.general}
              </div>
            )}
            <div style={{ display: 'flex', gap: '.5rem' }}>
              <Button
                variant="primary"
                size="md"
                data-testid="override-save"
                loading={submitting}
                disabled={submitting}
                onClick={() => void submitForm()}
              >
                {msg('action.save')}
              </Button>
              <Button variant="ghost" size="md" data-testid="override-cancel" disabled={submitting} onClick={() => setForm(null)}>
                {msg('action.cancel')}
              </Button>
            </div>
          </section>
        )}

        {canManage && retireRow !== null && (
          <section
            role="group"
            aria-label={msg('retire.title')}
            data-testid="override-retire-panel"
            style={{ display: 'flex', flexDirection: 'column', gap: '.75rem', maxWidth: '720px' }}
          >
            <strong>{msg('retire.title')}</strong>
            <p>{msg('retire.body')}</p>
            <label>
              {msg('field.reason')}
              <textarea
                rows={2}
                style={fieldStyle}
                value={retireReason}
                disabled={submitting}
                onChange={(e) => setRetireReason(e.target.value)}
              />
            </label>
            {retireError && (
              <div role="alert" data-testid="override-retire-error" style={errorStyle}>
                {retireError}
              </div>
            )}
            <div style={{ display: 'flex', gap: '.5rem' }}>
              <Button
                variant="danger"
                size="md"
                data-testid="override-retire-confirm"
                loading={submitting}
                disabled={submitting || retireReason.trim() === ''}
                onClick={() => void submitRetire()}
              >
                {msg('action.confirmRetire')}
              </Button>
              <Button
                variant="ghost"
                size="md"
                data-testid="override-retire-cancel"
                disabled={submitting}
                onClick={() => setRetireRow(null)}
              >
                {msg('action.cancel')}
              </Button>
            </div>
          </section>
        )}
      </div>
    </PageLayout>
  )
}

export function SolutionPackOverridesPage(): React.ReactElement {
  return (
    <EntitiesIntlProvider>
      <SolutionPackOverridesPageInner />
    </EntitiesIntlProvider>
  )
}

function PackOverridesLinkInner({ packId }: { packId: string }): React.ReactElement {
  const intl = useIntl()
  return (
    <Link data-testid="solution-pack-overrides-link" to={`/solution-packs/${encodeURIComponent(packId)}/overrides`}>
      {intl.formatMessage({ id: 'solutionOverrides.link' })}
    </Link>
  )
}

/** Launcher link to the overrides screen of a pack; carries its own intl, the launcher has none. */
export function PackOverridesLink({ packId }: { packId: string }): React.ReactElement {
  return (
    <EntitiesIntlProvider>
      <PackOverridesLinkInner packId={packId} />
    </EntitiesIntlProvider>
  )
}

export default SolutionPackOverridesPage
