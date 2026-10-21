/** PromotionReviewListPage — REQ-398: the promotion-review list/queue page,
 *  reached via the new `/promotions` nav entry (AppShell.tsx). Reads
 *  REQ-397's `GET /api/v1/promotions`, platform-admin role-only, and links each
 *  row to the existing `definitions/:id/promotions/:reviewId` detail route
 *  (ISS-0730, PromotionReviewPage.tsx).
 *
 *  SUPERSESSION NOTE (REQ-398 AC7): this page and its nav entry supersede
 *  lib/letflow/design/iss0730-promotion-review-page-routing.md §1's
 *  "Decision: no nav entry, no contextual link — direct URL only." That
 *  decision's rationale was "no list endpoint exists ... a static nav entry
 *  would 404 or need a placeholder list page nobody asked for" — REQ-397
 *  built the list endpoint and this requirement builds the real page it
 *  points to, so that rationale no longer holds. See
 *  lib/letflow/design/req398-promotion-review-list-page.md §8 for the full
 *  re-decision record.
 *
 *  OPEN SCOPE NOTE (REQ-398 AC8): this list can only show reviews that have
 *  a `promotion_reviews` row. A submit-time conflict refusal never creates
 *  one (ISS-0734 fix_direction piece 2 — whether such a refusal should be
 *  durably recorded at all — remains undecided and is out of this
 *  requirement's scope), so refused-at-submit-time proposals never appear
 *  here. That absence is expected, not a bug this requirement introduces or
 *  must fix.
 */

import React, { useMemo, useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { P, useAccess, AccessPending } from '@/auth/access'
import { usePromotionReviewList } from '@/hooks/usePromotions'
import type { PromotionReviewListFilters, ReviewStatus } from '@/api/promotions'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDateTime } from '@/i18n/format'

const REVIEW_STATUSES: ReviewStatus[] = [
  'pending_review',
  'approved',
  'rejected',
  'applied',
  'failed',
  'superseded',
]

export default function PromotionReviewListPage(): React.ReactElement {
  const access = useAccess()
  const isAllowed = access.can(P.PromotionsRead)

  const [statusFilter, setStatusFilter] = useState<ReviewStatus | ''>('')
  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [pageSize, setPageSize] = useState<number>(25)

  const cursor = cursorStack[cursorStack.length - 1]
  const filters = useMemo<PromotionReviewListFilters>(
    () => ({
      status: statusFilter || undefined,
      cursor,
      page_size: pageSize,
    }),
    [statusFilter, cursor, pageSize],
  )

  const { data, isLoading, isError, error, isFetching, refetch } = usePromotionReviewList(filters)

  const state: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const nextCursor = data?.next_cursor
  const hasResults = (data?.items.length ?? 0) > 0

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Promotion Reviews</h2>
        {isFetching && <span style={{ fontSize: 'var(--text-xs)', color: 'var(--color-info-dark)' }}>Refreshing…</span>}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '.65rem', marginBottom: '1rem' }}>
        <select
          value={statusFilter}
          onChange={(e) => {
            setStatusFilter(e.target.value as ReviewStatus | '')
            setCursorStack([])
          }}
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        >
          <option value="">All statuses</option>
          {REVIEW_STATUSES.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <select
          value={pageSize}
          onChange={(e) => {
            setPageSize(Number(e.target.value))
            setCursorStack([])
          }}
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        >
          <option value={25}>25 / page</option>
          <option value={50}>50 / page</option>
          <option value={100}>100 / page</option>
        </select>
      </div>

      <QueryStateBoundary
        state={state}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={state === 'rate-limit' ? getRetryAfterSeconds(error) : undefined}
        columns={[{ widthPercent: 15 }, { widthPercent: 30 }, { widthPercent: 25 }, { widthPercent: 30 }]}
      >
        {!hasResults && (
          <div style={{ marginBottom: '1rem', color: 'var(--text-secondary)' }}>No promotion reviews found.</div>
        )}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 'var(--text-sm)' }}>
          <thead>
            <tr style={{ background: 'var(--surface-page)', textAlign: 'left' }}>
              <th style={{ padding: '.6rem .8rem' }}>Status</th>
              <th style={{ padding: '.6rem .8rem' }}>Definition</th>
              <th style={{ padding: '.6rem .8rem' }}>Requested By</th>
              <th style={{ padding: '.6rem .8rem' }}>Requested At</th>
            </tr>
          </thead>
          <tbody>
            {(data?.items ?? []).map((item) => (
              <tr key={item.id} style={{ borderBottom: '1px solid var(--border-default)' }}>
                <td style={{ padding: '.5rem .8rem' }}>
                  <Link to={`/definitions/${item.def_id}/promotions/${item.id}`}>{item.status}</Link>
                </td>
                <td style={{ padding: '.5rem .8rem', fontSize: 'var(--text-xs)' }}>
                  <div>{item.def_type}</div>
                  <div style={{ color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)' }}>{item.def_id}</div>
                </td>
                <td style={{ padding: '.5rem .8rem', fontSize: 'var(--text-xs)', fontFamily: 'var(--font-mono)' }}>{item.requested_by}</td>
                <td style={{ padding: '.5rem .8rem', color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)', whiteSpace: 'nowrap' }}>
                  {formatDateTime(item.inserted_at)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>

        <div style={{ marginTop: '1rem' }}>
          <PaginationControls
            page={cursorStack.length + 1}
            pageSize={pageSize}
            totalItems={null}
            hasNextPage={Boolean(nextCursor)}
            onPageChange={(newPage) => {
              if (newPage < cursorStack.length + 1) {
                setCursorStack((prev) => prev.slice(0, -1))
              } else if (nextCursor) {
                setCursorStack((prev) => [...prev, nextCursor])
              }
            }}
          />
        </div>
      </QueryStateBoundary>
    </div>
  )
}
