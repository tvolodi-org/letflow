/** NonSkippableApprovalGate — PRM-05: Non-skippable approval gate UI
 *
 *  Displays the full promotion context (stored plan, digest, assertions, NEEDS_REVIEW package).
 *  Provides Reject / Approve / Apply buttons with:
 *    - Self-approval prevention (HTTP 403 inline error)
 *    - Apply button disabled unless plan_digest present in context
 *    - HTTP 422 for extra fields on apply (shown inline)
 *  Gate is non-skippable: no bypass parameter exists.
 */

import React, { useState } from 'react'
import type {
  PromotionContext,
} from '@/api/promotions'
import { PlanDigestView } from './PlanDigestView'

export interface NonSkippableApprovalGateProps {
  /** The full context response from GET /api/v1/promotions/{id}/context */
  context: PromotionContext
  /** Current user ID (sub from JWT) — used to enforce requested_by != approved_by */
  currentUserId: string
  /** Called when the review transitions; parent should invalidate queries */
  onTransition?: () => void
  /** Mutation helpers (passed in from parent to avoid coupling to query client here) */
  onApprove: (reviewId: string, planDigest: string) => Promise<void>
  onReject: (reviewId: string) => Promise<void>
  onApply: (reviewId: string, planDigest: string) => Promise<void>
  className?: string
  /** Hides Reject/Approve/Apply for a viewer without PromotionsManage (the server enforces it) */
  readOnly?: boolean
}

// ── Inline error alert ─────────────────────────────────────────────────────────

function InlineError(props: { message: string; testId?: string }) {
  return (
    <div
      data-testid={props.testId ?? 'inline-error'}
      role="alert"
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '.4rem',
        padding: '.5rem .75rem',
        borderRadius: '6px',
        background: 'var(--color-error-tint)',
        border: '1px solid var(--color-error)',
        color: 'var(--color-error-dark)',
        fontSize: '.82rem',
        marginTop: '.5rem',
      }}
    >
      <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="10" />
        <line x1="12" y1="8" x2="12" y2="12" />
        <line x1="12" y1="16" x2="12.01" y2="16" />
      </svg>
      {props.message}
    </div>
  )
}

// ── Self-approval error (HTTP 403) ───────────────────────────────────────────

function SelfApprovalError(props: { message?: string }) {
  return (
    <InlineError
      testId="self-approval-error"
      message={props.message ?? 'You cannot approve your own promotion request. A different reviewer must approve.'}
    />
  )
}

// ── Digest mismatch error (HTTP 409) ──────────────────────────────────────────

function DigestMismatchError(props: { message?: string }) {
  return (
    <InlineError
      testId="digest-mismatch-error"
      message={props.message ?? 'Plan digest mismatch. The plan may have changed since submission. Please review again.'}
    />
  )
}

// ── Promotion conflict error (HTTP 409, apply-time re-check — ISS-0735) ───────
//
// Distinct from a digest mismatch: this fires when `POST /apply`'s own
// conflict re-check (`Letflow.Definitions.PromotionConflict.reject_if_conflicts/4`,
// called from inside `Promotion.do_promote_definition/7`) finds the target
// tenant has moved past this review's `base_version` since it was approved
// — e.g. a different promotion landed in between. Both this and a digest
// mismatch are HTTP 409, but they are different RFC 9457 problem `type`s
// (`.../problems/promotion-conflict` vs `.../problems/conflict`) and need a
// different message: a digest mismatch means "re-review", a promotion
// conflict means "rebuild against the tenant's current version" (the same
// message the submit-time conflict already uses).
function PromotionConflictError(props: { targetActiveVersion?: string }) {
  return (
    <InlineError
      testId="promotion-conflict-error"
      message={
        props.targetActiveVersion
          ? `The target tenant has advanced to version ${props.targetActiveVersion} since this change was approved. This approval no longer applies — rebuild the proposal on the current live version and resubmit for review.`
          : 'The target tenant has advanced since this change was approved. This approval no longer applies — rebuild the proposal on the current live version and resubmit for review.'
      }
    />
  )
}

// ── Invalid transition error (HTTP 400) ───────────────────────────────────────

function TransitionError(props: { message?: string }) {
  return (
    <InlineError
      testId="transition-error"
      message={props.message ?? 'This action is not permitted in the current review state.'}
    />
  )
}

// ── Extra fields error (HTTP 422) ─────────────────────────────────────────────

function ExtraFieldsError(props: { message?: string }) {
  return (
    <InlineError
      testId="extra-fields-error"
      message={props.message ?? 'Unknown fields in request body. Ensure no extra parameters are sent.'}
    />
  )
}

