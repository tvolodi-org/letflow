/** SolutionPackUpdateReviewPage — REQ-381 design §4.2, §5, §6
 *
 *  Route: `/solution-packs/:packId/update-review`. Reached only via the
 *  launcher's `navigate(..., { state })` — a direct-URL-only,
 *  no-independent-deep-link constraint (same as `PromotionReviewPage.tsx`).
 *  If `location.state` is absent, renders an empty state rather than
 *  crashing or silently re-deriving the missing input.
 */
import React, { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { Navigate, useLocation, useParams } from 'react-router-dom'
import { P, useAccess, AccessPending } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { PageLayout } from '@/components/ui/PageLayout'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { UpdateReviewGroupList, artefactKey, entryNeedsDecision } from '@/components/solution-packs/UpdateReviewGroupList'
import { UpdateApplyGate } from '@/components/solution-packs/UpdateApplyGate'
import { useSolutionPackUpdateReview, useSolutionPackUpdateApply } from '@/hooks/useSolutionPackUpdate'
import {
  parseUnresolvedConflictDetail,
  type PackArtefactInput,
  type PackResolutionChoice,
  type PackUpdateAppliedEntry,
} from '@/api/solutionPacks'
import type { ApiError } from '@/types/api'

export interface SolutionPackReviewLocationState {
  targetVersion: string
  theirsArtefacts: PackArtefactInput[]
  incomingArtefacts: PackArtefactInput[]
}

interface ResolutionDraft {
  choice: PackResolutionChoice
  resolvedContent: string | null
}

function SolutionPackUpdateReviewPageInner(): React.ReactElement {
  const intl = useIntl()
  const { packId } = useParams<{ packId: string }>()
  const location = useLocation()
  const { session } = useAuth()
  const access = useAccess()
  const isAllowed = access.can(P.ModulesManage)
  const canManageOverrides = access.can(P.SolutionOverridesManage)

  const [resolutionDrafts, setResolutionDrafts] = useState<Map<string, ResolutionDraft>>(new Map())
  const [sessionAttribution, setSessionAttribution] = useState<Map<string, { resolvedBy: string; resolvedAt: string }>>(new Map())
  const [blockedDetail, setBlockedDetail] = useState<{ artefactType: string; artefactId: string } | null>(null)
  const [lastAppliedEntries, setLastAppliedEntries] = useState<PackUpdateAppliedEntry[] | null>(null)
  const [applyError, setApplyError] = useState<string | null>(null)

  const navState = location.state as SolutionPackReviewLocationState | null | undefined

  const targetVersion = navState?.targetVersion ?? ''
  const theirsArtefacts = navState?.theirsArtefacts ?? []
  const incomingArtefacts = navState?.incomingArtefacts ?? []

  const reviewQuery = useSolutionPackUpdateReview(packId ?? '', targetVersion, theirsArtefacts, incomingArtefacts)
  const applyMutation = useSolutionPackUpdateApply()

  const state: RendererState = reviewQuery.isLoading
    ? 'loading'
    : reviewQuery.isError
      ? classifyError(reviewQuery.error)
      : 'success'

  const entries = useMemo(() => reviewQuery.data?.entries ?? [], [reviewQuery.data])

  // Recomputed live as choices are made — client-side pre-block (design
  // §4.4), NOT the server-authoritative check (that's a 409 on Apply).
  const hasUnresolvedConflicts = useMemo(
    () =>
      entries.some(
        (e) =>
          entryNeedsDecision(e) &&
          !resolutionDrafts.has(artefactKey(e.artefact_type, e.artefact_id)),
      ),
    [entries, resolutionDrafts],
  )
  // The server needs the permission whenever the plan holds an override_conflict (REQ-617 (6)).
  const holdsOverrideConflict = entries.some((e) => e.override?.outcome === 'override_conflict')
  const applyAllowed = !holdsOverrideConflict || canManageOverrides

  const unresolvedCount = useMemo(
    () =>
      entries.filter(
        (e) =>
          entryNeedsDecision(e) &&
          !resolutionDrafts.has(artefactKey(e.artefact_type, e.artefact_id)),
      ).length,
    [entries, resolutionDrafts],
  )

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  if (!navState) {
    return (
      <PageLayout title="Review pack update">
        <div data-testid="solution-pack-review-empty-state" style={{ fontSize: '.9rem', color: 'var(--text-secondary)' }}>
          Start a new review from the pack list.
        </div>
      </PageLayout>
    )
  }

  const resolutionChoices = new Map<string, PackResolutionChoice>(
    Array.from(resolutionDrafts.entries()).map(([key, draft]) => [key, draft.choice]),
  )

  const handleChooseResolution = (artefactType: string, artefactId: string, choice: PackResolutionChoice): void => {
    setResolutionDrafts((prev) => {
      const next = new Map(prev)
      next.set(artefactKey(artefactType, artefactId), { choice, resolvedContent: null })
      return next
    })
  }

  const handleApply = async (): Promise<void> => {
    setBlockedDetail(null)
    setApplyError(null)
    const resolutions = Array.from(resolutionDrafts.entries()).map(([key, draft]) => {
      const [artefactType, artefactId] = key.split(':')
      return {
        artefact_type: artefactType,
        artefact_id: artefactId,
        resolution: draft.choice,
        resolved_content: draft.resolvedContent,
      }
    })

    const confirmedAt = new Date().toISOString()
    const resolvedBy = session?.display_name ?? 'unknown operator'

    try {
      const result = await applyMutation.mutateAsync({
        packId: packId ?? '',
        body: {
          target_version: targetVersion,
          theirs_artefacts: theirsArtefacts,
          incoming_artefacts: incomingArtefacts,
          resolutions,
        },
      })
      // §3.3 — session-local attribution, captured at the moment of decision.
      setSessionAttribution((prev) => {
        const next = new Map(prev)
        for (const [key] of resolutionDrafts) {
          next.set(key, { resolvedBy, resolvedAt: confirmedAt })
        }
        return next
      })
      setLastAppliedEntries(result.applied_entries)
    } catch (err) {
      const apiErr = err as ApiError
      if (apiErr.status === 409) {
        const detail = typeof apiErr.details?.detail === 'string' ? apiErr.details.detail : undefined
        const parsed = parseUnresolvedConflictDetail(detail)
        setBlockedDetail(parsed)
        if (!parsed) setApplyError(intl.formatMessage({ id: 'solutionOverrides.report.error.conflict' }))
      } else if (apiErr.status === 403) {
        setApplyError(intl.formatMessage({ id: 'solutionOverrides.report.error.forbidden' }))
      } else if (apiErr.status === 422 && apiErr.details?.detail === 'override_merge_unsupported') {
        setApplyError(intl.formatMessage({ id: 'solutionOverrides.report.error.override_merge_unsupported' }))
      } else {
        setApplyError(intl.formatMessage({ id: 'solutionOverrides.report.error.generic' }))
      }
      // No update is applied in the blocked case -- the review query is not
      // invalidated on error, so nothing on screen changes except the
      // banner (design §4.4).
    }
  }

  return (
    <PageLayout title="Review pack update">
      <QueryStateBoundary state={state} onRetry={() => { void reviewQuery.refetch() }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}>
          <UpdateReviewGroupList
            entries={entries}
            resolutionChoices={resolutionChoices}
            onChooseResolution={handleChooseResolution}
            attribution={sessionAttribution}
            appliedEntries={lastAppliedEntries}
          />
          <UpdateApplyGate
            hasUnresolvedConflicts={hasUnresolvedConflicts}
            unresolvedCount={unresolvedCount}
            onApply={() => { void handleApply() }}
            applyState={applyMutation.isPending ? 'submitting' : 'idle'}
            blockedDetail={blockedDetail}
            applyAllowed={applyAllowed}
            restrictedMessage={intl.formatMessage({ id: 'solutionOverrides.report.applyNeedsManage' })}
            errorMessage={applyError ?? undefined}
          />
        </div>
      </QueryStateBoundary>
    </PageLayout>
  )
}

export default function SolutionPackUpdateReviewPage(): React.ReactElement {
  return (
    <EntitiesIntlProvider>
      <SolutionPackUpdateReviewPageInner />
    </EntitiesIntlProvider>
  )
}
