/** DefinitionRollbackPage — REQ-371: operator-facing rollback/withdrawal
 *  screen for a released process definition.
 *
 *  Implements `lib/letflow/design/req371-rollback-withdrawal-screen.md`
 *  verbatim. `:id` is the definition row id of the currently-active
 *  version; the page resolves `process_key` itself via
 *  `useDefinition(id).data.name` (§2).
 *
 *  Role gating (§6) deliberately diverges from `DefinitionListPage.tsx`'s
 *  `DESIGNER_ROLES` — `POST .../rollback` is `:Unknown`-gated, i.e.
 *  platform-admin role-only, matching `PromotionReviewPage.tsx`'s own gate on an
 *  equally `:Unknown`-gated route, not `DefinitionListPage.tsx`'s broader
 *  `DefinitionsWrite`-gated `DESIGNER_ROLES`.
 */

import React, { useMemo, useState } from 'react'
import { useParams, Navigate } from 'react-router-dom'
import { P, useAccess, AccessPending } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { useDefinition, useDefinitionVersions, useRollbackDefinition } from '@/hooks/useDefinitions'
import type { RollbackResult } from '@/api/definitionRollback'
import type { ApiError, ProcessDefinition } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { formatDateTime } from '@/i18n/format'

const OTHER_VERSION_SENTINEL = '__other__'

type RollbackPhase = 'idle' | 'confirming' | 'submitting'

type RollbackErrorKind = 'forbidden' | 'not_found' | 'version_never_active' | 'already_active' | 'unknown'

/** §5 — the classifier that disambiguates the two 422 cases. Reads
 *  `err.details.detail` (the RFC 9457 problem document's `detail` field,
 *  preserved by `client.ts`'s error mapping), NEVER `err.message` — both
 *  422s share the identical title ("Unprocessable Entity"), so
 *  `err.message` cannot distinguish them (§1.3). Exact-string comparison
 *  against the two literal server strings is deliberate, not a
 *  substring/`.includes()` match.
 */
export function classifyRollbackError(err: ApiError): RollbackErrorKind {
  const detail = typeof err.details?.detail === 'string' ? err.details.detail : undefined
  if (err.status === 403) return 'forbidden'
  if (err.status === 404) return 'not_found'
  if (err.status === 422 && detail === 'target_version was never active') return 'version_never_active'
  if (err.status === 422 && detail === 'target_version is already the active version') return 'already_active'
  return 'unknown'
}

interface RollbackHistoryEntry {
  actor: string
  timestamp: Date
  restoredVersion: string
  rolledBackFromVersion: string
  reason: string
  eventId: string
}

