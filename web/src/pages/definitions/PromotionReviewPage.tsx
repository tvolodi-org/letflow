/** PromotionReviewPage — ISS-0730: mounts the promotion-review GUI flow
 *  (PRM-04 state machine + PRM-05 non-skippable approval gate) behind a
 *  direct-URL-only route, gated on platform-admin role.
 *
 *  Reached only via a direct URL (definitions/:id/promotions/:reviewId)
 *  known to the reviewer out-of-band -- no nav entry, no contextual link.
 *  See lib/letflow/design/iss0730-promotion-review-page-routing.md for the
 *  validated design this page implements verbatim.
 */

import React, { useMemo } from 'react'
import { useParams, Navigate } from 'react-router-dom'
import { P, useAccess, AccessPending } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { decodeTokenPayload } from '@/auth/tokenUtils'
import {
  usePromotionContext,
  useApprovePromotion,
  useRejectPromotion,
  useApplyPromotion,
} from '@/hooks/usePromotions'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { PromotionReviewStateMachine } from '@/components/promotions/PromotionReviewStateMachine'
import { NonSkippableApprovalGate } from '@/components/promotions/NonSkippableApprovalGate'
import { classifyError, type RendererState } from '@/utils/classifyError'

export default function PromotionReviewPage(): React.ReactElement {
  // `id` is the parent definition id -- kept in the URL only for
  // breadcrumb/context per the `definitions/:id` convention; not used in
  // any query here.
  const { reviewId } = useParams<{ id: string; reviewId: string }>()
  const { session } = useAuth()
  const access = useAccess()
  const isAllowed = access.can(P.PromotionsRead)

  const currentUserId = useMemo(
    () => (session?.token ? decodeTokenPayload(session.token)?.sub ?? null : null),
    [session?.token],
  )

  const { data, isLoading, isError, error, refetch } = usePromotionContext(reviewId ?? '')

  const approveMutation = useApprovePromotion()
  const rejectMutation = useRejectPromotion()
  const applyMutation = useApplyPromotion()

  const state: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <h2 style={{ marginTop: 0 }}>Promotion Review</h2>
      <QueryStateBoundary state={state} onRetry={() => { void refetch() }}>
        {data && (
          <>
            <PromotionReviewStateMachine review={data.review} />
            <NonSkippableApprovalGate
              context={data}
              currentUserId={currentUserId ?? ''}
              onApprove={(id, planDigest) =>
                approveMutation
                  .mutateAsync({ reviewId: id, body: { plan_digest: planDigest, approved_by: currentUserId ?? '' } })
                  .then(() => {})
              }
              onReject={(id) => rejectMutation.mutateAsync(id).then(() => {})}
              onApply={(id, planDigest) =>
                applyMutation.mutateAsync({ reviewId: id, body: { plan_digest: planDigest } }).then(() => {})
              }
            />
          </>
        )}
      </QueryStateBoundary>
    </div>
  )
}