// ── Rehearsal gate error (HTTP 409, apply-time assertion-run gate — ISS-0732/ISS-0767) ──
//
// Four distinct server-side reasons, all HTTP 409, all byte-identical in
// `status`/`type`/`title` (every one goes through `Letflow.Api.Error.conflict/1`),
// disambiguated only by the RFC 9457 `detail` string. See
// `lib/letflow/design/iss0767-non-skippable-gate-rehearsal-blocked-state.md` §0-§3
// for the full reasoning; this mirrors `classifyRollbackError`
// (`web/src/pages/definitions/DefinitionRollbackPage.tsx`) 1:1.

export type RehearsalGateErrorKind =
  | 'assertion_run_missing'
  | 'assertion_run_digest_mismatch'
  | 'assertion_run_in_progress'
  | 'assertion_run_failed'
  | 'not_rehearsal_related'

export function classifyApplyRehearsalError(err: {
  status?: number
  details?: Record<string, unknown>
}): RehearsalGateErrorKind {
  if (err.status !== 409) return 'not_rehearsal_related'
  const detail = typeof err.details?.detail === 'string' ? err.details.detail : undefined
  if (detail === 'no assertion run has been recorded for this review; run assertions before applying') {
    return 'assertion_run_missing'
  }
  if (
    detail ===
    'the most recent assertion run does not match the plan_digest being applied; re-run assertions against the current plan'
  ) {
    return 'assertion_run_digest_mismatch'
  }
  if (
    detail ===
    'the most recent assertion run for this review has not finished yet; wait for it to complete or re-run assertions before applying'
  ) {
    return 'assertion_run_in_progress'
  }
  if (
    detail ===
    'the most recent assertion run recorded failing assertions; applying is blocked until a rehearsal with zero failures is recorded'
  ) {
    return 'assertion_run_failed'
  }
  return 'not_rehearsal_related'
}

function RehearsalGateError(props: { kind: RehearsalGateErrorKind }): React.ReactElement | null {
  switch (props.kind) {
    case 'assertion_run_missing':
      return (
        <InlineError
          testId="rehearsal-gate-error-missing"
          message="This plan has not been rehearsed yet. Run assertions before applying — Apply is blocked until a rehearsal is recorded for the current plan."
        />
      )
    case 'assertion_run_digest_mismatch':
      return (
        <InlineError
          testId="rehearsal-gate-error-stale"
          message="The most recent rehearsal was run against an earlier version of this plan. Re-run assertions against the current plan before applying."
        />
      )
    case 'assertion_run_in_progress':
      return (
        <InlineError
          testId="rehearsal-gate-error-in-progress"
          message="A rehearsal is currently running for this plan. Wait for it to finish, then try Apply again — do not start a second rehearsal."
        />
      )
    case 'assertion_run_failed':
      return (
        <InlineError
          testId="rehearsal-gate-error-failed"
          message="The most recent rehearsal recorded failing assertions. Applying is blocked until a rehearsal with zero failures is recorded — fix the plan or target and re-run assertions."
        />
      )
    case 'not_rehearsal_related':
      return null
  }
}

// ── Assertion item ─────────────────────────────────────────────────────────────

function AssertionItem(props: { artifact_id: string; assertion_type: string; passed: boolean }) {
  return (
    <div
      data-testid={`assertion-${props.assertion_type}`}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '.5rem',
        padding: '.4rem .6rem',
        borderRadius: '5px',
        background: props.passed ? 'var(--color-success-tint)' : 'var(--color-error-tint)',
        border: `1px solid ${props.passed ? 'var(--color-success)' : 'var(--color-error)'}`,
      }}
    >
      {props.passed ? (
        <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--color-success-dark)" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <polyline points="20 6 9 17 4 12" />
        </svg>
      ) : (
        <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--color-error-dark)" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <line x1="18" y1="6" x2="6" y2="18" />
          <line x1="6" y1="6" x2="18" y2="18" />
        </svg>
      )}
      <code style={{ fontFamily: 'monospace', fontSize: '.75rem', color: 'var(--color-neutral-800)' }}>
        {props.assertion_type}
      </code>
      <span style={{ fontSize: '.72rem', color: 'var(--text-secondary)', marginLeft: 'auto' }}>
        {props.artifact_id}
      </span>
    </div>
  )
}

// ── Main component ─────────────────────────────────────────────────────────────