export default function DefinitionRollbackPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>()
  const { session } = useAuth()
  const access = useAccess()
  const isAllowed = access.can(P.DefinitionsRollback)

  const { data: def, isLoading, isError, error, refetch } = useDefinition(id ?? '')
  const processKey = (def as ProcessDefinition | undefined)?.name ?? ''
  const versionsQuery = useDefinitionVersions(processKey)
  const rollback = useRollbackDefinition()

  const [targetVersionSelect, setTargetVersionSelect] = useState('')
  const [targetVersionManual, setTargetVersionManual] = useState('')
  const [reason, setReason] = useState('')
  const [phase, setPhase] = useState<RollbackPhase>('idle')
  const [rollbackError, setRollbackError] = useState<ApiError | null>(null)
  const [successResult, setSuccessResult] = useState<RollbackResult | null>(null)
  const [history, setHistory] = useState<RollbackHistoryEntry[]>([])

  const isOther = targetVersionSelect === OTHER_VERSION_SENTINEL
  const targetVersion = (isOther ? targetVersionManual : targetVersionSelect).trim()
  const canContinue = targetVersion !== '' && reason.trim() !== ''

  const versionOptions = useMemo(() => {
    const items = (versionsQuery.data as { items?: ProcessDefinition[] } | undefined)?.items ?? []
    return items.filter((v) => v.status !== 'ACTIVE')
  }, [versionsQuery.data])

  const state: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const handleContinue = () => {
    if (!canContinue) return
    setRollbackError(null)
    setPhase('confirming')
  }

  const handleCancel = () => {
    setPhase('idle')
    setRollbackError(null)
  }

  const handleConfirm = async () => {
    if (!processKey || !targetVersion) return
    setPhase('submitting')
    setRollbackError(null)
    const confirmedAt = new Date()
    try {
      const result = await rollback.mutateAsync({ processKey, targetVersion })
      setSuccessResult(result)
      setHistory((prev) => [
        {
          actor: session?.display_name ?? 'unknown operator',
          timestamp: confirmedAt,
          restoredVersion: result.version,
          rolledBackFromVersion: result.rolled_back_from_version,
          reason,
          eventId: result.event_id,
        },
        ...prev,
      ])
      setTargetVersionSelect('')
      setTargetVersionManual('')
      setReason('')
      setPhase('idle')
    } catch (err) {
      setRollbackError(err as ApiError)
      setPhase('confirming')
    }
  }

  const errorKind = rollbackError ? classifyRollbackError(rollbackError) : null

  return (
    <PageLayout title="Roll back process definition">
      <QueryStateBoundary state={state} onRetry={() => { void refetch() }}>
        {def && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem', maxWidth: '640px' }}>
            {/* §4 step 1 — header */}
            <div>
              <h3 style={{ margin: '0 0 .35rem' }}>{def.name}</h3>
              <div style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
                <span data-testid="rollback-current-version" style={{ fontSize: '.9rem', color: 'var(--text-secondary)' }}>
                  Current active version: <strong>{def.version}</strong>
                </span>
                <StatusBadge status={def.status} domain="definition" size="sm" />
              </div>
            </div>

            {/* §4 step 2 — version picker */}
            <div>
              <label htmlFor="rollback-target-version" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
                Roll back to version
              </label>
              {!isOther ? (
                <select
                  id="rollback-target-version"
                  data-testid="rollback-target-version-select"
                  value={targetVersionSelect}
                  disabled={phase === 'submitting'}
                  onChange={(e) => setTargetVersionSelect(e.target.value)}
                  style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
                >
                  <option value="" disabled>
                    Select a version…
                  </option>
                  {versionOptions.map((v) => (
                    <option key={v.id} value={v.version}>
                      {v.version} — {v.status}
                    </option>
                  ))}
                  <option data-testid="rollback-target-version-other" value={OTHER_VERSION_SENTINEL}>
                    Other version…
                  </option>
                </select>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '.35rem' }}>
                  <input
                    data-testid="rollback-target-version-manual"
                    type="text"
                    value={targetVersionManual}
                    disabled={phase === 'submitting'}
                    onChange={(e) => setTargetVersionManual(e.target.value)}
                    placeholder="e.g. 9.9.9"
                    style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
                  />
                  <button
                    type="button"
                    data-testid="rollback-target-version-manual-cancel"
                    onClick={() => { setTargetVersionSelect(''); setTargetVersionManual('') }}
                    disabled={phase === 'submitting'}
                    style={{ alignSelf: 'flex-start', background: 'none', border: 'none', color: 'var(--interactive-primary)', cursor: 'pointer', padding: 0, fontSize: '.8rem' }}
                  >
                    Choose from the list instead
                  </button>
                </div>
              )}
            </div>

            {/* §4 step 3 — reason field (client-side only, not sent to the server) */}
            <div>
              <label htmlFor="rollback-reason-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
                Reason
              </label>
              <textarea
                id="rollback-reason-input"
                data-testid="rollback-reason-input"
                value={reason}
                disabled={phase === 'submitting'}
                onChange={(e) => setReason(e.target.value)}
                rows={3}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)', fontFamily: 'inherit' }}
              />
              <p style={{ fontSize: '.75rem', color: 'var(--text-secondary)', margin: '.35rem 0 0' }}>
                Recorded in this session's change history below. Not sent to the server — see
                design note in REQ-371 if this needs to persist across reloads.
              </p>
            </div>

            {phase === 'idle' && (
              <div>
                <Button
                  variant="primary"
                  size="md"
                  data-testid="rollback-continue-btn"
                  disabled={!canContinue}
                  onClick={handleContinue}
                >
                  Continue
                </Button>
              </div>
            )}

            {/* §5 — error rendering, shown above the confirmation panel */}
            {errorKind === 'forbidden' && (
              <div data-testid="rollback-error-forbidden" style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}>
                You don't have permission to roll back this process definition. Rollback is
                restricted to platform administrators.
              </div>
            )}
            {errorKind === 'not_found' && (
              <div data-testid="rollback-error-not-found" style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}>
                {def.name} has no active version to roll back — it may have been archived or
                deprecated since this page loaded.
              </div>
            )}
            {errorKind === 'version_never_active' && (
              <div data-testid="rollback-error-version-never-active" style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}>
                Version {targetVersion} has never been live in this workspace and cannot be
                selected. Choose a version that was previously active.
              </div>
            )}
            {errorKind === 'already_active' && (
              <div data-testid="rollback-error-already-active" style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}>
                Version {targetVersion} is already the active version — there is nothing to roll
                back to.
              </div>
            )}
            {errorKind === 'unknown' && rollbackError && (
              <div data-testid="rollback-error-unknown" style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}>
                The rollback could not be completed ({rollbackError.message}). No change was
                made — try again.
              </div>
            )}

            {/* §4 step 4 — confirmation step */}
            {(phase === 'confirming' || phase === 'submitting') && (
              <div
                data-testid="rollback-confirm-dialog"
                style={{ padding: '.85rem 1rem', border: '1px solid var(--border-default)', borderRadius: '6px', background: 'var(--surface-card)' }}
              >
                <p style={{ marginTop: 0 }}>
                  Roll back {def.name} from {def.version} to {targetVersion}? Every case started
                  after this completes will run on {targetVersion}. Cases already in progress are
                  not affected.
                </p>
                <div style={{ display: 'flex', gap: '.5rem' }}>
                  <Button
                    variant="secondary"
                    size="md"
                    data-testid="rollback-cancel-btn"
                    disabled={phase === 'submitting'}
                    onClick={handleCancel}
                  >
                    Cancel
                  </Button>
                  <Button
                    variant="danger"
                    size="md"
                    data-testid="rollback-confirm-btn"
                    loading={phase === 'submitting'}
                    disabled={phase === 'submitting'}
                    onClick={() => { void handleConfirm() }}
                  >
                    Confirm rollback
                  </Button>
                </div>
              </div>
            )}

            {/* §4 step 5 — success banner */}
            {successResult && phase === 'idle' && (
              <div
                data-testid="rollback-success-banner"
                style={{ padding: '.6rem .8rem', background: 'var(--color-success-light)', color: 'var(--color-success-dark)', borderRadius: '4px', fontSize: '.85rem' }}
              >
                Rolled back to {successResult.version}. Every new case will run on this version.
              </div>
            )}

            {/* §7.2 — page-local "Recent rollback" change-history panel */}
            <div data-testid="rollback-history-panel">
              <h4 style={{ marginBottom: '.5rem' }}>Recent rollback</h4>
              {history.length === 0 ? (
                <p style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
                  No rollbacks performed in this session yet.
                </p>
              ) : (
                history.map((entry, idx) => (
                  <div
                    key={`${entry.eventId}-${idx}`}
                    data-testid="rollback-history-entry"
                    style={{ padding: '.5rem 0', borderBottom: '1px solid var(--border-default)', fontSize: '.85rem' }}
                  >
                    <div><strong>Actor:</strong> {entry.actor}</div>
                    <div><strong>Timestamp:</strong> {formatDateTime(entry.timestamp)}</div>
                    <div><strong>Restored version:</strong> {entry.restoredVersion}</div>
                    <div><strong>Rolled back from:</strong> {entry.rolledBackFromVersion}</div>
                    <div><strong>Reason:</strong> {entry.reason}</div>
                    <div>
                      <strong>Event id:</strong>{' '}
                      <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--text-secondary)' }}>{entry.eventId}</span>
                    </div>
                  </div>
                ))
              )}
            </div>
          </div>
        )}
      </QueryStateBoundary>
    </PageLayout>
  )
}
