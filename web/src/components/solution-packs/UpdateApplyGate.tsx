/** UpdateApplyGate — REQ-381 design §4.4 (EO-002)
 *
 *  The Apply button is a CLIENT-SIDE pre-block (disabled while any
 *  both_sides_conflict entry has no resolution chosen this session), but
 *  the server-side block is authoritative: `onApply` always fires the real
 *  `update-apply` call when clicked-while-enabled, and if the server itself
 *  returns 409 (e.g. a race), `blockedDetail` renders a banner naming the
 *  real unresolved artefact from the endpoint's own response — never a
 *  client-only guess.
 */
import React from 'react'
import { Button } from '@/components/ui/Button'

export interface UpdateApplyGateProps {
  hasUnresolvedConflicts: boolean
  unresolvedCount: number
  onApply: () => void
  applyState: 'idle' | 'submitting'
  blockedDetail: { artefactType: string; artefactId: string } | null
  /** false hides the Apply control (UX only; the server stays the authority). */
  applyAllowed?: boolean
  restrictedMessage?: string
  errorMessage?: string
}

export function UpdateApplyGate(props: UpdateApplyGateProps): React.ReactElement {
  const { hasUnresolvedConflicts, unresolvedCount, onApply, applyState, blockedDetail, applyAllowed = true, restrictedMessage, errorMessage } = props

  return (
    <div data-testid="update-apply-gate" style={{ display: 'flex', flexDirection: 'column', gap: '.5rem' }}>
      {hasUnresolvedConflicts && (
        <p data-testid="update-apply-unresolved-hint" style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
          {unresolvedCount} artefact{unresolvedCount === 1 ? '' : 's'} still need{unresolvedCount === 1 ? 's' : ''} a decision before this update can be applied.
        </p>
      )}

      {blockedDetail && (
        <div
          data-testid="update-apply-blocked-banner"
          role="alert"
          style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}
        >
          Update blocked — {blockedDetail.artefactType} {blockedDetail.artefactId} still needs a decision.
        </div>
      )}

      {errorMessage && (
        <div
          data-testid="update-apply-error"
          role="alert"
          style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}
        >
          {errorMessage}
        </div>
      )}

      {!applyAllowed && (
        <p data-testid="update-apply-restricted" style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
          {restrictedMessage}
        </p>
      )}

      {applyAllowed && (
      <div>
        <Button
          variant="primary"
          size="md"
          data-testid="update-apply-btn"
          disabled={hasUnresolvedConflicts || applyState === 'submitting'}
          loading={applyState === 'submitting'}
          onClick={onApply}
        >
          Apply update
        </Button>
      </div>
      )}
    </div>
  )
}