export function NonSkippableApprovalGate(props: NonSkippableApprovalGateProps): React.ReactElement {
  const { context, currentUserId, onApprove, onReject, onApply, className, readOnly = false } = props
  const { review, plan, digest_verified, assertions } = context

  const [approving, setApproving] = useState(false)
  const [rejecting, setRejecting] = useState(false)
  const [applying, setApplying] = useState(false)

  const [selfApprovalError, setSelfApprovalError] = useState(false)
  const [digestError, setDigestError] = useState(false)
  const [transitionError, setTransitionError] = useState(false)
  const [extraFieldsError, setExtraFieldsError] = useState(false)
  const [generalError, setGeneralError] = useState<string | null>(null)
  const [promotionConflict, setPromotionConflict] = useState<{ targetActiveVersion?: string } | null>(null)
  const [rehearsalGateError, setRehearsalGateError] = useState<RehearsalGateErrorKind | null>(null)

  const isSelfApproval = review.requested_by === currentUserId
  const canApprove = !isSelfApproval && review.status === 'pending_review'
  const canReject = review.status === 'pending_review'
  const canApply = review.status === 'approved' && !!review.plan_digest

  async function handleApprove() {
    setSelfApprovalError(false)
    setDigestError(false)
    setTransitionError(false)
    setExtraFieldsError(false)
    setGeneralError(null)

    if (isSelfApproval) {
      setSelfApprovalError(true)
      return
    }

    setApproving(true)
    try {
      await onApprove(review.id, review.plan_digest)
    } catch (err: unknown) {
      const err2 = err as { status?: number; code?: string; message?: string }
      if (err2.status === 403 || err2.code === 'SELF_APPROVAL_FORBIDDEN') {
        setSelfApprovalError(true)
      } else if (err2.status === 409 || err2.code === 'PLAN_DIGEST_MISMATCH') {
        setDigestError(true)
      } else if (err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION') {
        setTransitionError(true)
      } else if (err2.status === 422) {
        setExtraFieldsError(true)
      } else {
        setGeneralError(err2.message ?? 'Approval failed. Please try again.')
      }
    } finally {
      setApproving(false)
    }
  }

  async function handleReject() {
    setTransitionError(false)
    setGeneralError(null)
    setRejecting(true)
    try {
      await onReject(review.id)
    } catch (err: unknown) {
      const err2 = err as { status?: number; code?: string; message?: string }
      if (err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION') {
        setTransitionError(true)
      } else {
        setGeneralError(err2.message ?? 'Rejection failed. Please try again.')
      }
    } finally {
      setRejecting(false)
    }
  }

  async function handleApply() {
    setDigestError(false)
    setPromotionConflict(null)
    setRehearsalGateError(null)
    setTransitionError(false)
    setExtraFieldsError(false)
    setGeneralError(null)
    setApplying(true)
    try {
      await onApply(review.id, review.plan_digest)
    } catch (err: unknown) {
      const err2 = err as {
        status?: number
        code?: string
        message?: string
        details?: { conflicts?: Array<{ target_active_version?: string }>; detail?: string }
      }
      // ISS-0735: HTTP 409 from /apply is not always a digest mismatch --
      // `POST /apply`'s own conflict re-check (the target tenant having
      // moved past this review's base_version since approval, EO-004's own
      // protection) ALSO returns 409, as a distinct RFC 9457 problem `type`
      // (`.../problems/promotion-conflict`, not `.../problems/conflict`).
      // Checking `code` (the response's `type`) before falling back to a
      // bare status check keeps these two 409s from collapsing into the
      // same, sometimes-wrong message.
      const rehearsalGateKind = classifyApplyRehearsalError(err2)
      if (err2.status === 409 && err2.code?.endsWith('/promotion-conflict')) {
        setPromotionConflict({ targetActiveVersion: err2.details?.conflicts?.[0]?.target_active_version })
      } else if (rehearsalGateKind !== 'not_rehearsal_related') {
        // ISS-0767: apply_review/4's assertion-run gate (ISS-0732) also
        // returns 409, as one of four `detail` strings distinct from the
        // pre-existing `:digest_mismatch` 409. This check MUST run before
        // the bare `status === 409` digest-mismatch fallback below --
        // otherwise all four of these new 409s would be silently swallowed
        // into a misleading "Plan digest mismatch" message.
        setRehearsalGateError(rehearsalGateKind)
      } else if (err2.status === 409 || err2.code === 'PLAN_DIGEST_MISMATCH') {
        setDigestError(true)
      } else if (err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION') {
        setTransitionError(true)
      } else if (err2.status === 422) {
        setExtraFieldsError(true)
      } else {
        setGeneralError(err2.message ?? 'Apply failed. Please try again.')
      }
    } finally {
      setApplying(false)
    }
  }

  return (
    <div
      data-testid="non-skippable-approval-gate"
      className={className}
      style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}
    >
      {/* NEEDS_REVIEW package + assertions */}
      <div
        style={{
          padding: '1rem',
          borderRadius: '8px',
          border: '1px solid var(--border-default)',
          background: 'var(--surface-card)',
        }}
      >
        <div style={{ fontSize: '.7rem', fontWeight: 600, color: 'var(--text-secondary)', marginBottom: '.5rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
          Artifact Assertions
        </div>
        {assertions && assertions.length > 0 ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '.35rem' }}>
            {assertions.map((a) => (
              <AssertionItem key={a.artifact_id + a.assertion_type} {...a} />
            ))}
          </div>
        ) : (
          <p style={{ margin: 0, fontSize: '.82rem', color: 'var(--text-secondary)' }}>No assertions available.</p>
        )}
      </div>

      {/* Plan digest view */}
      <PlanDigestView
        planDigest={review.plan_digest}
        plan={plan}
        digestVerified={digest_verified}
      />

      {/* Action buttons */}
      <div
        style={{
          display: 'flex',
          flexWrap: 'wrap',
          gap: '.75rem',
          alignItems: 'flex-start',
        }}
      >
        {!readOnly && (
        <>
        {/* Reject button */}
        <button
          data-testid="reject-btn"
          type="button"
          disabled={!canReject || rejecting}
          onClick={handleReject}
          style={{
            padding: '.5rem 1.25rem',
            border: '1px solid var(--color-error)',
            borderRadius: '6px',
            background: 'var(--surface-card)',
            color: 'var(--color-error-dark)',
            cursor: !canReject || rejecting ? 'not-allowed' : 'pointer',
            fontSize: '.875rem',
            fontWeight: 500,
            opacity: !canReject || rejecting ? 0.55 : 1,
          }}
        >
          {rejecting ? 'Rejecting…' : 'Reject'}
        </button>

        {/* Approve button */}
        <button
          data-testid="approve-btn"
          type="button"
          disabled={!canApprove || approving}
          onClick={handleApprove}
          style={{
            padding: '.5rem 1.25rem',
            border: 'none',
            borderRadius: '6px',
            background: isSelfApproval ? 'var(--color-neutral-400)' : 'var(--interactive-primary)',
            color: 'var(--text-inverse)',
            cursor: !canApprove || approving ? 'not-allowed' : 'pointer',
            fontSize: '.875rem',
            fontWeight: 500,
            opacity: !canApprove || approving ? 0.55 : 1,
          }}
          title={isSelfApproval ? 'Self-approval is not permitted' : undefined}
        >
          {approving ? 'Approving…' : 'Approve'}
        </button>

        {/* Apply button */}
        <button
          data-testid="apply-btn"
          type="button"
          disabled={!canApply || applying}
          onClick={handleApply}
          style={{
            padding: '.5rem 1.25rem',
            border: 'none',
            borderRadius: '6px',
            background: canApply ? 'var(--color-success)' : 'var(--color-neutral-500)',
            color: 'var(--text-inverse)',
            cursor: !canApply || applying ? 'not-allowed' : 'pointer',
            fontSize: '.875rem',
            fontWeight: 500,
            opacity: !canApply || applying ? 0.55 : 1,
          }}
          title={!canApply && review.status === 'approved' && !review.plan_digest ? 'Plan digest missing — cannot apply' : undefined}
        >
          {applying ? 'Applying…' : 'Apply'}
        </button>
        </>
        )}

        {/* Non-skippable gate notice */}
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: '.3rem' }}>
          <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--text-secondary)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
            <path d="M7 11V7a5 5 0 0 1 10 0v4" />
          </svg>
          <span style={{ fontSize: '.72rem', color: 'var(--text-secondary)' }}>
            Non-skippable gate
          </span>
        </div>
      </div>

      {/* Inline errors */}
      {selfApprovalError && <SelfApprovalError />}
      {digestError && <DigestMismatchError />}
      {promotionConflict && <PromotionConflictError targetActiveVersion={promotionConflict.targetActiveVersion} />}
      {rehearsalGateError && <RehearsalGateError kind={rehearsalGateError} />}
      {transitionError && <TransitionError />}
      {extraFieldsError && <ExtraFieldsError />}
      {generalError && <InlineError testId="general-error" message={generalError} />}
    </div>
  )
}
